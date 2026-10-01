package main

import (
	"context"
	"crypto/tls"
	"encoding/json"
	"io"
	"net"
	"net/http"
	"sync"
	"time"

	"github.com/metacubex/mihomo/component/dialer"
	"github.com/metacubex/mihomo/component/resolver"
	"github.com/metacubex/mihomo/log"
)

// MeowX：po0 客户端 IP 加白上报。
//
// po0 只把「发出请求的来源 IP」加进白名单，所以这个 POST 必须直连、绝不能经代理——
// 在 Dart 侧发会被 Bettbox 全局 HttpOverrides 指到本地混合端口（Windows），Android 上 App 自己的流量也在 VPN 里。
// 这里走 mihomo 的直连 dialer（与 DIRECT 出站同一条路：Android 由 DefaultSocketHook protect 出 VPN，
// Windows TUN 下由 sing-tun 的 DefaultInterfaceFinder 绑到物理网卡；系统代理模式 Go 的 socket 本来就不认系统代理），
// 并用 DirectHostResolver 解析（url 里一般直接是 IP）。po0 证书多半自签，跳过校验。

type Po0ReportParams struct {
	Urls []string `json:"urls"`
}

type Po0ReportResult struct {
	Url    string `json:"url"`
	Status int    `json:"status"`
	Body   string `json:"body,omitempty"`
	Error  string `json:"error,omitempty"`
}

const (
	meowPo0Timeout     = 10 * time.Second
	meowPo0MaxBodySize = 4096
)

func meowPo0Client() *http.Client {
	return &http.Client{
		Timeout: meowPo0Timeout,
		Transport: &http.Transport{
			Proxy: nil, // 不读环境变量里的代理
			DialContext: func(ctx context.Context, network, addr string) (net.Conn, error) {
				opts := []dialer.Option{}
				if resolver.DirectHostResolver != nil {
					opts = append(opts, dialer.WithResolver(resolver.DirectHostResolver))
				}
				return dialer.DialContext(ctx, network, addr, opts...)
			},
			TLSClientConfig:   &tls.Config{InsecureSkipVerify: true},
			DisableKeepAlives: true,
		},
	}
}

func meowPo0ReportOne(client *http.Client, url string) Po0ReportResult {
	res := Po0ReportResult{Url: url}
	req, err := http.NewRequest(http.MethodPost, url, nil)
	if err != nil {
		res.Error = err.Error()
		return res
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("User-Agent", "MeowX")
	resp, err := client.Do(req)
	if err != nil {
		res.Error = err.Error()
		return res
	}
	defer resp.Body.Close()
	res.Status = resp.StatusCode
	body, _ := io.ReadAll(io.LimitReader(resp.Body, meowPo0MaxBodySize))
	res.Body = string(body)
	return res
}

// handleMeowPo0Report 并发向每个 url 发一次空 body 的 POST，逐个返回状态码与响应体 / 错误。
func handleMeowPo0Report(paramsString string, fn func(string)) {
	go func() {
		var params Po0ReportParams
		if err := json.Unmarshal([]byte(paramsString), &params); err != nil {
			fn("[]")
			return
		}
		results := make([]Po0ReportResult, len(params.Urls))
		client := meowPo0Client()
		var wg sync.WaitGroup
		for i, u := range params.Urls {
			wg.Add(1)
			go func(i int, u string) {
				defer wg.Done()
				results[i] = meowPo0ReportOne(client, u)
				if results[i].Error != "" {
					log.Warnln("[MeowX] po0 report %s: %s", u, results[i].Error)
				}
			}(i, u)
		}
		wg.Wait()
		data, err := json.Marshal(results)
		if err != nil {
			fn("[]")
			return
		}
		fn(string(data))
	}()
}
