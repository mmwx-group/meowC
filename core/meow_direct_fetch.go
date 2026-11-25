package main

import (
	"context"
	"crypto/tls"
	"encoding/base64"
	"encoding/json"
	"errors"
	"io"
	"net"
	"net/http"
	"strings"
	"time"

	"github.com/metacubex/mihomo/component/dialer"
	"github.com/metacubex/mihomo/component/resolver"
)

// MeowX：拉订阅「直连」那一路由内核发（Windows / Linux，Dart 侧见 lib/common/request.dart 的 _vpnBypassDirect）。
//
// 虚拟网卡开着时 Dart 的「直连」也进了虚拟网卡、被内核按规则送进代理节点。账号的节点全是只认白名单 IP 的服务器、
// 「白名单节点经喵窝连线」又关着时节点全连不上，主控跟着连不上，再打开开关也拉不回喵窝版节点（规格
// miaomiaowuC/Design/meshnet-whitelist-direct.md）。这里走与 po0 上报同一条直连路（meow_po0.go）：mihomo 的直连
// dialer（TUN 下绑物理网卡）+ DirectHostResolver 解析，不进虚拟网卡、不走经节点查的 DNS。
//
// 参数 {url, headers: {名: 值}, insecure, timeout_ms}；成功回 {status, url, headers: {小写名: [值]}, body: base64}，
// 连接层失败回 {error}（Dart 据此换下一条路）。

type meowDirectFetchParams struct {
	URL       string            `json:"url"`
	Headers   map[string]string `json:"headers"`
	Insecure  bool              `json:"insecure"`
	TimeoutMs int64             `json:"timeout_ms"`
}

const (
	meowDirectFetchMethod         Method = "meowDirectFetch"
	meowDirectFetchLimit                 = 64 << 20
	meowDirectFetchMaxRedirects          = 5
	meowDirectFetchDefaultTimeout        = 40 * time.Second
)

func handleMeowDirectFetch(paramsString string, fn func(string)) {
	go func() {
		var p meowDirectFetchParams
		var out any
		if err := json.Unmarshal([]byte(paramsString), &p); err != nil || p.URL == "" {
			out = map[string]string{"error": "参数无效"}
		} else {
			out = meowDirectFetch(p)
		}
		data, err := json.Marshal(out)
		if err != nil {
			fn(`{"error":"参数无效"}`)
			return
		}
		fn(string(data))
	}()
}

func meowDirectFetch(p meowDirectFetchParams) any {
	timeout := time.Duration(p.TimeoutMs) * time.Millisecond
	if timeout <= 0 {
		timeout = meowDirectFetchDefaultTimeout
	}
	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	defer cancel()
	client := &http.Client{
		Transport: &http.Transport{
			Proxy: nil, // 不读环境变量里的代理
			DialContext: func(ctx context.Context, network, addr string) (net.Conn, error) {
				opts := []dialer.Option{}
				if resolver.DirectHostResolver != nil {
					opts = append(opts, dialer.WithResolver(resolver.DirectHostResolver))
				}
				return dialer.DialContext(ctx, network, addr, opts...)
			},
			TLSClientConfig:   &tls.Config{InsecureSkipVerify: p.Insecure},
			ForceAttemptHTTP2: true,
			DisableKeepAlives: true,
		},
		// 跳到别的站点时 net/http 自己去掉 Authorization / Cookie
		CheckRedirect: func(_ *http.Request, via []*http.Request) error {
			if len(via) > meowDirectFetchMaxRedirects {
				return errors.New("跳转次数过多")
			}
			return nil
		},
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, p.URL, nil)
	if err != nil {
		return map[string]string{"error": "无效的订阅地址"}
	}
	for k, v := range p.Headers {
		if strings.EqualFold(k, "host") {
			continue
		}
		req.Header.Set(k, v)
	}
	resp, err := client.Do(req)
	if err != nil {
		return map[string]string{"error": err.Error()}
	}
	defer resp.Body.Close()
	body, err := io.ReadAll(io.LimitReader(resp.Body, meowDirectFetchLimit+1))
	if err != nil {
		return map[string]string{"error": err.Error()}
	}
	if len(body) > meowDirectFetchLimit {
		return map[string]string{"error": "订阅内容过大"}
	}
	headers := make(map[string][]string, len(resp.Header))
	for k, v := range resp.Header {
		headers[strings.ToLower(k)] = v
	}
	return map[string]any{
		"status":  resp.StatusCode,
		"url":     resp.Request.URL.String(),
		"headers": headers,
		"body":    base64.StdEncoding.EncodeToString(body),
	}
}
