package speedtest

import (
	"context"
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
	if want := int(speedGoogleSize / speedGoogleChunk); len(seen) != want {
		t.Fatalf("用到 %d 段，want %d", len(seen), want)
	}
	if ep.hasUpload {
		t.Fatal("Google 不测上传")
	}
}

func TestUnknownNode(t *testing.T) {
	if reason := Start(Params{Source: "google", Proxy: "不存在"}); reason == "" {
		t.Fatal("找不到节点应直接回原因")
	}
}

// SPEEDTEST_LIVE=1 go test ./component/speedtest -run Live -v：经直连把四个源各跑一次（单线程 + 8 线程）
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
	sources := []string{"google", "apple", "speedtest", "cloudflare"}
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
