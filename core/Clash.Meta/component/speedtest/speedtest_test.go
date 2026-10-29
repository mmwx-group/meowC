package speedtest

import (
	"context"
	"fmt"
	"os"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/metacubex/mihomo/adapter"
	"github.com/metacubex/mihomo/adapter/outbound"
	C "github.com/metacubex/mihomo/constant"
)

func TestMbps(t *testing.T) {
	if v := speedMbps(1_250_000, 100*time.Millisecond); v < 99.99 || v > 100.01 {
		t.Fatalf("1.25MB/0.1s = %v, want 100", v)
	}
	if speedMbps(0, time.Second) != 0 || speedMbps(100, 0) != 0 {
		t.Fatal("零字节 / 零时长应为 0")
	}
}

func TestGoogleRanges(t *testing.T) {
	ep, err := speedResolve(context.Background(), "google", nil)
	if err != nil {
		t.Fatal(err)
	}
	seen := map[string]bool{}
	for round := 0; round < 10; round++ {
		for conn := 0; conn < 8; conn++ {
			seen[ep.download(conn, round, 8).headers["Range"]] = true
		}
	}
	if want := int(speedGoogleSize / speedRangeChunk); len(seen) != want {
		t.Fatalf("用到 %d 段，want %d", len(seen), want)
	}
	if ep.hasUpload {
		t.Fatal("Google 不测上传")
	}
}

// Microsoft 的文件只有 3 段完整的 32MB：所有 Range 都在文件之内（不会 416）、各连接与各轮次轮流取遍 3 段
func TestMicrosoftRanges(t *testing.T) {
	ep, err := speedResolve(context.Background(), "microsoft", nil)
	if err != nil {
		t.Fatal(err)
	}
	if ep.server != speedMicrosoftHost || ep.hasUpload {
		t.Fatalf("server %q hasUpload %v", ep.server, ep.hasUpload)
	}
	if got := ep.latency.headers["Range"]; got != "bytes=0-0" || ep.latency.path != speedMicrosoftPath {
		t.Fatalf("延迟请求 %q %q", ep.latency.path, got)
	}
	chunks := int(speedMicrosoftSize / speedRangeChunk)
	if chunks != 3 {
		t.Fatalf("%d 段，want 3", chunks)
	}
	for _, conns := range []int{1, 8} {
		seen := map[string]int{}
		for conn := 0; conn < conns; conn++ {
			// 单独一条连接上连续几轮也要换段（不是一直读同一段）
			own := map[string]bool{}
			for round := 0; round < 12; round++ {
				target := ep.download(conn, round, conns)
				if target.host != speedMicrosoftHost || target.path != speedMicrosoftPath {
					t.Fatalf("地址 %s%s", target.host, target.path)
				}
				var begin, end int64
				if _, err := fmt.Sscanf(target.headers["Range"], "bytes=%d-%d", &begin, &end); err != nil {
					t.Fatal(err)
				}
				if begin < 0 || end >= speedMicrosoftSize || end-begin+1 != speedRangeChunk || begin%speedRangeChunk != 0 {
					t.Fatalf("Range %d-%d 越界或不整段", begin, end)
				}
				seen[target.headers["Range"]]++
				own[target.headers["Range"]] = true
			}
			if len(own) != chunks {
				t.Fatalf("×%d 第 %d 条连接只用到 %d 段", conns, conn, len(own))
			}
		}
		// 每段被取的次数相同（轮转均匀）
		for r, n := range seen {
			if n != conns*12/chunks {
				t.Fatalf("×%d %s 取了 %d 次，want %d", conns, r, n, conns*12/chunks)
			}
		}
	}
}

func TestUnknownNode(t *testing.T) {
	if reason := Start(Params{Source: "google", Proxy: "不存在"}); reason == "" {
		t.Fatal("找不到节点应直接回原因")
	}
}

// SPEEDTEST_LIVE=1 go test ./component/speedtest -run Live -v：经直连把五个源各跑一次（单线程 + 8 线程）
func TestLiveSources(t *testing.T) {
	if os.Getenv("SPEEDTEST_LIVE") != "1" {
		t.Skip("SPEEDTEST_LIVE=1 才跑")
	}
	// SPEEDTEST_SS=host:port:password（aes-128-gcm）：经这个 SS 节点测（缺省直连）
	var proxy C.Proxy = adapter.NewProxy(outbound.NewDirect())
	if ss := os.Getenv("SPEEDTEST_SS"); ss != "" {
		parts := strings.SplitN(ss, ":", 3)
		port, _ := strconv.Atoi(parts[1])
		p, err := adapter.ParseProxy(map[string]any{"name": "node", "type": "ss", "server": parts[0], "port": port,
			"cipher": "aes-128-gcm", "password": parts[2]})
		if err != nil {
			t.Fatal(err)
		}
		proxy = p
	}
	sources := []string{"google", "microsoft", "apple", "speedtest", "cloudflare"}
	if only := os.Getenv("SPEEDTEST_SOURCE"); only != "" {
		sources = []string{only}
	}
	for _, source := range sources {
		for _, conns := range []int{1, 8} {
			speedState.Lock()
			runID := speedState.progress.RunID + 1
			speedState.progress = Progress{RunID: runID, Phase: "preparing", Source: source}
			speedState.Unlock()
			speedRun(context.Background(), runID, source, proxy, conns)
			p := Status()
			f := func(v *float64) float64 {
				if v == nil {
					return -1
				}
				return *v
			}
			lat := -1
			if p.LatencyMs != nil {
				lat = *p.LatencyMs
			}
			t.Logf("[%s ×%d] %s 服务器 %s 延迟 %dms 下载 %.1f（峰 %.1f） 上传 %.1f 流量 %dMB %s",
				source, conns, p.Phase, p.Server, lat, f(p.DownloadMbps), f(p.DownloadPeakMbps), f(p.UploadMbps), p.BytesUsed/1_000_000, p.Error)
			if p.Phase != "done" || f(p.DownloadMbps) <= 0 || len(p.DownloadSamples) == 0 {
				t.Errorf("%s ×%d 没有测完：%s", source, conns, p.Error)
			}
			time.Sleep(2 * time.Second)
		}
	}
}
