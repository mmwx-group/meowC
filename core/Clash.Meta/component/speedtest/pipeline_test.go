package speedtest

import (
	"bufio"
	"context"
	"crypto/x509"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"strconv"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/metacubex/mihomo/adapter"
	"github.com/metacubex/mihomo/adapter/outbound"
)

// pipeDialer 把一端交给被测代码，另一端交给假服务端 serve（在自己的 goroutine 里跑）。
func pipeDialer(t *testing.T, serve func(conn net.Conn)) speedDialer {
	return func(ctx context.Context, host string, port int) (net.Conn, error) {
		client, server := net.Pipe()
		go func() {
			defer server.Close()
			serve(server)
		}()
		return client, nil
	}
}

func readRequest(t *testing.T, r *bufio.Reader) *http.Request {
	req, err := http.ReadRequest(r)
	if err != nil {
		t.Errorf("服务端读请求：%v", err)
		return nil
	}
	return req
}

func target(path string) func(int) speedTarget {
	return func(i int) speedTarget { return speedTarget{host: "speed.test", path: fmt.Sprintf("%s?i=%d", path, i)} }
}

// 下载：两个请求先后发出、第一个响应还没回就已经收到第二个请求（流水线）；
// 第一个是 Content-Length、第二个是 chunked、两个响应一次写回，计数正好是两个 body 的长度、不越界读进下一个响应。
func TestPipelineDownload(t *testing.T) {
	gotSecondEarly := make(chan bool, 1)
	dial := pipeDialer(t, func(conn net.Conn) {
		r := bufio.NewReader(conn)
		first := readRequest(t, r)
		second := readRequest(t, r) // 第一个响应还没写：客户端必须已经把第二个请求发出来了
		gotSecondEarly <- first != nil && second != nil &&
			first.URL.RawQuery == "i=0" && second.URL.RawQuery == "i=1" && first.Header.Get("User-Agent") == "MeowX"
		body1 := strings.Repeat("a", 100_000)
		resp := "HTTP/1.1 200 OK\r\nContent-Length: " + strconv.Itoa(len(body1)) + "\r\n\r\n" + body1 +
			"HTTP/1.1 206 Partial Content\r\nTransfer-Encoding: chunked\r\n\r\n" +
			"7d0\r\n" + strings.Repeat("b", 2000) + "\r\n" + "3\r\nccc\r\n0\r\n\r\n"
		go io.Copy(io.Discard, r) // 补发的第三个请求
		_, _ = conn.Write([]byte(resp))
		// 写完两个响应就关连接：客户端读第三个响应头时 EOF，算正常结束
	})
	var meter, used atomic.Int64
	p := &speedPipeline{download: true, target: target("/down"), meter: &meter, used: &used}
	n, err := p.run(context.Background(), dial)
	if err != nil {
		t.Fatal(err)
	}
	if n != 2 {
		t.Fatalf("完成 %d 个，want 2", n)
	}
	if want := int64(100_000 + 2000 + 3); meter.Load() != want || used.Load() != want {
		t.Fatalf("计数 %d / %d，want %d", meter.Load(), used.Load(), want)
	}
	if !<-gotSecondEarly {
		t.Fatal("第二个请求没有在第一个响应之前发出")
	}
}

// 上传：写完第一段 body 不等响应就接着发第二段；服务端两段都收完才回两个 200
func TestPipelineUpload(t *testing.T) {
	const chunk = 300_000
	bodies := make(chan []int64, 1)
	dial := pipeDialer(t, func(conn net.Conn) {
		r := bufio.NewReader(conn)
		var got []int64
		for i := 0; i < 2; i++ {
			req := readRequest(t, r)
			if req == nil {
				return
			}
			n, _ := io.Copy(io.Discard, req.Body)
			if req.Method != http.MethodPost || req.ContentLength != chunk {
				t.Errorf("请求 %s %d", req.Method, req.ContentLength)
			}
			got = append(got, n)
		}
		bodies <- got
		go io.Copy(io.Discard, r)
		_, _ = conn.Write([]byte("HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nokHTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n"))
	})
	var meter, used atomic.Int64
	p := &speedPipeline{download: false, uploadChunk: chunk, meter: &meter, used: &used,
		target: func(i int) speedTarget {
			return speedTarget{method: http.MethodPost, host: "speed.test", path: "/up"}
		}}
	n, err := p.run(context.Background(), dial)
	if err != nil {
		t.Fatal(err)
	}
	if n != 2 {
		t.Fatalf("完成 %d 个，want 2", n)
	}
	if got := <-bodies; len(got) != 2 || got[0] != chunk || got[1] != chunk {
		t.Fatalf("服务端收到 %v", got)
	}
	// 写出去的至少是两段（第三段可能写了一部分才断）
	if meter.Load() < 2*chunk {
		t.Fatalf("上传计数 %d", meter.Load())
	}
}

// 非 2xx（例如 Cloudflare 限流的 429）报错，带状态码
func TestPipelineStatusError(t *testing.T) {
	dial := pipeDialer(t, func(conn net.Conn) {
		r := bufio.NewReader(conn)
		readRequest(t, r)
		go io.Copy(io.Discard, r)
		_, _ = conn.Write([]byte("HTTP/1.1 429 Too Many Requests\r\nContent-Length: 0\r\n\r\n"))
	})
	var meter, used atomic.Int64
	p := &speedPipeline{download: true, target: target("/down"), meter: &meter, used: &used}
	_, err := p.run(context.Background(), dial)
	if err == nil || !strings.Contains(err.Error(), "429") {
		t.Fatalf("err = %v", err)
	}
	// 一个响应都没有就被关：不是正常结束
	dial = pipeDialer(t, func(conn net.Conn) { readRequest(t, bufio.NewReader(conn)) })
	if n, err := p.run(context.Background(), dial); err == nil || n != 0 {
		t.Fatalf("n=%d err=%v", n, err)
	}
}

// 到点即停：ctx 结束时立刻关连接，不等在途的 body
func TestPipelineStopsOnCancel(t *testing.T) {
	dial := pipeDialer(t, func(conn net.Conn) {
		r := bufio.NewReader(conn)
		go io.Copy(io.Discard, r)
		_, _ = conn.Write([]byte("HTTP/1.1 200 OK\r\nContent-Length: 1000000000\r\n\r\n"))
		buf := make([]byte, 32*1024)
		for {
			if _, err := conn.Write(buf); err != nil {
				return
			}
		}
	})
	var meter, used atomic.Int64
	p := &speedPipeline{download: true, target: target("/down"), meter: &meter, used: &used}
	ctx, cancel := context.WithTimeout(context.Background(), 150*time.Millisecond)
	defer cancel()
	start := time.Now()
	_, _ = p.run(ctx, dial)
	if time.Since(start) > 2*time.Second {
		t.Fatalf("没有到点即停：%v", time.Since(start))
	}
	if meter.Load() == 0 {
		t.Fatal("停之前应该收到了数据")
	}
}

// 真 TLS（本地 httptest，经 DIRECT 出站拨号）：Go 的服务端支持流水线，连续多个响应都能读出来，计数等于各 body 之和
func TestPipelineTLS(t *testing.T) {
	var hits atomic.Int64
	server := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		n := hits.Add(1)
		if n > 5 {
			w.Header().Set("Connection", "close") // 第 6 个之后让客户端重拨
		}
		w.Header().Set("Content-Length", "50000")
		_, _ = w.Write(make([]byte, 50000))
	}))
	defer server.Close()
	roots := x509.NewCertPool()
	roots.AddCert(server.Certificate())
	host, portText, _ := net.SplitHostPort(server.Listener.Addr().String())
	port, _ := strconv.Atoi(portText)
	dial := speedTLSDialer(adapter.NewProxy(outbound.NewDirect()), roots)

	var meter, used atomic.Int64
	p := &speedPipeline{download: true, meter: &meter, used: &used,
		target: func(i int) speedTarget { return speedTarget{host: host, port: port, path: "/x"} }}
	n, err := p.run(context.Background(), dial)
	if err != nil {
		t.Fatal(err)
	}
	if n != 6 || meter.Load() != int64(n)*50000 {
		t.Fatalf("完成 %d 个、计数 %d", n, meter.Load())
	}

	// 证书不受信任（不给根证书）：握手失败
	if _, err := speedTLSDialer(adapter.NewProxy(outbound.NewDirect()), nil)(context.Background(), host, port); err == nil {
		t.Fatal("自签证书应校验失败")
	}
}
