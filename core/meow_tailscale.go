package main

import (
	"context"
	"encoding/json"
	"time"

	"github.com/metacubex/mihomo/adapter/outbound"
)

// MeowX：按出站名取 tailscale 出站（喵窝 / 订阅里的组网节点）的状态（见 Clash.Meta/adapter/outbound/tailscale_status.go）。
// 出站是懒启动的，问状态时内核会先启动它——客户端也拿它在配置生效后「叫醒」喵窝节点。

type meowTailscaleStatusParams struct {
	Name string `json:"name"`
	// 毫秒，缺省 5000：等出站启动、本机状态出来的上限
	Timeout int64 `json:"timeout"`
}

type meowTailscaleStatusResult struct {
	// 没有这个出站时为 null
	Status *outbound.TailscaleStatus `json:"status"`
	Error  string                    `json:"error,omitempty"`
}

// handleMeowTailscaleStatus 可能要等出站启动，放到 goroutine 里，取完回调（JSON）
func handleMeowTailscaleStatus(paramsString string, fn func(string)) {
	go func() {
		var params meowTailscaleStatusParams
		res := meowTailscaleStatusResult{}
		if err := json.Unmarshal([]byte(paramsString), &params); err != nil || params.Name == "" {
			res.Error = "参数无效"
		} else {
			timeout := time.Duration(params.Timeout) * time.Millisecond
			if timeout <= 0 {
				timeout = 5 * time.Second
			}
			ctx, cancel := context.WithTimeout(context.Background(), timeout)
			st, err := outbound.TailscaleStatusByName(ctx, params.Name)
			cancel()
			if err != nil {
				res.Error = err.Error()
			}
			res.Status = st
		}
		data, _ := json.Marshal(res)
		fn(string(data))
	}()
}
