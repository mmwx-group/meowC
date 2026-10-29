package main

import (
	"crypto/x509"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"
)

// 测试里只用假 token。
const meowGgyTestToken = "ctecsfw_TESTtoken0000000000AAAA"

// 日志里的上报地址 / url.Error 只留脱敏 token（与 Dart 端 maskGgyToken 同一写法）。
func TestMeowGgyRedact(t *testing.T) {
	cases := map[string]string{
		`Get "https://www.guguyun.com/cany_tencentecs/firewall/whitelist?token=` + meowGgyTestToken + `": dial tcp: i/o timeout`: `Get "https://www.guguyun.com/cany_tencentecs/firewall/whitelist?token=ctecsfw_••••AAAA": dial tcp: i/o timeout`,
		"https://www.guguyun.com/x?token=abcdefgh1234": "https://www.guguyun.com/x?token=••••1234",
		"no token here": "no token here",
	}
	for in, want := range cases {
		if got := meowGgyRedact(in); got != want {
			t.Errorf("meowGgyRedact(%q) = %q, want %q", in, got, want)
		}
	}
}

type meowGgySeen struct {
	method, accept, contentType, acceptEncoding string
	hasUA, close                                bool
	length                                      int64
}

func meowGgyServer(t *testing.T) (*httptest.Server, func() meowGgySeen) {
	var mu sync.Mutex
	var seen meowGgySeen
	srv := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		mu.Lock()
		_, hasUA := r.Header["User-Agent"]
		seen = meowGgySeen{
			method: r.Method, accept: r.Header.Get("Accept"), contentType: r.Header.Get("Content-Type"),
			acceptEncoding: r.Header.Get("Accept-Encoding"), hasUA: hasUA, close: r.Close, length: r.ContentLength,
		}
		mu.Unlock()
		_, _ = io.Copy(io.Discard, r.Body)
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"status":400,"msg":"白名单分享链接无效或已失效","data":[]}`))
	}))
	t.Cleanup(srv.Close)
	return srv, func() meowGgySeen {
		mu.Lock()
		defer mu.Unlock()
		return seen
	}
}

// GGY 请求：GET、不带 body，头只有 Accept: application/json + Connection: close（没有 UA / Content-Type / Accept-Encoding）。
func TestMeowGgyRequestShape(t *testing.T) {
	srv, seen := meowGgyServer(t)
	roots := x509.NewCertPool()
	roots.AddCert(srv.Certificate())
	res := meowGgyReportOne(meowGgyClient(roots), srv.URL+"/cany_tencentecs/firewall/whitelist?token="+meowGgyTestToken)
	if res.Error != "" || res.Status != 200 {
		t.Fatalf("result = %+v", res)
	}
	if !strings.Contains(res.Body, `"status":400`) {
		t.Errorf("body = %q", res.Body)
	}
	s := seen()
	if s.method != http.MethodGet || s.accept != "application/json" || s.contentType != "" || s.acceptEncoding != "" ||
		s.hasUA || !s.close || s.length != 0 {
		t.Errorf("request = %+v", s)
	}
}

func meowGgyInvoke(t *testing.T, params string) []Po0ReportResult {
	t.Helper()
	ch := make(chan string, 1)
	handleMeowPo0Report(params, func(v string) { ch <- v })
	select {
	case raw := <-ch:
		var out []Po0ReportResult
		if err := json.Unmarshal([]byte(raw), &out); err != nil {
			t.Fatalf("unmarshal %q: %v", raw, err)
		}
		return out
	case <-time.After(15 * time.Second):
		t.Fatal("timeout")
		return nil
	}
}

// kind=ggy 走 GET + 证书校验（自签证书连不上）；不带 kind 仍是 po0 的 POST + 跳过校验。
func TestMeowGgyKindDispatch(t *testing.T) {
	srv, seen := meowGgyServer(t)
	url := srv.URL + "/cany_tencentecs/firewall/whitelist?token=" + meowGgyTestToken

	ggy := meowGgyInvoke(t, `{"kind":"ggy","urls":["`+url+`"]}`)
	if len(ggy) != 1 || ggy[0].Status != 0 || !strings.Contains(ggy[0].Error, "certificate") {
		t.Errorf("ggy result = %+v", ggy)
	}

	po0 := meowGgyInvoke(t, `{"urls":["`+url+`"]}`)
	if len(po0) != 1 || po0[0].Status != 200 || po0[0].Error != "" {
		t.Errorf("po0 result = %+v", po0)
	}
	if s := seen(); s.method != http.MethodPost {
		t.Errorf("po0 method = %q", s.method)
	}
}
