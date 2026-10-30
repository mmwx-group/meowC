package main

import (
	"encoding/json"

	"github.com/metacubex/mihomo/component/speedtest"
)

// MeowX：网络测速。测法在 Clash.Meta/component/speedtest（与 OpenWrt 版共用），这里只把 Dart 的调用接过去：
// meowSpeedTestStart 开始（回空串 = 已开始，否则是原因）、meowSpeedTestStatus 每 300ms 拉一次进度（JSON）、meowSpeedTestStop 取消。
// meowSpeedTestBoard 测速榜的上传 / 删除：经测速用的同一个出站发一次 HTTPS 请求（见 component/speedtest/board.go），回 BoardResponse 的 JSON。

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

// handleMeowSpeedTestBoard 最多阻塞 10 秒，放到 goroutine 里，发完回调
func handleMeowSpeedTestBoard(paramsString string, fn func(string)) {
	go func() {
		var req speedtest.BoardRequest
		resp := speedtest.BoardResponse{Error: "参数无效"}
		if err := json.Unmarshal([]byte(paramsString), &req); err == nil {
			resp = speedtest.BoardSend(req)
		}
		data, _ := json.Marshal(resp)
		fn(string(data))
	}()
}
