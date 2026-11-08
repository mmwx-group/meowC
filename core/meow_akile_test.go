package main

import (
	"context"
	"crypto/x509"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/metacubex/mihomo/log"
)

// 只用假 Key，绝不打真正的 cdnapi.akile.ai：接口地址与出口 IP 端点都换成回环上的假服务器。
const meowAkileTestKey = "ak_TESTkey0000000000AAAA"

func TestMeowAkileMaskRedact(t *testing.T) {
	if got := meowAkileMask(meowAkileTestKey); got != "ak_••••AAAA" {
		t.Errorf("mask = %q", got)
	}
	in := `{"error":"invalid key ` + meowAkileTestKey + `"} 另一把 ak_otherKEY12345678ZZZZ`
	got := meowAkileRedact(in, meowAkileTestKey)
	if strings.Contains(got, "TESTkey") || strings.Contains(got, "otherKEY") {
		t.Errorf("redact = %q", got)
	}
	if !strings.Contains(got, "ak_••••AAAA") || !strings.Contains(got, "ak_••••ZZZZ") {
		t.Errorf("redact = %q", got)
	}
}

func TestMeowAkileParseRulesShapes(t *testing.T) {
	item := `{"id":7,"entry_whitelist":"1.2.3.4/32","name":"香港 01","node_id":3,"listen_port":443}`
	cases := map[string]string{
		"data 数组":         `{"data":[` + item + `]}`,
		"data.items":      `{"data":{"items":[` + item + `],"total":1}}`,
		"data.list":       `{"data":{"list":[` + item + `]}}`,
		"data.rules":      `{"data":{"rules":[` + item + `]}}`,
		"顶层 rules":        `{"rules":[` + item + `]}`,
		"顶层 items":        `{"items":[` + item + `]}`,
		"顶层数组":            `[` + item + `]`,
		"data 对象里找不到再看顶层": `{"data":{"page":1},"rules":[` + item + `]}`,
	}
	for name, body := range cases {
		rules, ok := meowAkileParseRules([]byte(body), 443)
		if !ok || len(rules) != 1 {
			t.Errorf("%s: ok=%v rules=%+v", name, ok, rules)
			continue
		}
		want := meowAkileRule{ID: 7, EntryWhitelist: "1.2.3.4/32", Summary: "香港 01", NodeID: "3", ListenPort: 443}
		if rules[0] != want {
			t.Errorf("%s: rule = %+v", name, rules[0])
		}
	}
	if rules, ok := meowAkileParseRules([]byte(`{"data":null}`), 443); !ok || len(rules) != 0 {
		t.Errorf("data null: ok=%v rules=%+v", ok, rules)
	}
	for _, bad := range []string{`{"data":{"page":1}}`, `{"ok":true}`, `"x"`, `not json`, ``, `{"data":"x"}`} {
		if _, ok := meowAkileParseRules([]byte(bad), 443); ok {
			t.Errorf("%q 应认不出", bad)
		}
	}
}

func TestMeowAkileParseRulesItems(t *testing.T) {
	body := `{"data":[
		{"id":"12","remark":"  ","note":"备注","node_id":"hk-1"},
		{"id":1.5,"name":"小数 id 丢掉"},
		{"id":"12a","name":"非纯数字丢掉"},
		{"name":"没有 id 丢掉"},
		{"id":13,"listen_port":8443,"name":"端口不对丢掉"},
		{"id":14,"listen_port":"443","description":"字符串端口"},
		{"id":15,"listen_port":"abc","name":"端口认不出丢掉"},
		{"id":16,"listen_port":null,"target":"1.1.1.1:443"},
		{"id":17},
		"不是对象"
	]}`
	rules, ok := meowAkileParseRules([]byte(body), 443)
	if !ok {
		t.Fatal("not ok")
	}
	want := []meowAkileRule{
		{ID: 12, Summary: "备注", NodeID: "hk-1"},
		{ID: 14, Summary: "字符串端口", ListenPort: 443},
		{ID: 16, Summary: "1.1.1.1:443"},
		{ID: 17},
	}
	if len(rules) != len(want) {
		t.Fatalf("rules = %+v", rules)
	}
	for i := range want {
		if rules[i] != want[i] {
			t.Errorf("rules[%d] = %+v, want %+v", i, rules[i], want[i])
		}
	}
}

func TestMeowAkileClassify(t *testing.T) {
	cases := []struct {
		status     int
		body       string
		kind, text string
	}{
		{401, `{"error":"unauthorized"}`, meowAkileKindInvalidKey, meowAkileTextInvalidKey},
		{403, ``, meowAkileKindInvalidKey, meowAkileTextInvalidKey},
		{404, `{"error":"not found"}`, meowAkileKindNotFound, meowAkileTextNotFound},
		{429, ``, meowAkileKindRateLimited, meowAkileTextRateLimited},
		{400, `{"error":"节点开着白名单时不能清空"}`, meowAkileKindFailed, "节点开着白名单时不能清空"},
		{400, `{"error":{"code":1,"message":"对象里的 message"}}`, meowAkileKindFailed, "对象里的 message"},
		{500, `{"error":"","message":"m"}`, meowAkileKindFailed, "m"},
		{500, `{"msg":"msg 字段"}`, meowAkileKindFailed, "msg 字段"},
		{502, `{"detail":"detail 字段"}`, meowAkileKindFailed, "detail 字段"},
		{503, `<html>bad gateway</html>`, meowAkileKindFailed, "HTTP 503"},
		{500, `{"code":500}`, meowAkileKindFailed, "HTTP 500"},
	}
	for _, c := range cases {
		kind, text := meowAkileClassify(c.status, []byte(c.body))
		if kind != c.kind || text != c.text {
			t.Errorf("%d %s → (%q, %q), want (%q, %q)", c.status, c.body, kind, text, c.kind, c.text)
		}
	}
}

func TestMeowAkilePublicIPv4(t *testing.T) {
	good := []string{"203.0.113.10", " 1.2.3.4\n", "223.255.255.255", "100.63.255.255", "172.32.0.1", "198.20.0.1"}
	bad := []string{"", "0.1.2.3", "10.0.0.1", "100.64.0.1", "100.127.255.255", "127.0.0.1", "169.254.1.1", "172.16.0.1",
		"172.31.255.255", "192.168.1.1", "198.18.0.1", "198.19.255.255", "224.0.0.1", "240.0.0.1", "255.255.255.255",
		"2001:db8::1", "::ffff:1.2.3.4", "1.2.3", "01.2.3.4", "abc"}
	for _, s := range good {
		if _, ok := meowAkilePublicIPv4(s); !ok {
			t.Errorf("%q 应合法", s)
		}
	}
	for _, s := range bad {
		if ip, ok := meowAkilePublicIPv4(s); ok {
			t.Errorf("%q 应不合法，得到 %q", s, ip)
		}
	}
}

// ---- 假服务器 ----

type meowAkileFake struct {
	t   *testing.T
	api *httptest.Server
	mu  sync.Mutex
	// 收到的 PUT（rule_id → 正文）与请求头
	puts    []string
	bodies  []string
	keys    []string
	ctypes  []string
	queries []string
	// rule_id → 回应（状态码 + 正文）
	putReply  map[string]func() (int, string)
	rulesBody func(r *http.Request) (int, string)
}

func newMeowAkileFake(t *testing.T) *meowAkileFake {
	f := &meowAkileFake{t: t, putReply: map[string]func() (int, string){}}
	f.api = httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		body, _ := io.ReadAll(r.Body)
		f.mu.Lock()
		f.keys = append(f.keys, r.Header.Get("X-API-Key"))
		f.mu.Unlock()
		w.Header().Set("Content-Type", "application/json")
		switch {
		case r.Method == http.MethodGet && r.URL.Path == "/api/open/rules":
			f.mu.Lock()
			f.queries = append(f.queries, r.URL.RawQuery)
			f.mu.Unlock()
			status, out := 200, `{"data":[]}`
			if f.rulesBody != nil {
				status, out = f.rulesBody(r)
			}
			w.WriteHeader(status)
			_, _ = w.Write([]byte(out))
		case r.Method == http.MethodPut && strings.HasPrefix(r.URL.Path, "/api/open/rules/") && strings.HasSuffix(r.URL.Path, "/entry-whitelist"):
			id := strings.TrimSuffix(strings.TrimPrefix(r.URL.Path, "/api/open/rules/"), "/entry-whitelist")
			f.mu.Lock()
			f.puts = append(f.puts, id)
			f.bodies = append(f.bodies, string(body))
			f.ctypes = append(f.ctypes, r.Header.Get("Content-Type"))
			reply := f.putReply[id]
			f.mu.Unlock()
			status, out := 200, fmt.Sprintf(`{"data":{"id":%s,"entry_whitelist":"203.0.113.10/32","previous":"198.51.100.1/32","changed":true}}`, id)
			if reply != nil {
				status, out = reply()
			}
			w.WriteHeader(status)
			_, _ = w.Write([]byte(out))
		default:
			w.WriteHeader(http.StatusTeapot)
		}
	}))
	t.Cleanup(f.api.Close)
	roots := x509.NewCertPool()
	roots.AddCert(f.api.Certificate())
	oldBase, oldRoots := meowAkileAPIBase, meowAkileRoots
	meowAkileAPIBase = f.api.URL + "/api/open"
	meowAkileRoots = func() *x509.CertPool { return roots }
	t.Cleanup(func() { meowAkileAPIBase, meowAkileRoots = oldBase, oldRoots })
	return f
}

func (f *meowAkileFake) putIDs() []string {
	f.mu.Lock()
	defer f.mu.Unlock()
	return append([]string(nil), f.puts...)
}

// meowAkileIPServers 换掉出口 IP 端点：每个参数是一个端点的正文（"" = 回 500，"slow" = 不回应直到超时）。
func meowAkileIPServers(t *testing.T, bodies ...string) {
	t.Helper()
	old := meowAkileIPEndpoints
	t.Cleanup(func() { meowAkileIPEndpoints = old })
	var eps []meowAkileIPEndpoint
	for i, b := range bodies {
		b := b
		srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			switch b {
			case "":
				w.WriteHeader(500)
			case "slow":
				select {
				case <-r.Context().Done():
				case <-time.After(10 * time.Second):
				}
			default:
				_, _ = w.Write([]byte(b))
			}
		}))
		t.Cleanup(srv.Close)
		eps = append(eps, meowAkileIPEndpoint{URL: srv.URL + "/", FirstIPv4: i == 1})
	}
	meowAkileIPEndpoints = eps
}

func meowAkileInvoke(t *testing.T, params any) string {
	t.Helper()
	raw, _ := json.Marshal(params)
	ch := make(chan string, 1)
	handleMeowAkile(string(raw), func(v string) { ch <- v })
	select {
	case v := <-ch:
		return v
	case <-time.After(30 * time.Second):
		t.Fatal("timeout")
		return ""
	}
}

func meowAkileReportOf(t *testing.T, params meowAkileParams) (meowAkileReportResult, string) {
	t.Helper()
	params.Op = meowAkileOpReport
	raw := meowAkileInvoke(t, params)
	var out meowAkileReportResult
	if err := json.Unmarshal([]byte(raw), &out); err != nil {
		t.Fatalf("unmarshal %q: %v", raw, err)
	}
	return out, raw
}

// ---- 出口 IP ----

func TestMeowAkileExitIP(t *testing.T) {
	t.Run("正文一行 IP", func(t *testing.T) {
		meowAkileIPServers(t, "203.0.113.10\n", "")
		if ip, err := meowAkileExitIP(context.Background()); err != nil || ip != "203.0.113.10" {
			t.Errorf("ip=%q err=%v", ip, err)
		}
	})
	t.Run("ipip 的写法取第一个 IPv4", func(t *testing.T) {
		meowAkileIPServers(t, "", "当前 IP：198.51.100.7  来自于：中国 浙江 杭州  联通 1.1.1.1")
		if ip, err := meowAkileExitIP(context.Background()); err != nil || ip != "198.51.100.7" {
			t.Errorf("ip=%q err=%v", ip, err)
		}
	})
	t.Run("一个不合法另一个合法", func(t *testing.T) {
		meowAkileIPServers(t, "192.168.1.2", "当前 IP：203.0.113.9  来自于：…")
		if ip, err := meowAkileExitIP(context.Background()); err != nil || ip != "203.0.113.9" {
			t.Errorf("ip=%q err=%v", ip, err)
		}
	})
	t.Run("先到的合法地址用它（另一个慢的不等）", func(t *testing.T) {
		meowAkileIPServers(t, "slow", "当前 IP：203.0.113.8")
		start := time.Now()
		if ip, err := meowAkileExitIP(context.Background()); err != nil || ip != "203.0.113.8" {
			t.Errorf("ip=%q err=%v", ip, err)
		}
		if time.Since(start) > 3*time.Second {
			t.Errorf("等了 %v", time.Since(start))
		}
	})
	t.Run("都不行：原因按端点顺序拼起来", func(t *testing.T) {
		meowAkileIPServers(t, "10.0.0.1", "")
		ip, err := meowAkileExitIP(context.Background())
		if err == nil || ip != "" {
			t.Fatalf("ip=%q err=%v", ip, err)
		}
		parts := strings.Split(err.Error(), "；")
		if len(parts) != 2 || !strings.Contains(parts[0], "不是公网 IPv4：10.0.0.1") || !strings.Contains(parts[1], "HTTP 500") {
			t.Errorf("err = %q", err)
		}
	})
}

// ---- 查规则 ----

func TestMeowAkileRulesOp(t *testing.T) {
	f := newMeowAkileFake(t)
	f.rulesBody = func(r *http.Request) (int, string) {
		return 200, `{"data":{"items":[
			{"id":7,"entry_whitelist":"1.2.3.4/32","name":"香港 01","node_id":3,"listen_port":443},
			{"id":8,"entry_whitelist":"","remark":"别的端口","listen_port":8443}
		]}}`
	}
	raw := meowAkileInvoke(t, meowAkileParams{Op: meowAkileOpRules, Key: meowAkileTestKey, Port: 443})
	var res meowAkileRulesResult
	if err := json.Unmarshal([]byte(raw), &res); err != nil {
		t.Fatal(err)
	}
	if res.Error != "" || len(res.Rules) != 1 || res.Rules[0].ID != 7 || res.Rules[0].Summary != "香港 01" || res.Rules[0].NodeID != "3" {
		t.Errorf("res = %+v", res)
	}
	if len(f.queries) != 1 || f.queries[0] != "listen_port=443" || f.keys[0] != meowAkileTestKey {
		t.Errorf("queries=%v keys=%v", f.queries, f.keys)
	}

	// 出错：服务端把 Key 原样写进出错文字也只留脱敏写法
	f.rulesBody = func(r *http.Request) (int, string) {
		return 400, `{"error":"bad key ` + meowAkileTestKey + `"}`
	}
	raw = meowAkileInvoke(t, meowAkileParams{Op: meowAkileOpRules, Key: meowAkileTestKey, Port: 443})
	if strings.Contains(raw, "TESTkey") || !strings.Contains(raw, "ak_••••AAAA") || !strings.Contains(raw, `"kind":"failed"`) {
		t.Errorf("raw = %s", raw)
	}
	f.rulesBody = func(r *http.Request) (int, string) { return 401, `{}` }
	raw = meowAkileInvoke(t, meowAkileParams{Op: meowAkileOpRules, Key: meowAkileTestKey, Port: 443})
	if !strings.Contains(raw, `"kind":"invalid_key"`) || !strings.Contains(raw, meowAkileTextInvalidKey) {
		t.Errorf("raw = %s", raw)
	}
	f.rulesBody = func(r *http.Request) (int, string) { return 200, `{"ok":true}` }
	raw = meowAkileInvoke(t, meowAkileParams{Op: meowAkileOpRules, Key: meowAkileTestKey, Port: 443})
	if !strings.Contains(raw, meowAkileTextUnparsable) {
		t.Errorf("raw = %s", raw)
	}

	// Key 不合法 / 端口无效：不发请求
	before := len(f.queries)
	raw = meowAkileInvoke(t, meowAkileParams{Op: meowAkileOpRules, Key: "sk_nope", Port: 443})
	if !strings.Contains(raw, meowAkileTextBadKey) {
		t.Errorf("raw = %s", raw)
	}
	raw = meowAkileInvoke(t, meowAkileParams{Op: meowAkileOpRules, Key: meowAkileTestKey, Port: 0})
	if !strings.Contains(raw, "端口无效") || len(f.queries) != before {
		t.Errorf("raw = %s queries=%v", raw, f.queries)
	}
}

// ---- 一轮上报 ----

func TestMeowAkileReportBasic(t *testing.T) {
	f := newMeowAkileFake(t)
	meowAkileIPServers(t, "203.0.113.10", "")
	f.putReply["2"] = func() (int, string) {
		return 200, `{"data":{"id":2,"entry_whitelist":"203.0.113.10/32","previous":"203.0.113.10/32","changed":false}}`
	}
	res, raw := meowAkileReportOf(t, meowAkileParams{Key: meowAkileTestKey, Nodes: []meowAkileTarget{
		{RuleID: 1, Name: "香港"}, {RuleID: 2, Name: "日本"},
	}})
	if res.IP != "203.0.113.10" || len(res.Results) != 2 {
		t.Fatalf("raw = %s", raw)
	}
	want := []meowAkileNodeResult{
		{RuleID: 1, OK: true, Kind: meowAkileKindUpdated, IP: "203.0.113.10", Previous: "198.51.100.1"},
		{RuleID: 2, OK: true, Kind: meowAkileKindUnchanged, IP: "203.0.113.10", Previous: "203.0.113.10"},
	}
	for i := range want {
		if res.Results[i] != want[i] {
			t.Errorf("results[%d] = %+v, want %+v", i, res.Results[i], want[i])
		}
	}
	if ids := f.putIDs(); strings.Join(ids, ",") != "1,2" {
		t.Errorf("puts = %v", ids)
	}
	for i := range f.bodies {
		if f.bodies[i] != `{"entry_whitelist":"203.0.113.10"}` || f.ctypes[i] != "application/json" || f.keys[i] != meowAkileTestKey {
			t.Errorf("put %d body=%q ctype=%q key=%q", i, f.bodies[i], f.ctypes[i], f.keys[i])
		}
	}
	if strings.Contains(raw, "TESTkey") {
		t.Errorf("结果里出现了 Key：%s", raw)
	}
}

// 定时那一轮：出口 IP 与上一次成功写入的相同就跳过；其它时机一律 PUT。
func TestMeowAkileReportTimerSkip(t *testing.T) {
	f := newMeowAkileFake(t)
	meowAkileIPServers(t, "203.0.113.10", "")
	nodes := []meowAkileTarget{
		{RuleID: 1, SkipIP: "203.0.113.10"}, // 没变 → 跳过
		{RuleID: 2, SkipIP: "198.51.100.1"}, // 变了 → PUT
		{RuleID: 3},                         // 没成功过 → PUT
	}
	res, raw := meowAkileReportOf(t, meowAkileParams{Key: meowAkileTestKey, Timer: true, Nodes: nodes})
	if len(res.Results) != 3 || res.Results[0].Kind != meowAkileKindSkipped || !res.Results[0].OK ||
		res.Results[1].Kind != meowAkileKindUpdated || res.Results[2].Kind != meowAkileKindUpdated {
		t.Errorf("raw = %s", raw)
	}
	if ids := f.putIDs(); strings.Join(ids, ",") != "2,3" {
		t.Errorf("puts = %v", ids)
	}

	// 不是定时轮：带着 skip_ip 也照样 PUT
	res, raw = meowAkileReportOf(t, meowAkileParams{Key: meowAkileTestKey, Nodes: nodes[:1]})
	if len(res.Results) != 1 || res.Results[0].Kind != meowAkileKindUpdated {
		t.Errorf("raw = %s", raw)
	}
	if ids := f.putIDs(); strings.Join(ids, ",") != "2,3,1" {
		t.Errorf("puts = %v", ids)
	}
}

// 429 / 401 / 403：本轮剩下的不再发，记同样的结果；404 与别的失败不影响后面的。
func TestMeowAkileReportTruncate(t *testing.T) {
	for _, c := range []struct {
		status int
		kind   string
		text   string
	}{
		{429, meowAkileKindRateLimited, meowAkileTextRateLimited},
		{401, meowAkileKindInvalidKey, meowAkileTextInvalidKey},
		{403, meowAkileKindInvalidKey, meowAkileTextInvalidKey},
	} {
		t.Run(fmt.Sprint(c.status), func(t *testing.T) {
			f := newMeowAkileFake(t)
			meowAkileIPServers(t, "203.0.113.10", "")
			f.putReply["2"] = func() (int, string) { return c.status, `{"error":"x"}` }
			res, raw := meowAkileReportOf(t, meowAkileParams{Key: meowAkileTestKey, Nodes: []meowAkileTarget{
				{RuleID: 1}, {RuleID: 2}, {RuleID: 3}, {RuleID: 4},
			}})
			if ids := f.putIDs(); strings.Join(ids, ",") != "1,2" {
				t.Errorf("puts = %v", ids)
			}
			if len(res.Results) != 4 || res.Results[0].Kind != meowAkileKindUpdated {
				t.Fatalf("raw = %s", raw)
			}
			for i, r := range res.Results[1:] {
				if r.RuleID != int64(i+2) || r.OK || r.Kind != c.kind || r.Error != c.text {
					t.Errorf("results[%d] = %+v", i+1, r)
				}
			}
		})
	}

	f := newMeowAkileFake(t)
	meowAkileIPServers(t, "203.0.113.10", "")
	f.putReply["1"] = func() (int, string) { return 404, `{"error":"rule not found"}` }
	f.putReply["2"] = func() (int, string) { return 400, `{"error":"节点开着白名单时不能清空"}` }
	f.putReply["3"] = func() (int, string) { return 200, `{"ok":true}` }
	res, raw := meowAkileReportOf(t, meowAkileParams{Key: meowAkileTestKey, Nodes: []meowAkileTarget{
		{RuleID: 1}, {RuleID: 2}, {RuleID: 3}, {RuleID: 4},
	}})
	if ids := f.putIDs(); strings.Join(ids, ",") != "1,2,3,4" {
		t.Errorf("puts = %v", ids)
	}
	want := []struct{ kind, text string }{
		{meowAkileKindNotFound, meowAkileTextNotFound},
		{meowAkileKindFailed, "节点开着白名单时不能清空"},
		{meowAkileKindFailed, meowAkileTextUnparsable},
		{meowAkileKindUpdated, ""},
	}
	for i, w := range want {
		if res.Results[i].Kind != w.kind || res.Results[i].Error != w.text {
			t.Errorf("results[%d] = %+v (raw %s)", i, res.Results[i], raw)
		}
	}
}

// 查不到出口 IP：所有节点记失败，不发 PUT。
func TestMeowAkileReportNoExitIP(t *testing.T) {
	f := newMeowAkileFake(t)
	meowAkileIPServers(t, "192.168.1.2", "当前 IP：127.0.0.1")
	res, raw := meowAkileReportOf(t, meowAkileParams{Key: meowAkileTestKey, Timer: true, Nodes: []meowAkileTarget{
		{RuleID: 1, SkipIP: "203.0.113.10"}, {RuleID: 2},
	}})
	if len(f.putIDs()) != 0 {
		t.Errorf("puts = %v", f.putIDs())
	}
	if res.IP != "" || res.IPError == "" || len(res.Results) != 2 {
		t.Fatalf("raw = %s", raw)
	}
	for _, r := range res.Results {
		if r.OK || r.Kind != meowAkileKindFailed || r.Error != meowAkileTextNoExitIP {
			t.Errorf("result = %+v", r)
		}
	}
}

// 连不上接口、服务端把 Key 写进应答：结果与核心日志里都只有脱敏写法。
func TestMeowAkileKeyNeverLeaks(t *testing.T) {
	var mu sync.Mutex
	var logs []string
	sub := log.Subscribe()
	done := make(chan struct{})
	go func() {
		defer close(done)
		for ev := range sub {
			mu.Lock()
			logs = append(logs, ev.Payload)
			mu.Unlock()
		}
	}()
	defer func() {
		log.UnSubscribe(sub)
		<-done
	}()

	f := newMeowAkileFake(t)
	meowAkileIPServers(t, "203.0.113.10", "")
	f.putReply["1"] = func() (int, string) { return 500, `{"message":"key ` + meowAkileTestKey + ` rejected"}` }
	_, raw1 := meowAkileReportOf(t, meowAkileParams{Key: meowAkileTestKey, Nodes: []meowAkileTarget{{RuleID: 1}}})

	// 接口连不上（关掉的端口）
	ln, _ := net.Listen("tcp", "127.0.0.1:0")
	addr := ln.Addr().String()
	_ = ln.Close()
	meowAkileAPIBase = "https://" + addr + "/api/open"
	_, raw2 := meowAkileReportOf(t, meowAkileParams{Key: meowAkileTestKey, Nodes: []meowAkileTarget{{RuleID: 1}}})
	raw3 := meowAkileInvoke(t, meowAkileParams{Op: meowAkileOpRules, Key: meowAkileTestKey, Port: 443})

	// 出口 IP 也查不到
	meowAkileIPServers(t, "", "")
	_, raw4 := meowAkileReportOf(t, meowAkileParams{Key: meowAkileTestKey, Nodes: []meowAkileTarget{{RuleID: 1}}})

	for _, raw := range []string{raw1, raw2, raw3, raw4} {
		if strings.Contains(raw, "TESTkey") {
			t.Errorf("结果里出现了 Key：%s", raw)
		}
	}
	if !strings.Contains(raw1, "key ak_••••AAAA rejected") || !strings.Contains(raw2, "连不上") || !strings.Contains(raw3, "连不上") {
		t.Errorf("raw1=%s raw2=%s raw3=%s", raw1, raw2, raw3)
	}
	time.Sleep(200 * time.Millisecond)
	mu.Lock()
	defer mu.Unlock()
	if len(logs) == 0 {
		t.Error("应有告警日志")
	}
	for _, l := range logs {
		if strings.Contains(l, "TESTkey") {
			t.Errorf("日志里出现了 Key：%s", l)
		}
	}
}

func TestMeowAkileBadParams(t *testing.T) {
	ch := make(chan string, 1)
	handleMeowAkile("not json", func(v string) { ch <- v })
	if v := <-ch; !strings.Contains(v, "参数无效") {
		t.Errorf("v = %s", v)
	}
	if v := meowAkileInvoke(t, map[string]string{"op": "nope"}); !strings.Contains(v, "参数无效") {
		t.Errorf("v = %s", v)
	}
	res, raw := meowAkileReportOf(t, meowAkileParams{Key: "bad", Nodes: []meowAkileTarget{{RuleID: 1}}})
	if res.Error != meowAkileTextBadKey || len(res.Results) != 0 {
		t.Errorf("raw = %s", raw)
	}
}

// 真打一次出口 IP 端点（只查 IP，不碰 Akile 接口）：MEOW_AKILE_LIVE_IP=1 go test -run TestMeowAkileExitIPLive -v .
func TestMeowAkileExitIPLive(t *testing.T) {
	if os.Getenv("MEOW_AKILE_LIVE_IP") == "" {
		t.Skip("设 MEOW_AKILE_LIVE_IP=1 才跑")
	}
	for _, ep := range meowAkileIPEndpoints {
		ip, err := meowAkileAskIP(context.Background(), meowAkileHTTPClient(nil, "tcp4", meowAkileIPTimeout), ep)
		t.Logf("%s → %q %v", ep.URL, ip, err)
	}
	ip, err := meowAkileExitIP(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	t.Logf("出口 IP %s", ip)
}
