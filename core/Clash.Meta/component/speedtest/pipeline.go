package speedtest

import (
	"bufio"
	"context"
	"crypto/tls"
	"crypto/x509"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"strconv"
	"sync/atomic"
	"time"

	"github.com/metacubex/mihomo/constant"
	"github.com/metacubex/mihomo/tunnel/statistic"
)

// 下载 / 上传阶段每条测速连接自己拨号，在这一条连接上手写 HTTP/1.1 流水线（与 iOS / macOS 的 SpeedTestRunner 一致）。
//
// 为什么不用 net/http 的 client.Do 循环：标准库不做流水线，每条连接上是「发请求 → 等响应头 → 读完 body → 再发下一个」，
// 每到段边界（Google 每段 32MB、Cloudflare / Speedtest 每段约 25MB）下行停一个 RTT，随后服务端按攒下的拥塞窗口突发，
// 远端节点上易丢包、窗口减半，逐格速率呈锯齿（单线程最明显，用户看到「中间几秒网速下降」）。
// 这里每条连接上始终多一个请求在路上（深度 2）：下载读完一个 body 就补发一个请求；上传不等响应就接着发下一段。
// 读 body 只读到它的末尾（Content-Length / chunked 由 http.ReadResponse 处理），多出的字节留给下一个响应头。

const speedPipelineDepth = 2

// speedDialer 拨一条到 host:port 的连接（生产里是经出站 + TLS；单测换成本地连接）。
type speedDialer func(ctx context.Context, host string, port int) (net.Conn, error)

// speedDialProxy 经出站拨 TCP（不经分流规则），speedClient 与流水线共用。
func speedDialProxy(ctx context.Context, proxy constant.Proxy, addr string) (net.Conn, error) {
	var metadata constant.Metadata
	metadata.NetWork = constant.TCP
	if err := metadata.SetRemoteAddress(addr); err != nil {
		return nil, err
	}
	return proxy.DialContext(ctx, &metadata)
}

// speedTLSDialer 经出站拨号 + TLS（只协商 http/1.1，按系统根证书校验，与 speedClient 一致；roots 非 nil 时用它，单测用）。
func speedTLSDialer(proxy constant.Proxy, roots *x509.CertPool) speedDialer {
	return func(ctx context.Context, host string, port int) (net.Conn, error) {
		if port == 0 {
			port = 443
		}
		raw, err := speedDialProxy(ctx, proxy, net.JoinHostPort(host, strconv.Itoa(port)))
		if err != nil {
			return nil, err
		}
		conn := tls.Client(raw, &tls.Config{ServerName: host, NextProtos: []string{"http/1.1"}, RootCAs: roots})
		hsCtx, cancel := context.WithTimeout(ctx, 8*time.Second)
		defer cancel()
		if err := conn.HandshakeContext(hsCtx); err != nil {
			raw.Close()
			return nil, err
		}
		return conn, nil
	}
}

// speedPipeline 一条连接上的流水线。target(i) 是这条连接上第 i 个请求。
type speedPipeline struct {
	download    bool
	target      func(i int) speedTarget
	uploadChunk int64
	meter, used *atomic.Int64
}

var errSpeedConnClosed = errors.New("测速服务器关闭了连接")

// run 拨一条连接跑到出错、对端正常关连接或 ctx 结束（结束时立刻关掉连接，不等在途请求）。
// 返回完成的请求数；对端在一个完整响应之后关连接（Connection: close 或直接 EOF）算正常结束，err 为 nil。
func (p *speedPipeline) run(ctx context.Context, dial speedDialer) (int, error) {
	first := p.target(0)
	conn, err := dial(ctx, first.host, first.port)
	if err != nil {
		return 0, err
	}
	stop := make(chan struct{})
	defer close(stop)
	go func() {
		select {
		case <-ctx.Done():
		case <-stop:
		}
		conn.Close()
	}()
	if p.download {
		return p.runDownload(ctx, conn)
	}
	return p.runUpload(ctx, conn)
}

func (p *speedPipeline) request(ctx context.Context, i int) (*http.Request, error) {
	if p.download {
		return speedRequest(ctx, p.target(i), nil, 0)
	}
	body := &zeroReader{ctx: ctx, remaining: p.uploadChunk, meter: p.meter, used: p.used}
	return speedRequest(ctx, p.target(i), body, p.uploadChunk)
}

func (p *speedPipeline) send(ctx context.Context, w *bufio.Writer, i int) error {
	req, err := p.request(ctx, i)
	if err != nil {
		return err
	}
	if err := req.Write(w); err != nil {
		return err
	}
	return w.Flush()
}

// readResponse 读一个响应：非 2xx 报错；body 读到末尾为止，下载时每块记进计数。
// 对端在响应头之前就 EOF（上一个响应之后关了连接）回 errSpeedConnClosed。
func (p *speedPipeline) readResponse(ctx context.Context, r *bufio.Reader) (closeAfter bool, err error) {
	resp, err := http.ReadResponse(r, nil)
	if err != nil {
		if errors.Is(err, io.EOF) || errors.Is(err, io.ErrUnexpectedEOF) {
			return false, errSpeedConnClosed
		}
		return false, err
	}
	defer resp.Body.Close()
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return false, fmt.Errorf("测速服务器返回 %d", resp.StatusCode)
	}
	buf := make([]byte, 64*1024)
	for {
		n, err := resp.Body.Read(buf)
		if n > 0 && p.download && ctx.Err() == nil {
			p.meter.Add(int64(n))
			p.used.Add(int64(n))
			statistic.DefaultManager.PushDownloaded(false, int64(n))
		}
		if err == io.EOF {
			return resp.Close, nil
		}
		if err != nil {
			return false, err
		}
	}
}

func (p *speedPipeline) runDownload(ctx context.Context, conn net.Conn) (int, error) {
	w := bufio.NewWriterSize(conn, 4*1024)
	r := bufio.NewReaderSize(conn, 64*1024)
	sent := 0
	for ; sent < speedPipelineDepth; sent++ {
		if err := p.send(ctx, w, sent); err != nil {
			return 0, err
		}
	}
	broken := false
	for done := 0; ; {
		closeAfter, err := p.readResponse(ctx, r)
		if err != nil {
			if err == errSpeedConnClosed && done > 0 {
				return done, nil
			}
			return done, err
		}
		done++
		if closeAfter {
			return done, nil
		}
		if broken {
			if done == sent {
				return done, nil // 已发出的都读完了，重拨一条接着来
			}
			continue
		}
		// 读完一个就补一个：读下一个 body 时后面始终还有一个请求在路上。
		// 补发失败（多半是对端在上一个响应之后关了连接）不算出错：已在路上的响应照读，读完再重拨
		if err := p.send(ctx, w, sent); err != nil {
			broken = true
			continue
		}
		sent++
	}
}

// runUpload 写和读各一个 goroutine：写完一段的 body 立刻写下一段（最多比已收到的响应多 depth 个），不等响应。
// 结果以读的一侧为准：对端在完整响应之后关连接时，写的一侧多半正写着下一段、会报错，那不算失败。
func (p *speedPipeline) runUpload(ctx context.Context, conn net.Conn) (int, error) {
	w := bufio.NewWriterSize(conn, 64*1024)
	r := bufio.NewReaderSize(conn, 4*1024)
	slots := make(chan struct{}, speedPipelineDepth)
	quit := make(chan struct{})
	writeErr := make(chan error, 1)
	go func() {
		for i := 0; ; i++ {
			select {
			case slots <- struct{}{}:
			case <-quit:
				return
			}
			if err := p.send(ctx, w, i); err != nil {
				writeErr <- err // 连接坏了读的一侧也会出错，由它收尾
				return
			}
		}
	}()
	defer func() {
		close(quit)
		conn.Close()
	}()
	for done := 0; ; {
		closeAfter, err := p.readResponse(ctx, r)
		if err == errSpeedConnClosed {
			if done > 0 {
				return done, nil
			}
			select {
			case werr := <-writeErr:
				return 0, werr
			default:
			}
		}
		if err != nil {
			return done, err
		}
		done++
		if closeAfter {
			return done, nil
		}
		<-slots
	}
}
