package speedtest

import (
	"context"
	"crypto/sha256"
	"crypto/tls"
	"crypto/x509"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/metacubex/mihomo/adapter"
	"github.com/metacubex/mihomo/adapter/outbound"
)

func boardDirectClient() *http.Client {
	return speedClient(adapter.NewProxy(outbound.NewDirect()), false)
}

// 经 DIRECT 上传：正文字节原样到达（服务端算的 sha256 与客户端算的一致）、头带上；回状态码与正文
func TestBoardSendPost(t *testing.T) {
	body := []byte(`{"v":1,"claimed_exit":{"org":"中国电信 🐱"}}`)
	var gotHash, gotGrant, gotType, gotMethod string
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		data, _ := io.ReadAll(r.Body)
		sum := sha256.Sum256(data)
		gotHash = hex.EncodeToString(sum[:])
		gotGrant = r.Header.Get("X-MeowX-Speed-Grant")
		gotType = r.Header.Get("Content-Type")
		gotMethod = r.Method
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"id":"No63xGk","url":"https://speed.meowx.net/r/No63xGk"}`))
	}))
	defer server.Close()

	resp := boardSend(context.Background(), boardDirectClient(), BoardRequest{
		Proxy:   "DIRECT",
		Method:  "post",
		URL:     server.URL + "/api/v2/speedtest/results",
		Headers: map[string]string{"Content-Type": "application/json", "X-MeowX-Speed-Grant": "g.s"},
		Body:    base64.StdEncoding.EncodeToString(body),
	})
	want := sha256.Sum256(body)
	if resp.Status != 200 || resp.Error != "" || !strings.Contains(resp.Body, `"No63xGk"`) {
		t.Fatalf("got %+v", resp)
	}
	if gotHash != hex.EncodeToString(want[:]) || gotGrant != "g.s" || gotType != "application/json" || gotMethod != http.MethodPost {
		t.Fatalf("服务端收到 hash %s grant %q type %q method %s", gotHash, gotGrant, gotType, gotMethod)
	}
}

// 429 带回 Retry-After；DELETE 不带正文
func TestBoardSendRetryAfterAndDelete(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method == http.MethodDelete {
			if r.ContentLength != 0 || r.Header.Get("X-MeowX-Delete-Token") != "tok" {
				w.WriteHeader(http.StatusForbidden)
				_, _ = w.Write([]byte(`{"code":"forbidden"}`))
				return
			}
			_, _ = w.Write([]byte(`{"success":true}`))
			return
		}
		w.Header().Set("Retry-After", "600")
		w.WriteHeader(http.StatusTooManyRequests)
		_, _ = w.Write([]byte(`{"error":"too many","code":"rate_limited"}`))
	}))
	defer server.Close()
	client := boardDirectClient()

	resp := boardSend(context.Background(), client, BoardRequest{Method: "POST", URL: server.URL, Body: base64.StdEncoding.EncodeToString([]byte("{}"))})
	if resp.Status != 429 || resp.RetryAfter != "600" || !strings.Contains(resp.Body, "rate_limited") {
		t.Fatalf("got %+v", resp)
	}
	resp = boardSend(context.Background(), client, BoardRequest{Method: "DELETE", URL: server.URL + "/x",
		Headers: map[string]string{"X-MeowX-Delete-Token": "tok"}})
	if resp.Status != 200 || !strings.Contains(resp.Body, "success") {
		t.Fatalf("got %+v", resp)
	}
}

// 证书照常校验：自签证书不认（status 0 + 原因）；换成认这张证书的根就通
func TestBoardSendVerifiesCertificate(t *testing.T) {
	server := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = w.Write([]byte(`{"ok":true}`))
	}))
	defer server.Close()

	resp := boardSend(context.Background(), boardDirectClient(), BoardRequest{Method: "POST", URL: server.URL})
	if resp.Status != 0 || resp.Error == "" {
		t.Fatalf("自签证书应失败：%+v", resp)
	}

	pool := x509.NewCertPool()
	pool.AddCert(server.Certificate())
	client := boardDirectClient()
	client.Transport.(*http.Transport).TLSClientConfig = &tls.Config{RootCAs: pool}
	resp = boardSend(context.Background(), client, BoardRequest{Method: "POST", URL: server.URL})
	if resp.Status != 200 || resp.Body != `{"ok":true}` {
		t.Fatalf("got %+v", resp)
	}
}

// 参数不对直接回原因，不发请求；连不上的地址回 status 0
func TestBoardSendRejectsBadInput(t *testing.T) {
	client := boardDirectClient()
	for _, req := range []BoardRequest{
		{Method: "GET", URL: "https://example.com"},
		{Method: "POST", URL: "ftp://example.com"},
		{Method: "POST", URL: "not a url"},
		{Method: "POST", URL: "https://example.com", Body: "!!!不是 base64"},
	} {
		if resp := boardSend(context.Background(), client, req); resp.Status != 0 || resp.Error == "" {
			t.Fatalf("%+v 应被拒：%+v", req, resp)
		}
	}
	dead := httptest.NewServer(http.NotFoundHandler())
	url := dead.URL
	dead.Close()
	if resp := boardSend(context.Background(), client, BoardRequest{Method: "POST", URL: url}); resp.Status != 0 || resp.Error == "" {
		t.Fatalf("连不上应失败：%+v", resp)
	}
}

// 整次请求 10 秒上限：外层 context 先到点也立刻返回
func TestBoardSendTimeout(t *testing.T) {
	release := make(chan struct{})
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		select {
		case <-release:
		case <-r.Context().Done():
		}
	}))
	defer server.Close()
	defer close(release)
	ctx, cancel := context.WithTimeout(context.Background(), 200*time.Millisecond)
	defer cancel()
	start := time.Now()
	resp := boardSend(ctx, boardDirectClient(), BoardRequest{Method: "POST", URL: server.URL})
	if resp.Status != 0 || resp.Error != "连接超时" {
		t.Fatalf("got %+v", resp)
	}
	if time.Since(start) > 2*time.Second {
		t.Fatalf("超时没有生效：等了 %v", time.Since(start))
	}
}

// 找不到出站：NoProxy 标记，Dart 据此换 DIRECT 或提示
func TestBoardSendUnknownProxy(t *testing.T) {
	resp := BoardSend(BoardRequest{Proxy: "不存在的节点", Method: "POST", URL: "https://example.com"})
	if !resp.NoProxy || resp.Status != 0 {
		t.Fatalf("got %+v", resp)
	}
	data, _ := json.Marshal(resp)
	if !strings.Contains(string(data), `"noProxy":true`) {
		t.Fatalf("JSON %s", data)
	}
}
