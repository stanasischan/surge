var proxywifi = ["lovelifeasus","lovelifeasus_5G"];
for (var i = 0; i < proxywifi.length; i++) {
	if ($network.wifi.ssid==proxywifi[i]){		 $done({ server:'198.18.0.2' })
	
		break;
		
	};
	if (i==proxywifi.length-1){
	  $done({})
	  };
};
$done();


		

/*#单wifi
if ($network.wifi.ssid === 'lovelifeasus_5G') {
  $done({ server: '198.18.0.2' })
} else {
  $done({})
}
*/