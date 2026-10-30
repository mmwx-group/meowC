package speedtest

import (
	"bytes"
	"context"
	"encoding/base64"
	"errors"
	"io"
	"net/http"
	"net/url"
	"strings"
	"time"
)

// 测速榜（规格 miaomiaowuC/Design/speedtest-board.md §5.2 / §5.3）：测完的结果经用户同意上传到许可证服务，服务端按**来源 IP**
// 判出口归属，所以上传 / 删除请求要经测速用的同一个出站（节点或 DIRECT）直接发，不经分流规则、不经 TUN / 本地混合端口。
//
// 地址、头、正文都由 Dart 组好：正文字节要与申请上传凭证时算 sha256 的那份一模一样，所以按 base64 原样传过来、原样发出去
// （经 JNI 的字符串会把四字节的 UTF-8 改写成 modified UTF-8，按字符串传不保证逐字节不变）。这里只管经出站发一次请求：
// 按系统根证书校验证书（同测速），整次 10 秒超时，回状态码、Retry-After 头与响应正文；成败、重试由 Dart 判断。

// BoardRequest 一次测速榜请求。
type BoardRequest struct {
	Proxy   string            `json:"proxy"`  // 节点名或 DIRECT（与测速取出站同一写法）
	Method  string            `json:"method"` // POST / DELETE
	URL     string            `json:"url"`
	Headers map[string]string `json:"headers,omitempty"`
	Body    string            `json:"body,omitempty"` // 正文的 base64（标准编码）；没有正文为空
}

// BoardResponse 一次测速榜请求的结果。
type BoardResponse struct {
	Status     int    `json:"status"`               // HTTP 状态码；0 = 没拿到应答（连不上、超时、证书不对…），原因在 Error
	RetryAfter string `json:"retryAfter,omitempty"` // 原样的 Retry-After 头（429 时有）
	Body       string `json:"body,omitempty"`       // 响应正文，至多 boardMaxBody
	Error      string `json:"error,omitempty"`
	NoProxy    bool   `json:"noProxy,omitempty"` // 当前配置里找不到这个出站（换过订阅）
}

const (
	boardTimeout = 10 * time.Second
	boardMaxBody = 64 << 10
)

// BoardSend 经 req.Proxy 发一次测速榜请求（阻塞，至多 boardTimeout）。
func BoardSend(req BoardRequest) BoardResponse {
	proxy := FindNode(req.Proxy)
	if proxy == nil {
		return BoardResponse{Error: "找不到节点 " + req.Proxy, NoProxy: true}
	}
	client := speedClient(proxy, false)
	defer client.CloseIdleConnections()
	return boardSend(context.Background(), client, req)
}

// boardSend 用给定的客户端发（单测换成指定根证书的客户端）。
func boardSend(ctx context.Context, client *http.Client, req BoardRequest) BoardResponse {
	method := strings.ToUpper(strings.TrimSpace(req.Method))
	if method != http.MethodPost && method != http.MethodDelete {
		return BoardResponse{Error: "不支持的请求方法 " + req.Method}
	}
	target, err := url.Parse(req.URL)
	if err != nil || (target.Scheme != "https" && target.Scheme != "http") || target.Host == "" {
		return BoardResponse{Error: "地址无效"}
	}
	var body []byte
	if req.Body != "" {
		if body, err = base64.StdEncoding.DecodeString(req.Body); err != nil {
			return BoardResponse{Error: "正文无效"}
		}
	}
	ctx, cancel := context.WithTimeout(ctx, boardTimeout)
	defer cancel()
	var reader io.Reader
	if len(body) > 0 {
		reader = bytes.NewReader(body)
	}
	httpReq, err := http.NewRequestWithContext(ctx, method, target.String(), reader)
	if err != nil {
		return BoardResponse{Error: err.Error()}
	}
	httpReq.Header.Set("User-Agent", "MeowX")
	for k, v := range req.Headers {
		httpReq.Header.Set(k, v)
	}
	httpReq.ContentLength = int64(len(body))
	resp, err := client.Do(httpReq)
	if err != nil {
		if errors.Is(err, context.DeadlineExceeded) || errors.Is(ctx.Err(), context.DeadlineExceeded) {
			return BoardResponse{Error: "连接超时"}
		}
		return BoardResponse{Error: err.Error()}
	}
	defer resp.Body.Close()
	data, err := io.ReadAll(io.LimitReader(resp.Body, boardMaxBody))
	out := BoardResponse{Status: resp.StatusCode, RetryAfter: resp.Header.Get("Retry-After"), Body: string(data)}
	if err != nil && len(data) == 0 {
		out.Error = err.Error()
	}
	return out
}
