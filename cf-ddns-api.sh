#!/usr/bin/env bash
set -o errexit
set -o nounset
set -o pipefail

# Cloudflare DDNS via API Token (hardened, dual-stack).
#
# Updates A and/or AAAA records for ONE FQDN from this host's egress IP(s).
#
# Stack selection (which record types to update) — set from "outside":
#   CF_STACK=dual  -> both A and AAAA   (default)
#   CF_STACK=v4    -> A only
#   CF_STACK=v6    -> AAAA only
# Override on CLI with:  -s dual|v4|v6   or shorthand  -4 / -6
# Back-compat:           -t A  == v4 ,   -t AAAA == v6
#
# Per-machine usage pattern (fits a fleet): put the right line in the env file
#   /etc/cf-ddns.env  (chmod 600):
#       CF_API_TOKEN='...'
#       CF_STACK='v6'        # or v4 / dual, per machine
#   then:  set -a; . /etc/cf-ddns.env; set +a; ./cf-ddns-api.sh -h host.stanasis.net
#
# Token permissions (least privilege):
#   Zone:DNS:Edit  for stanasis.net
#   Zone:Zone:Read for stanasis.net
# Recommended: scope to Specific zone = stanasis.net, plus Client IP Address
# Filtering locked to this host's egress IP. Token is read from CF_API_TOKEN
# env var ONLY (never argv) to avoid leaking it via `ps`.
#
# Options:
#   -h <fqdn>        record name (default: hkt.stanasis.net)
#   -z <zone>        zone name   (default: stanasis.net)
#   -s <dual|v4|v6>  stack       (default: $CF_STACK or dual)
#   -4               v4 only  (== -s v4)
#   -6               v6 only  (== -s v6)
#   -t <A|AAAA>      back-compat single type
#   -p <keep|on|off> proxied: keep current (default), force on, force off
#   -f               force update even if WAN IP unchanged

# cron may set HOME=/ or leave it empty; pin it before nounset bites.
: "${HOME:=/root}"

CF_API_TOKEN="${CF_API_TOKEN:-}"
CFZONE_NAME="stanasis.net"
CFRECORD_NAME="hkt.stanasis.net"
CFTTL=120
FORCE=false
PROXIED_MODE="keep"            # keep | on | off
CF_STACK="${CF_STACK:-dual}"   # dual | v4 | v6  (env-overridable)

while getopts h:z:s:t:p:46f opts; do
  case ${opts} in
    h) CFRECORD_NAME=${OPTARG} ;;
    z) CFZONE_NAME=${OPTARG} ;;
    s) CF_STACK=${OPTARG} ;;
    4) CF_STACK="v4" ;;
    6) CF_STACK="v6" ;;
    t) case "${OPTARG}" in
         A)    CF_STACK="v4" ;;
         AAAA) CF_STACK="v6" ;;
         *) echo "-t must be A or AAAA, got: ${OPTARG}" >&2; exit 2 ;;
       esac ;;
    p) PROXIED_MODE=${OPTARG} ;;
    f) FORCE=true ;;
    *) echo "Unknown option" >&2; exit 2 ;;
  esac
done

# --- preflight ---------------------------------------------------------------

for bin in curl jq; do
  if ! command -v "$bin" >/dev/null 2>&1; then
    echo "Missing dependency: $bin (apt install -y $bin)" >&2
    exit 2
  fi
done

if [ -z "$CF_API_TOKEN" ]; then
  echo "Missing Cloudflare API token. Set CF_API_TOKEN (env var only)." >&2
  exit 2
fi

if [ -z "$CFRECORD_NAME" ]; then
  echo "Missing hostname." >&2
  exit 2
fi

case "$PROXIED_MODE" in
  keep|on|off) ;;
  *) echo "-p must be keep|on|off, got: $PROXIED_MODE" >&2; exit 2 ;;
esac

case "$CF_STACK" in
  dual) RECORD_TYPES="A AAAA" ;;
  v4)   RECORD_TYPES="A" ;;
  v6)   RECORD_TYPES="AAAA" ;;
  *) echo "stack must be dual|v4|v6, got: $CF_STACK" >&2; exit 2 ;;
esac

# FQDN guard
if [ "$CFRECORD_NAME" != "$CFZONE_NAME" ] && [ -n "${CFRECORD_NAME##*$CFZONE_NAME}" ]; then
  CFRECORD_NAME="$CFRECORD_NAME.$CFZONE_NAME"
  echo " => Hostname is not a FQDN, assuming $CFRECORD_NAME"
fi

AUTH_HEADER="Authorization: Bearer $CF_API_TOKEN"
CF_API="https://api.cloudflare.com/client/v4"

# --- per-type update routine -------------------------------------------------
# Returns 0 on success or no-op, 1 on failure. Never aborts the whole run, so
# in dual-stack mode a v6 failure does not kill the v4 update (and vice versa).
update_one() {
  local rtype="$1"
  local wansite wan_ip old_wan_ip wan_ip_file id_file
  local cfzone_id cfrecord_id zone_json rec_json body proxy_bool response

  case "$rtype" in
    A)    wansite="https://ipv4.icanhazip.com" ;;
    AAAA) wansite="https://ipv6.icanhazip.com" ;;
  esac

  # --- get WAN IP (tolerate this family having no connectivity) ---
  wan_ip="$(curl -fsS --max-time 10 "$wansite" | tr -d '[:space:]' || true)"
  if [ -z "$wan_ip" ]; then
    echo "[$rtype] No WAN IP (no $rtype connectivity or fetch failed). Skipping." >&2
    return 1
  fi

  # sanity-check returned IP shape; a bogus reply (empty/HTML/MITM) must not
  # be pushed to DNS.
  case "$rtype" in
    A)
      if ! [[ "$wan_ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        echo "[$rtype] Refusing: got non-IPv4 reply: '$wan_ip'" >&2
        return 1
      fi ;;
    AAAA)
      # loose IPv6 check: at least one ':' and only hex/colon chars
      if ! [[ "$wan_ip" =~ ^[0-9a-fA-F:]+$ ]] || ! [[ "$wan_ip" == *:* ]]; then
        echo "[$rtype] Refusing: got non-IPv6 reply: '$wan_ip'" >&2
        return 1
      fi ;;
  esac

  wan_ip_file="$HOME/.cf-wan_ip_${rtype}_${CFRECORD_NAME}.txt"
  old_wan_ip=""
  [ -f "$wan_ip_file" ] && old_wan_ip="$(cat "$wan_ip_file")"

  if [ "$wan_ip" = "$old_wan_ip" ] && [ "$FORCE" = false ] && [ "$PROXIED_MODE" = "keep" ]; then
    echo "[$rtype] WAN IP unchanged ($wan_ip), nothing to do."
    return 0
  fi

  # --- resolve zone id + record id (cached in 4-line id file) ---
  id_file="$HOME/.cf-id_${rtype}_${CFRECORD_NAME}.txt"
  cfzone_id=""; cfrecord_id=""

  if [ -f "$id_file" ] && [ "$(wc -l < "$id_file")" = "4" ] \
    && [ "$(sed -n '3p' "$id_file")" = "$CFZONE_NAME" ] \
    && [ "$(sed -n '4p' "$id_file")" = "$CFRECORD_NAME" ]; then
    cfzone_id="$(sed -n '1p' "$id_file")"
    cfrecord_id="$(sed -n '2p' "$id_file")"
  fi

  if [ -z "$cfzone_id" ] || [ -z "$cfrecord_id" ]; then
    echo "[$rtype] Resolving zone_id / record_id from Cloudflare..."
    zone_json="$(curl -fsS --max-time 10 -X GET \
      "$CF_API/zones?name=$CFZONE_NAME" \
      -H "$AUTH_HEADER" -H "Content-Type: application/json" || true)"
    cfzone_id="$(printf '%s' "$zone_json" | jq -r '.result[0].id // empty')"
    if [ -z "$cfzone_id" ]; then
      echo "[$rtype] Could not resolve zone '$CFZONE_NAME'." >&2
      echo "[$rtype] Token may lack Zone:Read on this zone, or zone name is wrong." >&2
      echo "[$rtype] Response: $zone_json" >&2
      return 1
    fi

    rec_json="$(curl -fsS --max-time 10 -X GET \
      "$CF_API/zones/$cfzone_id/dns_records?type=$rtype&name=$CFRECORD_NAME" \
      -H "$AUTH_HEADER" -H "Content-Type: application/json" || true)"
    cfrecord_id="$(printf '%s' "$rec_json" | jq -r '.result[0].id // empty')"
    if [ -z "$cfrecord_id" ]; then
      echo "[$rtype] No $rtype record '$CFRECORD_NAME' in zone '$CFZONE_NAME'." >&2
      echo "[$rtype] Create the record once in the Cloudflare dashboard, then re-run." >&2
      echo "[$rtype] Response: $rec_json" >&2
      return 1
    fi

    {
      echo "$cfzone_id"
      echo "$cfrecord_id"
      echo "$CFZONE_NAME"
      echo "$CFRECORD_NAME"
    } > "$id_file"
  fi

  # --- build patch body ---
  # PATCH only updates fields we send, so untouched attributes (including
  # `proxied`) keep their current value — avoids the "PUT silently flips
  # orange cloud to grey" footgun.
  if [ "$PROXIED_MODE" = "keep" ]; then
    body="$(jq -nc --arg ip "$wan_ip" --argjson ttl "$CFTTL" \
      '{content:$ip, ttl:$ttl}')"
  else
    proxy_bool=false
    [ "$PROXIED_MODE" = "on" ] && proxy_bool=true
    body="$(jq -nc --arg ip "$wan_ip" --argjson ttl "$CFTTL" --argjson proxied "$proxy_bool" \
      '{content:$ip, ttl:$ttl, proxied:$proxied}')"
  fi

  echo "[$rtype] Updating $CFRECORD_NAME -> $wan_ip (proxied: $PROXIED_MODE)"

  response="$(curl -fsS --max-time 15 -X PATCH \
    "$CF_API/zones/$cfzone_id/dns_records/$cfrecord_id" \
    -H "$AUTH_HEADER" -H "Content-Type: application/json" \
    --data "$body" || true)"

  if [ -n "$response" ] && printf '%s' "$response" | jq -e '.success == true' >/dev/null 2>&1; then
    echo "[$rtype] Updated successfully."
    printf '%s\n' "$wan_ip" > "$wan_ip_file"
    return 0
  fi

  echo "[$rtype] Update failed." >&2
  echo "[$rtype] Response: $response" >&2
  # cache may be stale (record recreated -> new id); drop it so next run re-resolves
  rm -f "$id_file"
  return 1
}

# --- run for each requested family -------------------------------------------

echo "Stack: $CF_STACK  (types: $RECORD_TYPES)  Host: $CFRECORD_NAME"

overall_rc=0
attempted=0
succeeded=0
for t in $RECORD_TYPES; do
  attempted=$((attempted + 1))
  if update_one "$t"; then
    succeeded=$((succeeded + 1))
  else
    overall_rc=1
  fi
done

echo "Done: $succeeded/$attempted record type(s) OK."
exit $overall_rc
