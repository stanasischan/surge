/* Surge DNS Script for macOS
功能：在家 (lovelife_5G) 使用 Mac mini (198.18.0.2) 作为 DNS 服务器
*/

// 安全获取 SSID，如果读不到（无权限）则默认为空字符串，防止报错
var wifiname = $network.wifi.ssid || "";
var proxywifi = ["lovelife_4G", "lovelife_5G"];

// 标记是否匹配到家庭网络
var matched = false;

for (var i = 0; i < proxywifi.length; i++) {
    if (wifiname === proxywifi[i]) {
        // 匹配成功！
        // 指示 Surge 向 198.18.0.2 发起 DNS 查询
        // 注意：确保 macOS 开启了增强模式，否则可能无法路由到 198.18 网段
        $done({ server: '198.18.0.2' });
        matched = true;
        break;
    }
}

// 循环结束，如果没有匹配到任何家庭 WiFi
if (!matched) {
    // 走系统或 Surge 默认 DNS
    $done({});
}
