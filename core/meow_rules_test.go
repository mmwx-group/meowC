package main

import (
	"testing"

	"github.com/metacubex/mihomo/config"
)

// 悬空引用的规则被改成 PASS / 删掉，正常规则一个字都不动。
func TestMeowSanitizeDanglingRules(t *testing.T) {
	raw := &config.RawConfig{
		Proxy:      []map[string]any{{"name": "节点A"}},
		ProxyGroup: []map[string]any{{"name": "🚀 手动选择"}},
		RuleProvider: map[string]map[string]any{
			"private": {"type": "http", "behavior": "ipcidr"},
		},
		SubRules: map[string][]string{
			"sub": {"DOMAIN,a.com,不存在的组", "DOMAIN,b.com,节点A"},
		},
		Rule: []string{
			"RULE-SET,private,🏠 私有网络,no-resolve",                      // 组不存在 → PASS，参数保留
			"RULE-SET,不存在的集合,DIRECT",                                  // provider 不存在 → 删掉
			"AND,((NETWORK,UDP),(DST-PORT,443)),REJECT",             // 正常的逻辑规则，原样
			"DOMAIN-SUFFIX,example.com,🚀 手动选择",                       // 正常
			"DOMAIN-SUFFIX,x.com,节点A",                                // 直接指向节点，正常
			"SUB-RULE,(DOMAIN,c.com),sub",                           // 子规则存在，原样
			"SUB-RULE,(DOMAIN,d.com),没有这个子规则",                        // 子规则不存在 → 删掉
			"MATCH,🐟 漏网之鱼",                                          // 组不存在 → MATCH,PASS
		},
	}
	meowSanitizeDanglingRules(raw)

	want := []string{
		"RULE-SET,private,PASS,no-resolve",
		"AND,((NETWORK,UDP),(DST-PORT,443)),REJECT",
		"DOMAIN-SUFFIX,example.com,🚀 手动选择",
		"DOMAIN-SUFFIX,x.com,节点A",
		"SUB-RULE,(DOMAIN,c.com),sub",
		"MATCH,PASS",
	}
	if len(raw.Rule) != len(want) {
		t.Fatalf("规则条数 = %d, 期望 %d：%q", len(raw.Rule), len(want), raw.Rule)
	}
	for i := range want {
		if raw.Rule[i] != want[i] {
			t.Errorf("rules[%d] = %q, 期望 %q", i, raw.Rule[i], want[i])
		}
	}
	wantSub := []string{"DOMAIN,a.com,PASS", "DOMAIN,b.com,节点A"}
	for i := range wantSub {
		if raw.SubRules["sub"][i] != wantSub[i] {
			t.Errorf("sub-rules[sub][%d] = %q, 期望 %q", i, raw.SubRules["sub"][i], wantSub[i])
		}
	}
}

// 之前 config.Parse 会整份拒收，处理过之后能解析通过。
func TestMeowSanitizeMakesConfigParseable(t *testing.T) {
	data := []byte("rules:\n  - MATCH,🏠 私有网络\n")
	if _, err := config.Parse(data); err == nil {
		t.Fatal("期望 mihomo 原样解析失败（悬空的出站引用）")
	}
	raw, err := config.UnmarshalRawConfig(data)
	if err != nil {
		t.Fatalf("UnmarshalRawConfig: %v", err)
	}
	meowSanitizeDanglingRules(raw)
	if _, err := config.ParseRawConfig(raw); err != nil {
		t.Fatalf("处理后仍然解析失败: %v", err)
	}
}
