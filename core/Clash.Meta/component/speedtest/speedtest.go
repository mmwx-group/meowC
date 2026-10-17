package speedtest

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"math/rand"
	"net"
	"net/http"
	"sort"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/metacubex/mihomo/adapter/outboundgroup"
	"github.com/metacubex/mihomo/constant"
	"github.com/metacubex/mihomo/log"
	"github.com/metacubex/mihomo/tunnel"
	"github.com/metacubex/mihomo/tunnel/statistic"
)

// Package speedtest 是 MeowX 的网络测速（与 iOS / macOS 的 SpeedTestRunner 同一套测法），
// meowC（Android / Windows，经 Bettbox 桥 core/meow_speedtest.go）与 OpenWrt 版（经 external controller 的 /speedtest）共用。
//
// 经用户选定的**节点**直接拨号连测速服务器（proxy.DialContext，不经分流规则、不经 TUN / 本地混合端口）：
// 先测延迟（同一条已建好的连接上连发小请求、取中位数），再下载、上传各 10 秒（单线程或多线程），
// 结果取去掉前 2 秒（TCP 慢启动）后的平均值，峰值取 1 秒窗口。收到的数据边读边丢，字节数记进 mihomo 的流量统计
// （首页网速曲线看得到）。调用方 Start 开始、Status 轮询进度（约 300ms 一次）、Stop 取消；同一时间只跑一次。
//
// 四个源：Google（dl.google.com 上约 1GB 的安装包，32MB 一段 Range，只测下载）/ Apple（mensura.cdn-apple.com，
// 系统 networkQuality 同一组地址）/ Speedtest（经节点向 speedtest.net 要离节点出口最近的服务器）/ Cloudflare。

type Params struct {
	Source      string `json:"source"`
	Proxy       string `json:"proxy"`
	Connections int    `json:"connections"`
}

type Progress struct {
	RunID            int       `json:"runID"`
	Phase            string    `json:"phase"` // idle preparing latency download upload done failed cancelled
	Source           string    `json:"source,omitempty"`
	Via              string    `json:"via,omitempty"`
	Server           string    `json:"server,omitempty"`
	LatencyMs        *int      `json:"latencyMs,omitempty"`
	DownloadMbps     *float64  `json:"downloadMbps,omitempty"`
	UploadMbps       *float64  `json:"uploadMbps,omitempty"`
	DownloadPeakMbps *float64  `json:"downloadPeakMbps,omitempty"`
	UploadPeakMbps   *float64  `json:"uploadPeakMbps,omitempty"`
	CurrentMbps      float64   `json:"currentMbps"`
	DownloadSamples  []float64 `json:"downloadSamples"`
	UploadSamples    []float64 `json:"uploadSamples"`
	PhaseProgress    float64   `json:"phaseProgress"`
	BytesUsed        int64     `json:"bytesUsed"`
	Error            string    `json:"error,omitempty"`
}

const (
	speedPhaseDuration = 10 * time.Second
	speedWarmup        = 2 * time.Second
	speedSampleEvery   = 250 * time.Millisecond
	speedLatencyRounds = 6

	speedGoogleHost  = "dl.google.com"
	speedGooglePath  = "/dl/android/studio/install/3.4.1.0/android-studio-ide-183.5522156-windows.exe"
	speedGoogleSize  = int64(1_018_566_480)
	speedGoogleChunk = int64(32 * 1024 * 1024)
)

var speedState = struct {
	sync.Mutex
	progress Progress
	cancel   context.CancelFunc
}{progress: Progress{Phase: "idle"}}

func speedUpdate(runID int, change func(p *Progress)) {
	speedState.Lock()
	defer speedState.Unlock()
	if speedState.progress.RunID != runID || speedState.progress.Phase == "cancelled" {
		return
	}
	change(&speedState.progress)
}

// Start 开始一次测速（已有一次在跑就先取消它）。回空串 = 已开始，否则是没能开始的原因。
func Start(params Params) string {
	proxy := FindNode(params.Proxy)
	if proxy == nil {
		return "找不到节点 " + params.Proxy
	}
	connections := params.Connections
	if connections < 1 {
		connections = 1
	} else if connections > 16 {
		connections = 16
	}
	ctx, cancel := context.WithCancel(context.Background())
	speedState.Lock()
	if speedState.cancel != nil {
		speedState.cancel()
	}
	runID := speedState.progress.RunID + 1
	speedState.progress = Progress{RunID: runID, Phase: "preparing", Source: params.Source, Via: params.Proxy,
		DownloadSamples: []float64{}, UploadSamples: []float64{}}
	speedState.cancel = cancel
	speedState.Unlock()
	go speedRun(ctx, runID, params.Source, proxy, connections)
	return ""
}

// Status 当前进度（idle 表示还没测过）。
func Status() Progress {
	speedState.Lock()
	defer speedState.Unlock()
	return speedState.progress
}

// Stop 取消正在跑的测速。
func Stop() {
	speedState.Lock()
	defer speedState.Unlock()
	if speedState.cancel != nil {
		speedState.cancel()
		speedState.cancel = nil
	}
	switch speedState.progress.Phase {
	case "preparing", "latency", "download", "upload":
		speedState.progress.Phase = "cancelled"
		speedState.progress.CurrentMbps = 0
	}
}

// FindNode 按名字找节点（含 provider 里的）；代理组（select / url-test / fallback / load-balance / relay）不算，返回 nil。
func FindNode(name string) constant.Proxy {
	proxy, ok := tunnel.Proxies()[name]
	if !ok {
		for _, provider := range tunnel.Providers() {
			for _, p := range provider.Proxies() {
				if p.Name() == name {
					proxy, ok = p, true
				}
			}
		}
	}
	if !ok || proxy == nil {
		return nil
	}
	if _, isGroup := proxy.Adapter().(outboundgroup.ProxyGroup); isGroup {
		return nil
	}
	return proxy
}

// MARK: - 流程

type speedEndpoints struct {
	server      string
	latency     speedTarget
	download    func(conn, round, conns int) speedTarget
	upload      func(conn, round, conns int) speedTarget
	uploadChunk int64
	hasUpload   bool
}

type speedTarget struct {
	method  string
	host    string
	port    int
	path    string
	headers map[string]string
}

func (t speedTarget) url() string {
	if t.port == 443 || t.port == 0 {
		return "https://" + t.host + t.path
	}
	return "https://" + net.JoinHostPort(t.host, strconv.Itoa(t.port)) + t.path
}

func speedRun(ctx context.Context, runID int, source string, proxy constant.Proxy, connections int) {
	var used atomic.Int64
	fail := func(err error) {
		if ctx.Err() != nil {
			return // 已被取消，状态由 stop 改好了
		}
		speedUpdate(runID, func(p *Progress) {
			p.Phase = "failed"
			p.CurrentMbps = 0
			p.BytesUsed = used.Load()
			p.Error = speedDescribe(err)
		})
		log.Warnln("[MeowX] 测速失败 %s 经 %s：%s", source, proxy.Name(), speedDescribe(err))
	}

	endpoints, err := speedResolve(ctx, source, proxy)
	if err != nil {
		fail(err)
		return
	}
	speedUpdate(runID, func(p *Progress) { p.Server = endpoints.server; p.Phase = "latency" })

	// 延迟只是附带的一项：一条连接偶尔卡在握手里不该让整次测速失败——重试一次，还不行就不显示延迟、照测下载
	var latency *int
	for attempt := 0; attempt < 2 && latency == nil && ctx.Err() == nil; attempt++ {
		if ms, err := speedMeasureLatency(ctx, endpoints.latency, proxy, &used); err == nil {
			latency = &ms
		} else {
			log.Warnln("[MeowX] 测速：第 %d 次测延迟失败（%s）", attempt+1, speedDescribe(err))
		}
	}
	if ctx.Err() != nil {
		return
	}
	speedUpdate(runID, func(p *Progress) { p.LatencyMs = latency; p.BytesUsed = used.Load(); p.Phase = "download" })

	avg, peak, err := speedTransfer(ctx, runID, true, endpoints, proxy, connections, &used)
	if err != nil {
		fail(err)
		return
	}
	next := "done"
	if endpoints.hasUpload {
		next = "upload"
	}
	speedUpdate(runID, func(p *Progress) {
		p.DownloadMbps, p.DownloadPeakMbps = &avg, &peak
		p.CurrentMbps, p.PhaseProgress = 0, 0
		p.BytesUsed = used.Load()
		p.Phase = next
	})
	if !endpoints.hasUpload {
		return
	}
	upAvg, upPeak, err := speedTransfer(ctx, runID, false, endpoints, proxy, connections, &used)
	if err != nil {
		fail(err)
		return
	}
	speedUpdate(runID, func(p *Progress) {
		p.UploadMbps, p.UploadPeakMbps = &upAvg, &upPeak
		p.CurrentMbps, p.PhaseProgress = 0, 1
		p.BytesUsed = used.Load()
		p.Phase = "done"
	})
}

func speedDescribe(err error) string {
	switch {
	case errors.Is(err, context.DeadlineExceeded):
		return "连接超时"
	default:
		return err.Error()
	}
}

// speedClient 经节点拨号的 HTTP 客户端（不读系统 / 环境变量代理；TLS 按系统根证书校验）。
func speedClient(proxy constant.Proxy, keepAlive bool) *http.Client {
	return &http.Client{
		Transport: &http.Transport{
			Proxy: nil,
			DialContext: func(ctx context.Context, network, addr string) (net.Conn, error) {
				var metadata constant.Metadata
				metadata.NetWork = constant.TCP
				if err := metadata.SetRemoteAddress(addr); err != nil {
					return nil, err
				}
				return proxy.DialContext(ctx, &metadata)
			},
			ForceAttemptHTTP2:     false,
			DisableKeepAlives:     !keepAlive,
			MaxIdleConnsPerHost:   1,
			TLSHandshakeTimeout:   8 * time.Second,
			ResponseHeaderTimeout: 10 * time.Second,
			DisableCompression:    true,
			// 缺省读写缓冲各 4KB：上传 body 被切成 4KB 一块，经节点加密后包数翻倍，实测上传只有大缓冲的十分之一
			WriteBufferSize: 64 * 1024,
			ReadBufferSize:  64 * 1024,
		},
	}
}

func speedRequest(ctx context.Context, t speedTarget, body io.Reader, length int64) (*http.Request, error) {
	method := t.method
	if method == "" {
		method = http.MethodGet
	}
	req, err := http.NewRequestWithContext(ctx, method, t.url(), body)
	if err != nil {
		return nil, err
	}
	req.Header.Set("User-Agent", "MeowX")
	req.Header.Set("Cache-Control", "no-cache")
	for k, v := range t.headers {
		req.Header.Set(k, v)
	}
	if body != nil {
		req.ContentLength = length
	}
	return req, nil
}

func speedMeasureLatency(ctx context.Context, t speedTarget, proxy constant.Proxy, used *atomic.Int64) (int, error) {
	client := speedClient(proxy, true)
	defer client.CloseIdleConnections()
	ctx, cancel := context.WithTimeout(ctx, 15*time.Second)
	defer cancel()
	var samples []time.Duration
	for i := 0; i < speedLatencyRounds; i++ {
		req, err := speedRequest(ctx, t, nil, 0)
		if err != nil {
			return 0, err
		}
		start := time.Now()
		resp, err := client.Do(req)
		if err != nil {
			if len(samples) > 0 {
				break
			}
			return 0, err
		}
		n, _ := io.Copy(io.Discard, resp.Body)
		resp.Body.Close()
		used.Add(n)
		if resp.StatusCode >= 400 {
			return 0, fmt.Errorf("测速服务器返回 %d", resp.StatusCode)
		}
		samples = append(samples, time.Since(start))
	}
	// 第一次带着连接 + TLS 握手，有多次时去掉它再取中位数
	if len(samples) > 2 {
		samples = samples[1:]
	}
	if len(samples) == 0 {
		return 0, errors.New("没有测到延迟")
	}
	sort.Slice(samples, func(i, j int) bool { return samples[i] < samples[j] })
	ms := int(samples[len(samples)/2].Milliseconds())
	if ms < 1 {
		ms = 1
	}
	return ms, nil
}

func speedMbps(bytes int64, d time.Duration) float64 {
	if d <= 0 || bytes <= 0 {
		return 0
	}
	return float64(bytes) * 8 / d.Seconds() / 1_000_000
}

// speedTransfer N 条连接各自循环请求 phaseDuration 秒，每 250ms 采样一次；到点就收掉所有连接（取消 context），不等在途请求读完。
func speedTransfer(ctx context.Context, runID int, download bool, ep *speedEndpoints, proxy constant.Proxy,
	connections int, used *atomic.Int64) (float64, float64, error) {
	var meter atomic.Int64
	phaseCtx, cancel := context.WithTimeout(ctx, speedPhaseDuration)
	defer cancel()
	var errMu sync.Mutex
	var errs []error
	var failedWorkers atomic.Int32
	for i := 0; i < connections; i++ {
		go func(index int) {
			client := speedClient(proxy, true)
			defer client.CloseIdleConnections()
			failures := 0
			for round := 0; phaseCtx.Err() == nil; round++ {
				var err error
				if download {
					err = speedDownloadOnce(phaseCtx, client, ep.download(index, round, connections), &meter, used)
				} else {
					err = speedUploadOnce(phaseCtx, client, ep.upload(index, round, connections), ep.uploadChunk, &meter, used)
				}
				if err == nil || phaseCtx.Err() != nil {
					continue
				}
				errMu.Lock()
				errs = append(errs, err)
				errMu.Unlock()
				failures++
				if failures >= 3 {
					failedWorkers.Add(1)
					return
				}
				time.Sleep(200 * time.Millisecond)
			}
		}(i)
	}

	type mark struct {
		at    time.Duration
		bytes int64
	}
	start := time.Now()
	marks := []mark{{0, 0}}
	var samples []float64
	var warmupBytes int64 = -1
	ticker := time.NewTicker(speedSampleEvery)
	defer ticker.Stop()
	firstErr := func() error {
		errMu.Lock()
		defer errMu.Unlock()
		if len(errs) > 0 {
			return errs[0]
		}
		return nil
	}
loop:
	for {
		select {
		case <-ctx.Done():
			return 0, 0, ctx.Err()
		case <-ticker.C:
		}
		elapsed := time.Since(start)
		bytes := meter.Load()
		prev := marks[len(marks)-1]
		samples = append(samples, speedMbps(bytes-prev.bytes, elapsed-prev.at))
		marks = append(marks, mark{elapsed, bytes})
		if warmupBytes < 0 && elapsed >= speedWarmup {
			warmupBytes = bytes
		}
		window := marks[0]
		for j := len(marks) - 1; j >= 0; j-- {
			if elapsed-marks[j].at >= time.Second {
				window = marks[j]
				break
			}
		}
		current := speedMbps(bytes-window.bytes, elapsed-window.at)
		progress := float64(elapsed) / float64(speedPhaseDuration)
		if progress > 1 {
			progress = 1
		}
		snapshot := append([]float64(nil), samples...)
		speedUpdate(runID, func(p *Progress) {
			p.CurrentMbps = current
			p.PhaseProgress = progress
			p.BytesUsed = used.Load()
			if download {
				p.DownloadSamples = snapshot
			} else {
				p.UploadSamples = snapshot
			}
		})
		if elapsed >= speedPhaseDuration {
			break loop
		}
		// 一个字节都没走、所有连接都已报错放弃：不必等满 10 秒
		if bytes == 0 && int(failedWorkers.Load()) >= connections {
			break loop
		}
	}
	cancel()

	elapsed := time.Since(start)
	total := meter.Load()
	if total == 0 {
		if err := firstErr(); err != nil {
			return 0, 0, err
		}
		if download {
			return 0, 0, errors.New("下载没有收到数据")
		}
		return 0, 0, errors.New("上传没有发出数据")
	}
	avg := speedMbps(total, elapsed)
	if warmupBytes >= 0 && elapsed > speedWarmup && total > warmupBytes {
		avg = speedMbps(total-warmupBytes, elapsed-speedWarmup)
	}
	span := int(time.Second / speedSampleEvery)
	peak := 0.0
	if len(samples) >= span {
		for end := span; end <= len(samples); end++ {
			sum := 0.0
			for _, v := range samples[end-span : end] {
				sum += v
			}
			if sum/float64(span) > peak {
				peak = sum / float64(span)
			}
		}
	} else {
		for _, v := range samples {
			if v > peak {
				peak = v
			}
		}
	}
	if peak < avg {
		peak = avg
	}
	return avg, peak, nil
}

func speedDownloadOnce(ctx context.Context, client *http.Client, t speedTarget, meter, used *atomic.Int64) error {
	req, err := speedRequest(ctx, t, nil, 0)
	if err != nil {
		return err
	}
	resp, err := client.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return fmt.Errorf("测速服务器返回 %d", resp.StatusCode)
	}
	buf := make([]byte, 64*1024)
	for {
		n, err := resp.Body.Read(buf)
		if n > 0 && ctx.Err() == nil {
			meter.Add(int64(n))
			used.Add(int64(n))
			statistic.DefaultManager.PushDownloaded(false, int64(n))
		}
		if err == io.EOF {
			return nil
		}
		if err != nil {
			return err
		}
	}
}

var speedZeros = make([]byte, 64*1024)

// zeroReader 上传用的全零 body，读一块记一块。
type zeroReader struct {
	ctx         context.Context
	remaining   int64
	meter, used *atomic.Int64
}

func (z *zeroReader) Read(p []byte) (int, error) {
	if z.remaining <= 0 {
		return 0, io.EOF
	}
	if err := z.ctx.Err(); err != nil {
		return 0, err
	}
	n := len(p)
	if n > len(speedZeros) {
		n = len(speedZeros)
	}
	if int64(n) > z.remaining {
		n = int(z.remaining)
	}
	copy(p[:n], speedZeros[:n])
	z.remaining -= int64(n)
	z.meter.Add(int64(n))
	z.used.Add(int64(n))
	statistic.DefaultManager.PushUploaded(false, int64(n))
	return n, nil
}

func speedUploadOnce(ctx context.Context, client *http.Client, t speedTarget, length int64, meter, used *atomic.Int64) error {
	req, err := speedRequest(ctx, t, &zeroReader{ctx: ctx, remaining: length, meter: meter, used: used}, length)
	if err != nil {
		return err
	}
	resp, err := client.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	_, _ = io.Copy(io.Discard, resp.Body)
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return fmt.Errorf("测速服务器返回 %d", resp.StatusCode)
	}
	return nil
}

// MARK: - 测速地址

func speedResolve(ctx context.Context, source string, proxy constant.Proxy) (*speedEndpoints, error) {
	octet := map[string]string{"Content-Type": "application/octet-stream"}
	switch source {
	case "apple":
		host := "mensura.cdn-apple.com"
		return &speedEndpoints{
			server:   host,
			latency:  speedTarget{host: host, path: "/api/v1/gm/small"},
			download: func(int, int, int) speedTarget { return speedTarget{host: host, path: "/api/v1/gm/large"} },
			upload: func(int, int, int) speedTarget {
				return speedTarget{method: http.MethodPost, host: host, path: "/api/v1/gm/slurp", headers: octet}
			},
			uploadChunk: 32 * 1024 * 1024,
			hasUpload:   true,
		}, nil
	case "cloudflare":
		host := "speed.cloudflare.com"
		return &speedEndpoints{
			server:   host,
			latency:  speedTarget{host: host, path: "/__down?bytes=0"},
			download: func(int, int, int) speedTarget { return speedTarget{host: host, path: "/__down?bytes=25000000"} },
			upload: func(int, int, int) speedTarget {
				return speedTarget{method: http.MethodPost, host: host, path: "/__up", headers: octet}
			},
			uploadChunk: 10_000_000,
			hasUpload:   true,
		}, nil
	case "speedtest":
		server, err := speedtestPick(ctx, proxy)
		if err != nil {
			return nil, err
		}
		return &speedEndpoints{
			server:  server.label,
			latency: speedTarget{host: server.host, port: server.port, path: "/hello"},
			download: func(conn, round, _ int) speedTarget {
				return speedTarget{host: server.host, port: server.port,
					path: fmt.Sprintf("/download?nocache=%d-%d-%d&size=25000000", conn, round, rand.Uint32())}
			},
			upload: func(conn, round, _ int) speedTarget {
				return speedTarget{method: http.MethodPost, host: server.host, port: server.port,
					path: fmt.Sprintf("/upload?nocache=%d-%d-%d", conn, round, rand.Uint32()), headers: octet}
			},
			uploadChunk: 25_000_000,
			hasUpload:   true,
		}, nil
	default: // google
		host := speedGoogleHost
		return &speedEndpoints{
			server:  host,
			latency: speedTarget{host: host, path: speedGooglePath, headers: map[string]string{"Range": "bytes=0-0"}},
			download: func(conn, round, conns int) speedTarget {
				// 各连接错开取不同的段，绕满整个文件再从头
				chunks := speedGoogleSize / speedGoogleChunk
				slot := int64(conn+round*conns) % chunks
				begin := slot * speedGoogleChunk
				return speedTarget{host: host, path: speedGooglePath,
					headers: map[string]string{"Range": fmt.Sprintf("bytes=%d-%d", begin, begin+speedGoogleChunk-1)}}
			},
			upload:    func(int, int, int) speedTarget { return speedTarget{host: host, path: speedGooglePath} },
			hasUpload: false,
		}, nil
	}
}

type speedtestServer struct {
	host  string
	port  int
	label string
}

// speedtestPick 经节点向 speedtest.net 要离请求方（= 节点出口）最近的几台，前三台各测一次 /hello 往返，取最快的。
func speedtestPick(ctx context.Context, proxy constant.Proxy) (speedtestServer, error) {
	type entry struct {
		Host    string `json:"host"`
		Name    string `json:"name"`
		Sponsor string `json:"sponsor"`
	}
	fetch := func() ([]entry, error) {
		reqCtx, cancel := context.WithTimeout(ctx, 12*time.Second)
		defer cancel()
		client := speedClient(proxy, false)
		req, err := speedRequest(reqCtx, speedTarget{host: "www.speedtest.net",
			path: "/api/js/servers?engine=js&limit=5&https_functional=true"}, nil, 0)
		if err != nil {
			return nil, err
		}
		req.Header.Set("Accept", "application/json")
		resp, err := client.Do(req)
		if err != nil {
			return nil, err
		}
		defer resp.Body.Close()
		if resp.StatusCode != 200 {
			return nil, fmt.Errorf("speedtest.net 返回 %d", resp.StatusCode)
		}
		var list []entry
		if err := json.NewDecoder(io.LimitReader(resp.Body, 1<<20)).Decode(&list); err != nil {
			return nil, errors.New("speedtest.net 的服务器列表解析失败")
		}
		return list, nil
	}
	list, err := fetch()
	if err != nil && ctx.Err() == nil {
		log.Warnln("[MeowX] 测速：拉 Speedtest 服务器列表失败（%s），重试", speedDescribe(err))
		list, err = fetch()
	}
	if err != nil {
		return speedtestServer{}, err
	}
	if len(list) == 0 {
		return speedtestServer{}, errors.New("speedtest.net 没有返回可用的服务器")
	}
	if len(list) > 3 {
		list = list[:3]
	}
	servers := make([]speedtestServer, len(list))
	for i, e := range list {
		host, portText, err := net.SplitHostPort(e.Host)
		port := 443
		if err != nil {
			host = e.Host
		} else if p, err := strconv.Atoi(portText); err == nil {
			port = p
		}
		label := strings.TrimSpace(strings.Join(nonEmpty(e.Name, e.Sponsor), " · "))
		if label == "" {
			label = host
		}
		servers[i] = speedtestServer{host: host, port: port, label: label}
	}
	rtts := make([]time.Duration, len(servers))
	var wg sync.WaitGroup
	for i, s := range servers {
		wg.Add(1)
		go func(i int, s speedtestServer) {
			defer wg.Done()
			pingCtx, cancel := context.WithTimeout(ctx, 2500*time.Millisecond)
			defer cancel()
			client := speedClient(proxy, false)
			req, err := speedRequest(pingCtx, speedTarget{host: s.host, port: s.port, path: "/hello"}, nil, 0)
			if err != nil {
				return
			}
			start := time.Now()
			resp, err := client.Do(req)
			if err != nil {
				return
			}
			resp.Body.Close()
			if resp.StatusCode < 400 {
				rtts[i] = time.Since(start)
			}
		}(i, s)
	}
	wg.Wait()
	best := 0
	for i, rtt := range rtts {
		if rtt > 0 && (rtts[best] == 0 || rtt < rtts[best]) {
			best = i
		}
	}
	return servers[best], nil
}

func nonEmpty(values ...string) []string {
	var out []string
	for _, v := range values {
		if v != "" {
			out = append(out, v)
		}
	}
	return out
}
