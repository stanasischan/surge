#!/usr/bin/env bash
set -o errexit
set -o nounset
set -o pipefail

# Cloudflare DDNS via API Token (hardened).
#
# Token permissions (least privilege):
#   Zone:DNS:Edit  for stanasis.net
#   Zone:Zone:Read for stanasis.net
# Recommended: scope to Specific zone = stanasis.net, plus Client IP
# Address Filtering locked to this host's egress IP.
#
# Usage:
#   export CF_API_TOKEN='your_cloudflare_api_token'
#   ./cf-v4-ddns-token-hardened.sh
#
# Options:
#   -h <fqdn>        record name (default: hkt.stanasis.net)
#   -z <zone>        zone name   (default: stanasis.net)
#   -t <A|AAAA>      record type (default: A)
#   -p <keep|on|off> proxied: keep current (default), force on, force off
#   -f               force update even if WAN IP unchanged
#
# Token is read from CF_API_TOKEN env var only — never from argv, to avoid
# leaking it through `ps`. For cron, put it in a chmod 600 env file and
# `set -a; source /etc/cf-ddns.env; set +a` before invoking.

# cron may set HOME=/ or leave it empty; pin it before nounset bites.
: "${HOME:=/root}"

CF_API_TOKEN="${CF_API_TOKEN:-}"
CFZONE_NAME="stanasis.net"
CFRECORD_NAME="hkt.stanasis.net"
CFRECORD_TYPE="A"
CFTTL=120
FORCE=false
PROXIED_MODE="keep"   # keep | on | off

while getopts h:z:t:p:f opts; do
  case ${opts} in
    h) CFRECORD_NAME=${OPTARG} ;;
    z) CFZONE_NAME=${OPTARG} ;;
    t) CFRECORD_TYPE=${OPTARG} ;;
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

case "$CFRECORD_TYPE" in
  A)    WANIPSITE="https://ipv4.icanhazip.com" ;;
  AAAA) WANIPSITE="https://ipv6.icanhazip.com" ;;
  *) echo "CFRECORD_TYPE must be A or AAAA, got: $CFRECORD_TYPE" >&2; exit 2 ;;
esac

case "$PROXIED_MODE" in
  keep|on|off) ;;
  *) echo "-p must be keep|on|off, got: $PROXIED_MODE" >&2; exit 2 ;;
esac

# FQDN guard
if [ "$CFRECORD_NAME" != "$CFZONE_NAME" ] && ! [ -z "${CFRECORD_NAME##*$CFZONE_NAME}" ]; then
  CFRECORD_NAME="$CFRECORD_NAME.$CFZONE_NAME"
  echo " => Hostname is not a FQDN, assuming $CFRECORD_NAME"
fi

AUTH_HEADER="Authorization: Bearer $CF_API_TOKEN"
CF_API="https://api.cloudflare.com/client/v4"

# --- get WAN IP --------------------------------------------------------------

WAN_IP="$(curl -fsS --max-time 10 "$WANIPSITE" | tr -d '[:space:]')"

# sanity-check returned IP shape; bogus reply (empty/HTML/MITM) should not
# be pushed to DNS.
case "$CFRECORD_TYPE" in
  A)
    if ! [[ "$WAN_IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
      echo "Refusing to update: got non-IPv4 WAN reply: '$WAN_IP'" >&2
      exit 1
    fi
    ;;
  AAAA)
    # loose IPv6 check — at least one ':' and only hex/colon chars
    if ! [[ "$WAN_IP" =~ ^[0-9a-fA-F:]+$ ]] || ! [[ "$WAN_IP" == *:* ]]; then
      echo "Refusing to update: got non-IPv6 WAN reply: '$WAN_IP'" >&2
      exit 1
    fi
    ;;
esac

WAN_IP_FILE="$HOME/.cf-wan_ip_${CFRECORD_TYPE}_${CFRECORD_NAME}.txt"
OLD_WAN_IP=""
if [ -f "$WAN_IP_FILE" ]; then
  OLD_WAN_IP="$(cat "$WAN_IP_FILE")"
fi

if [ "$WAN_IP" = "$OLD_WAN_IP" ] && [ "$FORCE" = false ] && [ "$PROXIED_MODE" = "keep" ]; then
  echo "WAN IP unchanged ($WAN_IP), nothing to do. Use -f to force."
  exit 0
fi

# --- resolve zone id + record id --------------------------------------------

ID_FILE="$HOME/.cf-id_${CFRECORD_TYPE}_${CFRECORD_NAME}.txt"
CFZONE_ID=""
CFRECORD_ID=""

if [ -f "$ID_FILE" ] && [ "$(wc -l < "$ID_FILE")" = "4" ] \
  && [ "$(sed -n '3p' "$ID_FILE")" = "$CFZONE_NAME" ] \
  && [ "$(sed -n '4p' "$ID_FILE")" = "$CFRECORD_NAME" ]; then
  CFZONE_ID="$(sed -n '1p' "$ID_FILE")"
  CFRECORD_ID="$(sed -n '2p' "$ID_FILE")"
fi

if [ -z "$CFZONE_ID" ] || [ -z "$CFRECORD_ID" ]; then
  echo "Resolving zone_id / record_id from Cloudflare..."

  # `|| true` so empty/failed lookups don't trip errexit before we can
  # print a helpful message; we explicitly validate below.
  ZONE_JSON="$(curl -fsS --max-time 10 -X GET \
    "$CF_API/zones?name=$CFZONE_NAME" \
    -H "$AUTH_HEADER" -H "Content-Type: application/json" || true)"
  CFZONE_ID="$(printf '%s' "$ZONE_JSON" | jq -r '.result[0].id // empty')"

  if [ -z "$CFZONE_ID" ]; then
    echo "Could not resolve zone '$CFZONE_NAME'." >&2
    echo "Token may lack Zone:Read on this zone, or zone name is wrong." >&2
    echo "Response: $ZONE_JSON" >&2
    exit 1
  fi

  REC_JSON="$(curl -fsS --max-time 10 -X GET \
    "$CF_API/zones/$CFZONE_ID/dns_records?type=$CFRECORD_TYPE&name=$CFRECORD_NAME" \
    -H "$AUTH_HEADER" -H "Content-Type: application/json" || true)"
  CFRECORD_ID="$(printf '%s' "$REC_JSON" | jq -r '.result[0].id // empty')"

  if [ -z "$CFRECORD_ID" ]; then
    echo "Could not find $CFRECORD_TYPE record '$CFRECORD_NAME' in zone '$CFZONE_NAME'." >&2
    echo "Create the record once in the Cloudflare dashboard, then re-run." >&2
    echo "Response: $REC_JSON" >&2
    exit 1
  fi

  {
    echo "$CFZONE_ID"
    echo "$CFRECORD_ID"
    echo "$CFZONE_NAME"
    echo "$CFRECORD_NAME"
  } > "$ID_FILE"
fi

# --- build patch body --------------------------------------------------------

# PATCH only updates fields we send, so untouched attributes (including
# `proxied`) keep their current value. That's the fix for the "PUT silently
# flips orange cloud to grey" footgun.
if [ "$PROXIED_MODE" = "keep" ]; then
  BODY="$(jq -nc --arg ip "$WAN_IP" --argjson ttl "$CFTTL" \
    '{content: $ip, ttl: $ttl}')"
else
  PROXY_BOOL=false
  [ "$PROXIED_MODE" = "on" ] && PROXY_BOOL=true
  BODY="$(jq -nc --arg ip "$WAN_IP" --argjson ttl "$CFTTL" --argjson proxied "$PROXY_BOOL" \
    '{content: $ip, ttl: $ttl, proxied: $proxied}')"
fi

echo "Updating $CFRECORD_NAME ($CFRECORD_TYPE) -> $WAN_IP (proxied: $PROXIED_MODE)"

RESPONSE="$(curl -fsS --max-time 15 -X PATCH \
  "$CF_API/zones/$CFZONE_ID/dns_records/$CFRECORD_ID" \
  -H "$AUTH_HEADER" -H "Content-Type: application/json" \
  --data "$BODY" || true)"

if [ -n "$RESPONSE" ] && printf '%s' "$RESPONSE" | jq -e '.success == true' >/dev/null 2>&1; then
  echo "Updated successfully."
  printf '%s\n' "$WAN_IP" > "$WAN_IP_FILE"
  exit 0
fi

echo "Update failed." >&2
echo "Response: $RESPONSE" >&2
# Cache may be stale (record recreated -> new id). Drop it so next run
# re-resolves from the API.
rm -f "$ID_FILE"
exit 1
