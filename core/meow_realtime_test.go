package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/metacubex/mihomo/component/panelrt"
)

type fakeRT struct {
	applied  [][]panelrt.Channel
	notified []pendingSub
}

func newTestBridge(t *testing.T, home string) (*realtimeBridge, *fakeRT) {
	t.Helper()
	f := &fakeRT{}
	b := newRealtimeBridge()
	b.home = func() string { return home }
	b.apply = func(ch []panelrt.Channel) error {
		f.applied = append(f.applied, append([]panelrt.Channel(nil), ch...))
		return nil
	}
	b.notify = func(p pendingSub) { f.notified = append(f.notified, p) }
	return b, f
}

func TestRealtimeBridgeAppliesOnlyWhileRunning(t *testing.T) {
	home := t.TempDir()
	b, f := newTestBridge(t, home)

	// 没在运行：配置落盘，内核那边保持全停
	if err := b.configure([]panelrt.Channel{
		{Base: "Panel.Example.com/", Token: "tok"},
		{Base: "", Token: "bad"},                    // 地址无效：丢掉
		{Base: "https://other.example.com", RT: ""}, // 缺凭证：丢掉
		{Base: "sub.example.net", RT: "rt1"},
	}); err != nil {
		t.Fatal(err)
	}
	if len(f.applied) != 1 || f.applied[0] != nil {
		t.Fatalf("not running should apply nil, got %#v", f.applied)
	}

	b.setRunning(true)
	got := f.applied[len(f.applied)-1]
	want := []panelrt.Channel{{Base: "https://panel.example.com", Token: "tok"}, {Base: "https://sub.example.net", RT: "rt1"}}
	if len(got) != 2 || got[0] != want[0] || got[1] != want[1] {
		t.Fatalf("running should apply desired, got %#v", got)
	}

	b.setRunning(false)
	if f.applied[len(f.applied)-1] != nil {
		t.Fatalf("stop should apply nil")
	}

	// 落盘文件只给本用户读写
	st, err := os.Stat(filepath.Join(home, "meowx-realtime.json"))
	if err != nil {
		t.Fatal(err)
	}
	if st.Mode().Perm() != 0o600 {
		t.Fatalf("perm = %v", st.Mode().Perm())
	}
}

func TestRealtimeBridgeUsesPersistedConfigWithoutDart(t *testing.T) {
	home := t.TempDir()
	b1, _ := newTestBridge(t, home)
	if err := b1.configure([]panelrt.Channel{{Base: "https://panel.example.com", Token: "tok"}}); err != nil {
		t.Fatal(err)
	}
	// 新进程（磁贴 / 开机直接起 VPN，界面从没开过）：一 startListener 就用落盘的那份
	b2, f2 := newTestBridge(t, home)
	b2.setRunning(true)
	if len(f2.applied) != 1 || len(f2.applied[0]) != 1 || f2.applied[0][0].Token != "tok" {
		t.Fatalf("persisted config not applied: %#v", f2.applied)
	}
}

func TestRealtimeBridgePendingQueue(t *testing.T) {
	home := t.TempDir()
	b, f := newTestBridge(t, home)
	now := time.UnixMilli(1_800_000_000_000)
	b.now = func() time.Time { return now }

	b.subscriptionChanged("https://panel.example.com", "pkg:12", "aaa")
	now = now.Add(time.Second)
	b.subscriptionChanged("https://panel.example.com", "", "")
	now = now.Add(time.Second)
	b.subscriptionChanged("https://panel.example.com", "pkg:12", "bbb") // 同一份订阅：只留最新的 rev
	if len(f.notified) != 3 {
		t.Fatalf("notified %d", len(f.notified))
	}
	items := b.listPending()
	if len(items) != 2 || items[0].Key != "" || items[1].Rev != "bbb" {
		t.Fatalf("pending = %#v", items)
	}

	// 界面不在时消息没人收：换个进程照样取得到
	b2, _ := newTestBridge(t, home)
	b2.now = b.now
	if got := b2.listPending(); len(got) != 2 {
		t.Fatalf("persisted pending = %#v", got)
	}

	// ack 时 rev 对不上（处理期间来了更新的）不删
	if n := b2.ack([]pendingSub{{Base: "https://panel.example.com", Key: "pkg:12", Rev: "aaa"}}); n != 0 {
		t.Fatalf("stale ack removed %d", n)
	}
	if n := b2.ack([]pendingSub{{Base: "https://panel.example.com", Key: "pkg:12", Rev: "bbb"}, {Base: "https://panel.example.com"}}); n != 2 {
		t.Fatalf("ack removed %d", n)
	}
	if got := b2.listPending(); len(got) != 0 {
		t.Fatalf("left %#v", got)
	}

	// 放了 7 天以上没人处理的丢掉
	b2.subscriptionChanged("https://panel.example.com", "file:a.yaml", "x")
	now = now.Add(8 * 24 * time.Hour)
	if got := b2.listPending(); len(got) != 0 {
		t.Fatalf("expired item kept: %#v", got)
	}
}

func TestHandleMeowRealtimeRejectsClearAll(t *testing.T) {
	var res map[string]any
	if err := json.Unmarshal([]byte(handleMeowRealtime(`{"op":"clear","source":" "}`)), &res); err != nil {
		t.Fatal(err)
	}
	if res["error"] == nil {
		t.Fatalf("clear without source must not clear everything: %v", res)
	}
	if err := json.Unmarshal([]byte(handleMeowRealtime(`{"op":"nope"}`)), &res); err != nil || res["error"] == nil {
		t.Fatalf("unknown op: %v %v", res, err)
	}
}
