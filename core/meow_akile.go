package main

import (
	"bytes"
	"context"
	"crypto/tls"
	"crypto/x509"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/netip"
	"net/url"
	"regexp"
	"strconv"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/metacubex/mihomo/component/ca"
	"github.com/metacubex/mihomo/component/dialer"
	"github.com/metacubex/mihomo/component/resolver"
	"github.com/metacubex/mihomo/log"
)

// MeowX：AkileCDN 白名单（五端共用规格：MeowX 仓库 Design/akile-whitelist.md）。
//
// AkileCDN 的转发规则可以开「入口白名单」，只放一个 IPv4。这里先查本机**直连**出口 IPv4，再用 Akile 开放接口把它写进
// 用户所选规则的入口白名单。对方不看来源 IP（IP 写在请求体里），但写进去的必须是设备直连 Akile 入口时对方看到的地址，
// 所以查出口 IP 与 po0 / GGY 一样走 mihomo 的直连 dialer（Android 经 socket protect 出 VPN，Windows TUN 下绑物理网卡，
// 见 meow_po0.go），并且只按 IPv4 连；接口请求（GET /rules、PUT）也走同一个直连 dialer，证书照常校验（同 GGY）。
//
// 一个 action 两种操作（参数 JSON 的 op）：
//   - rules：用 Key 查 listen_port 的规则（§1.1 宽松解析，客户端再按端口过滤一遍）；
//   - report：一轮上报——查一次出口 IP，再对每个节点按 rule_id 依次 PUT；timer=true（定时那一轮）时出口 IP 与这个节点
//     上一次成功写入的 IP（skip_ip，由 Dart 端带来，只在它的内存里）相同就跳过；429 / 401 / 403 时本轮剩下的不再发。
//
// 返回给 Dart 与写进日志的文字一律把 Key 换成脱敏写法 ak_••••<后 4 位>。

const (
	meowAkileOpRules  = "rules"
	meowAkileOpReport = "report"

	meowAkileKindUpdated     = "updated"
	meowAkileKindUnchanged   = "unchanged"
	meowAkileKindSkipped     = "skipped"
	meowAkileKindInvalidKey  = "invalid_key"
	meowAkileKindNotFound    = "not_found"
	meowAkileKindRateLimited = "rate_limited"
	meowAkileKindFailed      = "failed"

	meowAkileTextInvalidKey  = "API Key 无效或已删除"
	meowAkileTextNotFound    = "规则不存在（已删除，或不属于这个 API Key 的账号）"
	meowAkileTextRateLimited = "请求太频繁，稍后自动重试"
	meowAkileTextUnparsable  = "应答无法解析"
	meowAkileTextNoExitIP    = "查不到本机直连出口 IPv4"
	meowAkileTextBadKey      = "API Key 应以 ak_ 开头"

	meowAkileTimeout   = 10 * time.Second
	meowAkileIPTimeout = 5 * time.Second
	meowAkileMaxBody   = 256 << 10 // 规则列表可能不短
	meowAkileIPMaxBody = 4096
	meowAkileMaxNodes  = 20
	// 服务端给的出错文字最多留这么多个字符
	meowAkileMaxErrorRunes = 200
)

// 可注入（单测换成回环上的假服务器）
var (
	meowAkileAPIBase     = "https://cdnapi.akile.ai/api/open"
	meowAkileIPEndpoints = []meowAkileIPEndpoint{
		{URL: "http://ip.3322.net/"},                    // 正文就是一行 IP
		{URL: "http://myip.ipip.net/", FirstIPv4: true}, // 「当前 IP：1.2.3.4  来自于：…」
	}
	meowAkileRoots = func() *x509.CertPool { return ca.GetCertPool() }
)

type meowAkileIPEndpoint struct {
	URL string
	// true = 取正文里第一个 IPv4；false = 整个正文（去掉首尾空白）就是 IP
	FirstIPv4 bool
}

type meowAkileParams struct {
	Op    string            `json:"op"`
	Key   string            `json:"key"`
	Port  int               `json:"port,omitempty"`
	Timer bool              `json:"timer,omitempty"`
	Nodes []meowAkileTarget `json:"nodes,omitempty"`
}

type meowAkileTarget struct {
	RuleID int64  `json:"rule_id"`
	Name   string `json:"name,omitempty"`
	// 这个节点上一次成功写入的 IP（没成功过 / 上次失败为空）：定时那一轮出口 IP 与它相同就跳过
	SkipIP string `json:"skip_ip,omitempty"`
}

type meowAkileRule struct {
	ID             int64  `json:"id"`
	EntryWhitelist string `json:"entry_whitelist"`
	Summary        string `json:"summary"`
	NodeID         string `json:"node_id"`
	ListenPort     int64  `json:"listen_port,omitempty"`
}

type meowAkileRulesResult struct {
	Rules []meowAkileRule `json:"rules"`
	// 出错时：invalid_key | not_found | rate_limited | failed，Error 是界面文字
	Kind  string `json:"kind,omitempty"`
	Error string `json:"error,omitempty"`
}

type meowAkileNodeResult struct {
	RuleID   int64  `json:"rule_id"`
	OK       bool   `json:"ok"`
	Kind     string `json:"kind"`
	IP       string `json:"ip,omitempty"`
	Previous string `json:"previous,omitempty"`
	Error    string `json:"error,omitempty"`
}

type meowAkileReportResult struct {
	// 本次查到的出口 IP（查不到为空，原因在 IPError：只给日志用）
	IP      string                `json:"ip,omitempty"`
	IPError string                `json:"ip_error,omitempty"`
	Results []meowAkileNodeResult `json:"results"`
	Error   string                `json:"error,omitempty"`
}

var meowAkileKeyPattern = regexp.MustCompile(`^ak_[A-Za-z0-9_-]{8,200}$`)

var meowAkileKeyLike = regexp.MustCompile(`ak_[A-Za-z0-9_-]{8,200}`)

// meowAkileMask 脱敏写法：ak_••••<后 4 位>。
func meowAkileMask(key string) string {
	tail := key
	if len(tail) > 4 {
		tail = tail[len(tail)-4:]
	}
	return "ak_••••" + tail
}

// meowAkileRedact 把文字里的 Key（原样出现的、以及任何像 Key 的串）换成脱敏写法。
func meowAkileRedact(s, key string) string {
	if key != "" {
		s = strings.ReplaceAll(s, key, meowAkileMask(key))
	}
	return meowAkileKeyLike.ReplaceAllStringFunc(s, meowAkileMask)
}

// ---- 解析（§1.1 / §1.2） ----

func meowAkileDecode(body []byte) (any, bool) {
	dec := json.NewDecoder(bytes.NewReader(body))
	dec.UseNumber()
	var v any
	if err := dec.Decode(&v); err != nil {
		return nil, false
	}
	return v, true
}

// meowAkileInt：JSON 整数，或纯数字字符串。
func meowAkileInt(v any) (int64, bool) {
	switch t := v.(type) {
	case json.Number:
		n, err := t.Int64()
		return n, err == nil
	case string:
		s := strings.TrimSpace(t)
		if s == "" {
			return 0, false
		}
		for _, c := range s {
			if c < '0' || c > '9' {
				return 0, false
			}
		}
		n, err := strconv.ParseInt(s, 10, 64)
		return n, err == nil
	}
	return 0, false
}

func meowAkileString(v any) string {
	switch t := v.(type) {
	case string:
		return strings.TrimSpace(t)
	case json.Number:
		return t.String()
	}
	return ""
}

// meowAkileRuleList 找规则数组：data 是数组；data 是对象时依次 data.items / data.list / data.rules；再看顶层 rules / items；
// 顶层直接是数组也认。`data: null`（Go 后端的空切片常这样写）当作没有规则。
func meowAkileRuleList(top any) ([]any, bool) {
	switch t := top.(type) {
	case []any:
		return t, true
	case map[string]any:
		if d, ok := t["data"]; ok {
			switch dd := d.(type) {
			case []any:
				return dd, true
			case nil:
				return []any{}, true
			case map[string]any:
				for _, k := range []string{"items", "list", "rules"} {
					if l, ok := dd[k].([]any); ok {
						return l, true
					}
				}
			}
		}
		for _, k := range []string{"rules", "items"} {
			if l, ok := t[k].([]any); ok {
				return l, true
			}
		}
	}
	return nil, false
}

// meowAkileParseRules 解析规则列表；第二个返回值为 false = 认不出外层结构（应答无法解析）。
func meowAkileParseRules(body []byte, port int) ([]meowAkileRule, bool) {
	top, ok := meowAkileDecode(body)
	if !ok {
		return nil, false
	}
	list, ok := meowAkileRuleList(top)
	if !ok {
		return nil, false
	}
	out := []meowAkileRule{}
	for _, item := range list {
		m, ok := item.(map[string]any)
		if !ok {
			continue
		}
		id, ok := meowAkileInt(m["id"])
		if !ok {
			continue
		}
		rule := meowAkileRule{ID: id, NodeID: meowAkileString(m["node_id"])}
		if s, ok := m["entry_whitelist"].(string); ok {
			rule.EntryWhitelist = strings.TrimSpace(s)
		}
		// 服务端可能忽略过滤参数：有 listen_port 且不是查的那个端口就丢掉，没有这个字段就保留
		if lp, present := m["listen_port"]; present && lp != nil {
			n, ok := meowAkileInt(lp)
			if !ok || n != int64(port) {
				continue
			}
			rule.ListenPort = n
		}
		for _, k := range []string{"name", "remark", "note", "description", "node_name", "target"} {
			if s, ok := m[k].(string); ok && strings.TrimSpace(s) != "" {
				rule.Summary = strings.TrimSpace(s)
				break
			}
		}
		out = append(out, rule)
	}
	return out, true
}

// meowAkileErrorText 出错应答里的文字：error（字符串，或对象里的 message）、message、msg、detail。
func meowAkileErrorText(body []byte) string {
	top, ok := meowAkileDecode(body)
	if !ok {
		return ""
	}
	m, ok := top.(map[string]any)
	if !ok {
		return ""
	}
	switch e := m["error"].(type) {
	case string:
		if s := strings.TrimSpace(e); s != "" {
			return meowAkileClip(s)
		}
	case map[string]any:
		if s, ok := e["message"].(string); ok && strings.TrimSpace(s) != "" {
			return meowAkileClip(strings.TrimSpace(s))
		}
	}
	for _, k := range []string{"message", "msg", "detail"} {
		if s, ok := m[k].(string); ok && strings.TrimSpace(s) != "" {
			return meowAkileClip(strings.TrimSpace(s))
		}
	}
	return ""
}

func meowAkileClip(s string) string {
	if utf8.RuneCountInString(s) <= meowAkileMaxErrorRunes {
		return s
	}
	r := []rune(s)
	return string(r[:meowAkileMaxErrorRunes]) + "…"
}

// meowAkileClassify：非 2xx 的状态码归类（§1.2）。
func meowAkileClassify(status int, body []byte) (kind, text string) {
	switch status {
	case http.StatusUnauthorized, http.StatusForbidden:
		return meowAkileKindInvalidKey, meowAkileTextInvalidKey
	case http.StatusNotFound:
		return meowAkileKindNotFound, meowAkileTextNotFound
	case http.StatusTooManyRequests:
		return meowAkileKindRateLimited, meowAkileTextRateLimited
	}
	if s := meowAkileErrorText(body); s != "" {
		return meowAkileKindFailed, s
	}
	return meowAkileKindFailed, fmt.Sprintf("HTTP %d", status)
}

func meowAkileOK(status int) bool { return status >= 200 && status < 300 }

// meowAkileNetError：连不上 / 超时时界面上的文字（只留原因，不带整个地址）。
func meowAkileNetError(err error) string {
	var ue *url.Error
	if errors.As(err, &ue) {
		if ue.Timeout() {
			return "连不上：超时"
		}
		err = ue.Err
	}
	return "连不上：" + err.Error()
}

// ---- 出口 IP（§2） ----

var meowAkileReserved = []netip.Prefix{
	netip.MustParsePrefix("0.0.0.0/8"),
	netip.MustParsePrefix("10.0.0.0/8"),
	netip.MustParsePrefix("100.64.0.0/10"),
	netip.MustParsePrefix("127.0.0.0/8"),
	netip.MustParsePrefix("169.254.0.0/16"),
	netip.MustParsePrefix("172.16.0.0/12"),
	netip.MustParsePrefix("192.168.0.0/16"),
	netip.MustParsePrefix("198.18.0.0/15"),
	netip.MustParsePrefix("224.0.0.0/3"), // 224/4 及以上
}

// meowAkilePublicIPv4：能解析成 IPv4、且不在保留段里。
func meowAkilePublicIPv4(s string) (string, bool) {
	addr, err := netip.ParseAddr(strings.TrimSpace(s))
	if err != nil || !addr.Is4() {
		return "", false
	}
	for _, p := range meowAkileReserved {
		if p.Contains(addr) {
			return "", false
		}
	}
	return addr.String(), true
}

var meowAkileIPv4InText = regexp.MustCompile(`\d{1,3}(?:\.\d{1,3}){3}`)

func meowAkileExtractIP(ep meowAkileIPEndpoint, body string) (string, error) {
	candidate := strings.TrimSpace(body)
	if ep.FirstIPv4 {
		candidate = meowAkileIPv4InText.FindString(body)
	}
	if ip, ok := meowAkilePublicIPv4(candidate); ok {
		return ip, nil
	}
	if candidate == "" {
		return "", errors.New("应答里没有 IPv4")
	}
	return "", fmt.Errorf("不是公网 IPv4：%s", meowAkileClip(candidate))
}

// meowAkileHTTPClient：mihomo 直连 dialer（同 po0 / GGY），network = "tcp4" 时只按 IPv4 连。
func meowAkileHTTPClient(roots *x509.CertPool, network string, timeout time.Duration) *http.Client {
	return &http.Client{
		Timeout: timeout,
		Transport: &http.Transport{
			Proxy: nil, // 不读环境变量里的代理
			DialContext: func(ctx context.Context, _, addr string) (net.Conn, error) {
				opts := []dialer.Option{}
				if resolver.DirectHostResolver != nil {
					opts = append(opts, dialer.WithResolver(resolver.DirectHostResolver))
				}
				return dialer.DialContext(ctx, network, addr, opts...)
			},
			TLSClientConfig:   &tls.Config{RootCAs: roots},
			DisableKeepAlives: true,
		},
	}
}

func meowAkileAskIP(ctx context.Context, client *http.Client, ep meowAkileIPEndpoint) (string, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, ep.URL, nil)
	if err != nil {
		return "", err
	}
	resp, err := client.Do(req)
	if err != nil {
		var ue *url.Error
		if errors.As(err, &ue) {
			if ue.Timeout() {
				return "", errors.New("超时")
			}
			return "", ue.Err
		}
		return "", err
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(io.LimitReader(resp.Body, meowAkileIPMaxBody))
	if resp.StatusCode != http.StatusOK {
		return "", fmt.Errorf("HTTP %d", resp.StatusCode)
	}
	return meowAkileExtractIP(ep, string(body))
}

// meowAkileExitIP 并发问各个端点，谁先给出合法地址用谁；都失败时把各自的原因拼起来（按端点顺序）。
func meowAkileExitIP(ctx context.Context) (string, error) {
	eps := meowAkileIPEndpoints
	if len(eps) == 0 {
		return "", errors.New("没有查询端点")
	}
	ctx, cancel := context.WithTimeout(ctx, meowAkileIPTimeout)
	defer cancel()
	client := meowAkileHTTPClient(nil, "tcp4", meowAkileIPTimeout)
	type answer struct {
		i   int
		ip  string
		err error
	}
	ch := make(chan answer, len(eps))
	for i, ep := range eps {
		go func(i int, ep meowAkileIPEndpoint) {
			ip, err := meowAkileAskIP(ctx, client, ep)
			ch <- answer{i, ip, err}
		}(i, ep)
	}
	errs := make([]string, len(eps))
	for range eps {
		a := <-ch
		if a.err == nil {
			return a.ip, nil
		}
		host := eps[a.i].URL
		if u, err := url.Parse(host); err == nil && u.Host != "" {
			host = u.Host
		}
		errs[a.i] = host + "：" + a.err.Error()
	}
	return "", errors.New(strings.Join(errs, "；"))
}

// ---- 接口请求（§1） ----

func meowAkileRequest(ctx context.Context, method, path, key string, body []byte) (*http.Request, error) {
	var r io.Reader
	if body != nil {
		r = bytes.NewReader(body)
	}
	req, err := http.NewRequestWithContext(ctx, method, strings.TrimRight(meowAkileAPIBase, "/")+path, r)
	if err != nil {
		return nil, err
	}
	req.Header.Set("X-API-Key", key)
	req.Header.Set("Accept", "application/json")
	req.Header.Set("User-Agent", "MeowX")
	if body != nil {
		req.Header.Set("Content-Type", "application/json")
	}
	return req, nil
}

func meowAkileDo(client *http.Client, req *http.Request) (int, []byte, error) {
	resp, err := client.Do(req)
	if err != nil {
		return 0, nil, err
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(io.LimitReader(resp.Body, meowAkileMaxBody))
	return resp.StatusCode, body, nil
}

// meowAkileFetchRules：GET /rules?listen_port=<port>。
func meowAkileFetchRules(ctx context.Context, client *http.Client, key string, port int) meowAkileRulesResult {
	res := meowAkileRulesResult{Rules: []meowAkileRule{}}
	fail := func(kind, text string) meowAkileRulesResult {
		res.Kind, res.Error = kind, meowAkileRedact(text, key)
		return res
	}
	if !meowAkileKeyPattern.MatchString(key) {
		return fail(meowAkileKindFailed, meowAkileTextBadKey)
	}
	if port <= 0 || port > 65535 {
		return fail(meowAkileKindFailed, "端口无效")
	}
	req, err := meowAkileRequest(ctx, http.MethodGet, "/rules?listen_port="+strconv.Itoa(port), key, nil)
	if err != nil {
		return fail(meowAkileKindFailed, err.Error())
	}
	status, body, err := meowAkileDo(client, req)
	if err != nil {
		text := meowAkileNetError(err)
		log.Warnln("[MeowX] AkileCDN 白名单 查规则（端口 %d）：%s", port, meowAkileRedact(text, key))
		return fail(meowAkileKindFailed, text)
	}
	if !meowAkileOK(status) {
		return fail(meowAkileClassify(status, body))
	}
	rules, ok := meowAkileParseRules(body, port)
	if !ok {
		return fail(meowAkileKindFailed, meowAkileTextUnparsable)
	}
	for i := range rules {
		rules[i].Summary = meowAkileRedact(rules[i].Summary, key)
	}
	res.Rules = rules
	return res
}

// meowAkilePut：PUT /rules/<id>/entry-whitelist，正文 {"entry_whitelist":"<ip>"}。
func meowAkilePut(ctx context.Context, client *http.Client, key string, ruleID int64, ip string) meowAkileNodeResult {
	res := meowAkileNodeResult{RuleID: ruleID, IP: ip}
	fail := func(kind, text string) meowAkileNodeResult {
		res.Kind, res.Error = kind, meowAkileRedact(text, key)
		return res
	}
	payload, _ := json.Marshal(map[string]string{"entry_whitelist": ip})
	req, err := meowAkileRequest(ctx, http.MethodPut, "/rules/"+strconv.FormatInt(ruleID, 10)+"/entry-whitelist", key, payload)
	if err != nil {
		return fail(meowAkileKindFailed, err.Error())
	}
	status, body, err := meowAkileDo(client, req)
	if err != nil {
		text := meowAkileNetError(err)
		log.Warnln("[MeowX] AkileCDN 白名单 规则 #%d：%s", ruleID, meowAkileRedact(text, key))
		return fail(meowAkileKindFailed, text)
	}
	if !meowAkileOK(status) {
		return fail(meowAkileClassify(status, body))
	}
	top, _ := meowAkileDecode(body)
	m, _ := top.(map[string]any)
	data, _ := m["data"].(map[string]any)
	if data == nil {
		return fail(meowAkileKindFailed, meowAkileTextUnparsable)
	}
	if _, ok := meowAkileInt(data["id"]); !ok {
		return fail(meowAkileKindFailed, meowAkileTextUnparsable)
	}
	if s, ok := data["entry_whitelist"].(string); ok && strings.TrimSpace(s) != "" {
		res.IP = strings.TrimSuffix(strings.TrimSpace(s), "/32")
	}
	if s, ok := data["previous"].(string); ok {
		res.Previous = strings.TrimSuffix(strings.TrimSpace(s), "/32")
	}
	changed, ok := data["changed"].(bool)
	if !ok {
		changed = res.Previous != res.IP
	}
	res.OK = true
	res.Kind = meowAkileKindUnchanged
	if changed {
		res.Kind = meowAkileKindUpdated
	}
	return res
}

func meowAkileRules(ctx context.Context, p meowAkileParams) meowAkileRulesResult {
	client := meowAkileHTTPClient(meowAkileRoots(), "tcp", meowAkileTimeout)
	return meowAkileFetchRules(ctx, client, p.Key, p.Port)
}

// meowAkileReport：一轮上报（§4）。
func meowAkileReport(ctx context.Context, p meowAkileParams) meowAkileReportResult {
	res := meowAkileReportResult{Results: []meowAkileNodeResult{}}
	if !meowAkileKeyPattern.MatchString(p.Key) {
		res.Error = meowAkileTextBadKey
		return res
	}
	nodes := p.Nodes
	if len(nodes) > meowAkileMaxNodes {
		nodes = nodes[:meowAkileMaxNodes]
	}
	if len(nodes) == 0 {
		return res
	}
	ip, err := meowAkileExitIP(ctx)
	if err != nil {
		res.IPError = meowAkileRedact(err.Error(), p.Key)
		log.Warnln("[MeowX] AkileCDN 白名单：%s（%s）", meowAkileTextNoExitIP, res.IPError)
		for _, n := range nodes {
			res.Results = append(res.Results, meowAkileNodeResult{RuleID: n.RuleID, Kind: meowAkileKindFailed, Error: meowAkileTextNoExitIP})
		}
		return res
	}
	res.IP = ip
	client := meowAkileHTTPClient(meowAkileRoots(), "tcp", meowAkileTimeout)
	var abort *meowAkileNodeResult
	for _, n := range nodes {
		if p.Timer && n.SkipIP != "" && n.SkipIP == ip {
			res.Results = append(res.Results, meowAkileNodeResult{RuleID: n.RuleID, OK: true, Kind: meowAkileKindSkipped, IP: ip})
			continue
		}
		if abort != nil {
			// 429 / Key 无效：本轮剩下的不再发，记同样的结果
			r := *abort
			r.RuleID = n.RuleID
			res.Results = append(res.Results, r)
			continue
		}
		r := meowAkilePut(ctx, client, p.Key, n.RuleID, ip)
		if r.Kind == meowAkileKindInvalidKey || r.Kind == meowAkileKindRateLimited {
			a := meowAkileNodeResult{Kind: r.Kind, Error: r.Error, IP: ip}
			abort = &a
		}
		res.Results = append(res.Results, r)
	}
	return res
}

// handleMeowAkile 可能要发好几个请求，放到 goroutine 里，做完回调（JSON）。
func handleMeowAkile(paramsString string, fn func(string)) {
	go func() {
		var p meowAkileParams
		var out any
		if err := json.Unmarshal([]byte(paramsString), &p); err != nil {
			out = map[string]string{"error": "参数无效"}
		} else {
			// 一轮最多：查 IP 5s + 每个节点 10s
			ctx, cancel := context.WithTimeout(context.Background(), meowAkileIPTimeout+meowAkileTimeout*time.Duration(meowAkileMaxNodes+1))
			switch p.Op {
			case meowAkileOpRules:
				out = meowAkileRules(ctx, p)
			case meowAkileOpReport:
				out = meowAkileReport(ctx, p)
			default:
				out = map[string]string{"error": "参数无效"}
			}
			cancel()
		}
		data, err := json.Marshal(out)
		if err != nil {
			fn(`{"error":"参数无效"}`)
			return
		}
		fn(string(data))
	}()
}
