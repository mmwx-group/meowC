package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/metacubex/mihomo/component/panelrt"
	"github.com/metacubex/mihomo/constant"
	"github.com/metacubex/mihomo/log"
)

// MeowX：主控实时通道（入口即时切换 + 订阅自动更新，规格 MeowX 仓库 Design/entry-realtime.md §2 / §3 / §6）。
// 通道、入口覆盖表、订阅变更的节流都在内核 component/panelrt（与 OpenWrt / 飞牛共用），这里只做 meowC 这一层：
//
//   - Dart 经 meowRealtime（op=configure）交来「要连哪些主控」：已登录的主控用会话 token，没登录、订阅应答里给了只读凭证
//     的主控用 rt。桥层把它落盘（<数据目录>/meowx-realtime.json），只在代理运行时（startListener 到 stopListener 之间）
//     接到内核上：安卓上界面被收、VPN 服务在后台跑时通道照样活着；磁贴 / 开机直接起 VPN、界面从没开过时用落盘的那份。
//   - 订阅变更：内核回调 → 记进待更新队列（落盘 <数据目录>/realtime-pending.json）+ 推一条 meowSubChanged 消息。
//     Dart 收到后取队列（op=pending）、重拉、处理完再 ack；界面不在时消息没人收，队列留着，界面回来（启动 / 回前台）再补。
//     内核把通知过的 rev 记成「已知」、不会再通知第二次，所以队列必须在这一侧留住，不能只靠那条消息。
//   - 其余：status（各通道状态）/ entries（入口覆盖表，节点详情显示）/ note（刚拉过的订阅 rev）/ clear（退出登录清入口覆盖）/
//     kick（换网；安卓由 VPN 服务的换网回调经 netreset 叫，不用 Dart）。

const meowRealtimeMethod Method = "meowRealtime"

// meowSubChangedMessage 订阅变更推给 Dart 的消息类型（data = {base, key, rev}）
const meowSubChangedMessage MessageType = "meowSubChanged"

// pendingMaxAge 队列里放了这么久还没被 Dart 处理的丢掉（7 天，与入口覆盖表的过期同长）
const pendingMaxAge = 7 * 24 * time.Hour

type meowRealtimeParams struct {
	Op       string            `json:"op"`
	Channels []panelrt.Channel `json:"channels,omitempty"`
	Subs     []panelrt.SubRev  `json:"subs,omitempty"`
	Items    []pendingSub      `json:"items,omitempty"`
	Source   string            `json:"source,omitempty"`
}

type pendingSub struct {
	Base string `json:"base"`
	Key  string `json:"key"`
	Rev  string `json:"rev"`
	At   int64  `json:"at,omitempty"` // 毫秒
}

type realtimeBridge struct {
	mu         sync.Mutex
	running    bool
	desired    []panelrt.Channel
	loadedFrom string // 已从这个路径读过落盘的配置
	pending    []pendingSub
	pendingAt  string // 已从这个路径读过落盘的队列

	// 以下可在测试里换掉
	home   func() string
	apply  func(channels []panelrt.Channel) error
	notify func(p pendingSub)
	now    func() time.Time
}

var meowRT = newRealtimeBridge()

func newRealtimeBridge() *realtimeBridge {
	return &realtimeBridge{
		home: constant.Path.HomeDir,
		apply: func(channels []panelrt.Channel) error {
			return panelrt.Configure(channels, nil)
		},
		notify: func(p pendingSub) {
			sendMessage(Message{Type: meowSubChangedMessage, Data: map[string]string{"base": p.Base, "key": p.Key, "rev": p.Rev}})
		},
		now: time.Now,
	}
}

func init() {
	panelrt.SetSubscriptionCallback(func(base, key, rev string) { meowRT.subscriptionChanged(base, key, rev) })
}

// meowRealtimeSetRunning 代理起停（hub.go 的 handleStartListener / handleStopListener 调）。
func meowRealtimeSetRunning(running bool) {
	meowRT.setRunning(running)
}

func (b *realtimeBridge) path(name string) string {
	home := b.home()
	if home == "" {
		return ""
	}
	return filepath.Join(home, name)
}

// cleanChannels 去掉地址无效、缺凭证的：一条坏的不该让别的主控也连不上（内核遇到坏的整份拒掉）。
func cleanChannels(in []panelrt.Channel) []panelrt.Channel {
	out := []panelrt.Channel{}
	for _, ch := range in {
		base, err := panelrt.NormalizeBase(ch.Base)
		token, rt := strings.TrimSpace(ch.Token), strings.TrimSpace(ch.RT)
		if err != nil || token == "" && rt == "" {
			continue
		}
		out = append(out, panelrt.Channel{Base: base, Token: token, RT: rt})
	}
	return out
}

func (b *realtimeBridge) loadDesiredLocked() {
	p := b.path("meowx-realtime.json")
	if p == "" || p == b.loadedFrom {
		return
	}
	b.loadedFrom = p
	data, err := os.ReadFile(p)
	if err != nil {
		return
	}
	var f struct {
		Channels []panelrt.Channel `json:"channels"`
	}
	if json.Unmarshal(data, &f) == nil {
		b.desired = cleanChannels(f.Channels)
	}
}

func (b *realtimeBridge) saveDesiredLocked() {
	p := b.path("meowx-realtime.json")
	if p == "" {
		return
	}
	b.loadedFrom = p
	data, _ := json.MarshalIndent(map[string]any{"channels": b.desired}, "", "  ")
	writeFileAtomic0600(p, data)
}

func writeFileAtomic0600(path string, data []byte) {
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, data, 0o600); err != nil {
		log.Warnln("[MeowX] 写 %s 失败：%s", filepath.Base(path), err)
		return
	}
	if err := os.Rename(tmp, path); err != nil {
		log.Warnln("[MeowX] 写 %s 失败：%s", filepath.Base(path), err)
	}
}

// applyLocked 运行中 = 接上想要的通道；没在运行 = 全停（入口覆盖表留着）。
func (b *realtimeBridge) applyLocked() error {
	if !b.running {
		return b.apply(nil)
	}
	return b.apply(b.desired)
}

func (b *realtimeBridge) setRunning(running bool) {
	b.mu.Lock()
	defer b.mu.Unlock()
	b.loadDesiredLocked()
	if b.running == running {
		return
	}
	b.running = running
	if running && len(b.desired) == 0 {
		return
	}
	if err := b.applyLocked(); err != nil {
		log.Warnln("[MeowX] 实时通道：%s", err)
	}
}

func (b *realtimeBridge) configure(channels []panelrt.Channel) error {
	b.mu.Lock()
	defer b.mu.Unlock()
	b.loadDesiredLocked()
	b.desired = cleanChannels(channels)
	b.saveDesiredLocked()
	return b.applyLocked()
}

// MARK: - 待更新队列

func (b *realtimeBridge) loadPendingLocked() {
	p := b.path("realtime-pending.json")
	if p == "" || p == b.pendingAt {
		return
	}
	b.pendingAt = p
	data, err := os.ReadFile(p)
	if err != nil {
		return
	}
	var f struct {
		Items []pendingSub `json:"items"`
	}
	if json.Unmarshal(data, &f) != nil {
		return
	}
	// 内存里已有的（数据目录还没定下来时收到的）排在后面、以它们为准
	merged := append([]pendingSub{}, f.Items...)
	for _, it := range b.pending {
		merged = upsertPending(merged, it)
	}
	b.pending = merged
}

func (b *realtimeBridge) savePendingLocked() {
	p := b.path("realtime-pending.json")
	if p == "" {
		return
	}
	b.pendingAt = p
	data, _ := json.MarshalIndent(map[string]any{"items": b.pending}, "", "  ")
	writeFileAtomic0600(p, data)
}

// upsertPending 同一 (主控, 键) 只留最新的一条。
func upsertPending(list []pendingSub, it pendingSub) []pendingSub {
	for i := range list {
		if list[i].Base == it.Base && list[i].Key == it.Key {
			list[i] = it
			return list
		}
	}
	return append(list, it)
}

func (b *realtimeBridge) pruneLocked() bool {
	cut := b.now().Add(-pendingMaxAge).UnixMilli()
	kept := b.pending[:0]
	for _, it := range b.pending {
		if it.At == 0 || it.At >= cut {
			kept = append(kept, it)
		}
	}
	changed := len(kept) != len(b.pending)
	b.pending = kept
	return changed
}

func (b *realtimeBridge) subscriptionChanged(base, key, rev string) {
	it := pendingSub{Base: base, Key: key, Rev: rev, At: b.now().UnixMilli()}
	b.mu.Lock()
	b.loadPendingLocked()
	b.pending = upsertPending(b.pending, it)
	b.pruneLocked()
	b.savePendingLocked()
	b.mu.Unlock()
	b.notify(it)
}

func (b *realtimeBridge) listPending() []pendingSub {
	b.mu.Lock()
	defer b.mu.Unlock()
	b.loadPendingLocked()
	if b.pruneLocked() {
		b.savePendingLocked()
	}
	out := append([]pendingSub{}, b.pending...)
	sort.SliceStable(out, func(i, j int) bool { return out[i].At < out[j].At })
	return out
}

// ack Dart 处理完了：rev 对得上才删（处理期间又来了更新的 rev 就留着）。
func (b *realtimeBridge) ack(items []pendingSub) int {
	b.mu.Lock()
	defer b.mu.Unlock()
	b.loadPendingLocked()
	removed := 0
	kept := b.pending[:0]
	for _, it := range b.pending {
		done := false
		for _, a := range items {
			if a.Base == it.Base && a.Key == it.Key && a.Rev == it.Rev {
				done = true
				break
			}
		}
		if done {
			removed++
			continue
		}
		kept = append(kept, it)
	}
	b.pending = kept
	if removed > 0 {
		b.savePendingLocked()
	}
	return removed
}

// MARK: - 动作

func handleMeowRealtime(paramsString string) string {
	var params meowRealtimeParams
	if err := json.Unmarshal([]byte(paramsString), &params); err != nil {
		return jsonString(map[string]string{"error": "参数无效"})
	}
	switch params.Op {
	case "configure":
		res := map[string]any{}
		if err := meowRT.configure(params.Channels); err != nil {
			res["error"] = err.Error()
		}
		for _, s := range params.Subs {
			panelrt.NoteSubscriptionRev(s.Base, s.Key, s.Rev)
		}
		return jsonString(res)
	case "status":
		meowRT.mu.Lock()
		running := meowRT.running
		meowRT.mu.Unlock()
		return jsonString(map[string]any{"running": running, "status": panelrt.Status()})
	case "entries":
		return jsonString(map[string]any{"entries": panelrt.Entries()})
	case "note":
		for _, s := range params.Subs {
			panelrt.NoteSubscriptionRev(s.Base, s.Key, s.Rev)
		}
		return jsonString(map[string]any{})
	case "clear":
		// 空的 source 在内核里 = 全部清掉；这里只按主控清，别误清
		if strings.TrimSpace(params.Source) == "" {
			return jsonString(map[string]string{"error": "缺主控地址"})
		}
		return jsonString(map[string]any{"cleared": panelrt.ClearEntries(params.Source)})
	case "kick":
		panelrt.Kick()
		return jsonString(map[string]any{})
	case "pending":
		return jsonString(map[string]any{"items": meowRT.listPending()})
	case "ack":
		return jsonString(map[string]any{"removed": meowRT.ack(params.Items)})
	}
	return jsonString(map[string]string{"error": "未知操作 " + params.Op})
}

func jsonString(v any) string {
	data, err := json.Marshal(v)
	if err != nil {
		return `{"error":"编码失败"}`
	}
	return string(data)
}
