/* wifi_proxy change (Made by Meeta)
文本编辑模式下复制粘贴,TG频道已发操作教程视频
event network-changed debug=1,script-path=wifi_proxy.js
PS:记得自己修改WIFI名称
虽然设置SSID可以达到基本相同功能
使用脚本,Surge不会被suspend
Rewrite和Scripting依然有效
https://meetagit.github.io/MeetaRules/Surge/Scripting/wifi_proxy.js
TG频道:@meetashare
*/
/*#单wifi代码
var wifiname = $network.wifi.ssid;
var proxywifi = "lovelife_5G";
if (wifiname == proxywifi){
    $surge.setOutboundMode("direct");
//    $notification.post("SSID ON","Surge Direct Mode","");
    
}
else{
    $surge.setOutboundMode("rule");
//    $notification.post("SSID OFF","Surge Rules Mode","");
}
$done();*/

var wifiname = $network.wifi.ssid;
var proxywifi = ["lovelife","lovelife_5G"];

for (var i = 0; i < proxywifi.length; i++) {
	if (wifiname==proxywifi[i]){
		$surge.setOutboundMode("direct");
		
//		setTimeout(function(){$notification.post("Meeta_Remind","您目前处于WIFI-Proxy"+"SSID: "+wifiname,"Surge已自动变为直连模式");}, 3000);
		break;
		
	};
	if (i==proxywifi.length-1){
		$surge.setOutboundMode("rule");
		
//		setTimeout(function(){$notification.post("Meeta_Remind","Surge已自动变为规则模式","");}, 3000);
	
	}
	
	
};
$done();

