package main

import (
	"context"
	"crypto/tls"
	"crypto/x509"
	"io"
	"net"
	"net/http"
	"regexp"
	"strings"

	"github.com/metacubex/mihomo/component/ca"
	"github.com/metacubex/mihomo/component/dialer"
	"github.com/metacubex/mihomo/component/resolver"
)

// MeowX：GGY（咕咕云）客户端 IP 加白上报。
//
// GGY 的白名单分享链接（`https://www.guguyun.com/cany_tencentecs/firewall/whitelist?token=<token>`）谁打开就把谁的
// 公网 IP 加进防火墙白名单，所以和 po0 一样必须直连：复用 po0 的 `meowPo0Report` 通道（参数带 `"kind":"ggy"`），
// 不另登记 action，免得动 Bettbox 层的方法表。与 po0 的区别：GET、不带 body，头只要 Host / Accept / Connection: close，
// 证书照常校验（系统根证书 + mihomo 内置的 Mozilla 根证书，同订阅拉取）。成败看应答 JSON 里的 status，由 Dart 端判断。

const meowReportKindGgy = "ggy"

func meowGgyClient(roots *x509.CertPool) *http.Client {
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
			TLSClientConfig:    &tls.Config{RootCAs: roots},
			DisableKeepAlives:  true, // 请求头带 Connection: close
			DisableCompression: true, // 不加 Accept-Encoding
		},
	}
}

func meowGgyReportOne(client *http.Client, url string) Po0ReportResult {
	res := Po0ReportResult{Url: url}
	req, err := http.NewRequest(http.MethodGet, url, nil)
	if err != nil {
		res.Error = err.Error()
		return res
	}
	req.Header.Set("Accept", "application/json")
	// 显式设成空串 = 不发 User-Agent（否则 Go 会补 Go-http-client/1.1）
	req.Header.Set("User-Agent", "")
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

var meowGgyTokenParam = regexp.MustCompile(`token=[A-Za-z0-9_-]*`)

// meowGgyRedact 把上报地址里 `token=<token>` 换成脱敏写法（同 Dart 端 maskGgyToken：含 `_` 时留第一个 `_` 及之前，
// 再加 `••••` + 最后 4 个字符；不含 `_` 时 `••••` + 最后 4 个字符）。
func meowGgyRedact(s string) string {
	return meowGgyTokenParam.ReplaceAllStringFunc(s, func(m string) string {
		return "token=" + meowGgyMask(strings.TrimPrefix(m, "token="))
	})
}

func meowGgyMask(token string) string {
	tail := token
	if len(tail) > 4 {
		tail = tail[len(tail)-4:]
	}
	if i := strings.Index(token, "_"); i >= 0 {
		return token[:i+1] + "••••" + tail
	}
	return "••••" + tail
}

// meowGgyRoots：GGY 证书校验用的根证书。
func meowGgyRoots() *x509.CertPool { return ca.GetCertPool() }
