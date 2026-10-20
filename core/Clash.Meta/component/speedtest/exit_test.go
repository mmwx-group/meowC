package speedtest

import (
	"context"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/metacubex/mihomo/adapter"
	"github.com/metacubex/mihomo/adapter/outbound"
)

// 2026-10 实拍的 speed.cloudflare.com/meta（IP 换成文档地址）
const sampleMeta = `{"hostname":"speed.cloudflare.com","clientIp":"203.0.113.8","httpProtocol":"HTTP/1.1","asn":2516,
"asOrganization":"KDDI CORPORATION ","country":"JP","city":"Tokyo","postalCode":"151-0053","latitude":"35.6893","longitude":"139.6899",
"colo":{"iata":"NRT","lat":35.764702,"lon":140.386002,"cca2":"JP","region":"Asia Pacific","city":"Tokyo"}}`

func TestParseExit(t *testing.T) {
	info, err := speedParseExit([]byte(sampleMeta))
	if err != nil {
		t.Fatal(err)
	}
	want := ExitInfo{IP: "203.0.113.8", ASN: 2516, Org: "KDDI CORPORATION", Country: "JP"}
	if *info != want {
		t.Fatalf("got %+v, want %+v", *info, want)
	}

	// asn 写成字符串（可带 AS 前缀）也认
	info, err = speedParseExit([]byte(`{"clientIp":"2001:db8::1","asn":"AS4134","colo":"SHA"}`))
	if err != nil {
		t.Fatal(err)
	}
	if info.ASN != 4134 || info.IP != "2001:db8::1" {
		t.Fatalf("got %+v", *info)
	}

	// 拿到 {}：没有出口 IP 算失败；不是 JSON 也失败
	for _, bad := range []string{`{}`, `not json`, `{"asn":13335}`} {
		if _, err := speedParseExit([]byte(bad)); err == nil {
			t.Fatalf("%q 应解析失败", bad)
		}
	}
}

func TestFetchExit(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Referer") == "" {
			w.WriteHeader(http.StatusForbidden) // 同真实 Cloudflare：不带 Referer 回 403 + {}
			_, _ = w.Write([]byte(`{}`))
			return
		}
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(sampleMeta))
	}))
	defer server.Close()

	// 经出站拨号（与测速同一个客户端），这里用 DIRECT
	client := speedClient(adapter.NewProxy(outbound.NewDirect()), false)
	info, err := speedFetchExit(context.Background(), client, server.URL+"/meta")
	if err != nil {
		t.Fatal(err)
	}
	if info.IP != "203.0.113.8" || info.ASN != 2516 || info.Org != "KDDI CORPORATION" {
		t.Fatalf("got %+v", *info)
	}

	// 非 200 → 失败
	notFound := httptest.NewServer(http.NotFoundHandler())
	defer notFound.Close()
	if _, err := speedFetchExit(context.Background(), client, notFound.URL); err == nil {
		t.Fatal("404 应失败")
	}
}

func TestFetchExitTimeout(t *testing.T) {
	release := make(chan struct{})
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		select {
		case <-release:
		case <-r.Context().Done():
		}
	}))
	defer server.Close()
	defer close(release)

	// 外层 context 先到点也要立刻返回（真实的上限是 speedExitTimeout = 5s）
	ctx, cancel := context.WithTimeout(context.Background(), 200*time.Millisecond)
	defer cancel()
	start := time.Now()
	if _, err := speedFetchExit(ctx, http.DefaultClient, server.URL); err == nil {
		t.Fatal("应超时失败")
	}
	if time.Since(start) > 2*time.Second {
		t.Fatalf("超时没有生效：等了 %v", time.Since(start))
	}
}

// 查到的出口写进进度、清掉 exitPending；查不到也清掉 exitPending、不写出口；跑的不是这一次（runID 不对）就不写
func TestQueryExitUpdatesProgress(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = w.Write([]byte(sampleMeta))
	}))
	defer server.Close()
	saved := speedExitURL
	defer func() { speedExitURL = saved }()
	direct := adapter.NewProxy(outbound.NewDirect())
	reset := func(runID int) {
		speedState.Lock()
		speedState.progress = Progress{RunID: runID, Phase: "download", ExitPending: true}
		speedState.Unlock()
	}
	defer func() {
		speedState.Lock()
		speedState.progress = Progress{Phase: "idle"}
		speedState.Unlock()
	}()

	speedExitURL = server.URL + "/meta"
	reset(7)
	speedQueryExit(context.Background(), 7, direct)
	if got := Status(); got.ExitPending || got.Exit == nil || got.Exit.ASN != 2516 || got.Exit.IP != "203.0.113.8" {
		t.Fatalf("got %+v", got)
	}

	reset(8)
	speedQueryExit(context.Background(), 7, direct)
	if got := Status(); !got.ExitPending || got.Exit != nil {
		t.Fatalf("别的 runID 不该写进来：%+v", got)
	}

	dead := httptest.NewServer(http.NotFoundHandler())
	speedExitURL = dead.URL + "/meta" // 关掉的服务器：连不上
	dead.Close()
	reset(9)
	speedQueryExit(context.Background(), 9, direct)
	if got := Status(); got.ExitPending || got.Exit != nil {
		t.Fatalf("查不到时应清掉 exitPending、不写出口：%+v", got)
	}
}
