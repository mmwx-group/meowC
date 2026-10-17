package main

import (
	"encoding/json"

	"github.com/metacubex/mihomo/component/speedtest"
)

// MeowX：网络测速。测法在 Clash.Meta/component/speedtest（与 OpenWrt 版共用），这里只把 Dart 的调用接过去：
// meowSpeedTestStart 开始（回空串 = 已开始，否则是原因）、meowSpeedTestStatus 每 300ms 拉一次进度（JSON）、meowSpeedTestStop 取消。

func handleMeowSpeedTestStart(paramsString string) string {
	var params speedtest.Params
	if err := json.Unmarshal([]byte(paramsString), &params); err != nil {
		return "参数无效"
	}
	return speedtest.Start(params)
}

func handleMeowSpeedTestStatus() string {
	data, _ := json.Marshal(speedtest.Status())
	return string(data)
}

func handleMeowSpeedTestStop() {
	speedtest.Stop()
}
