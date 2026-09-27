package main

import (
	"strings"

	"github.com/metacubex/mihomo/config"
	"github.com/metacubex/mihomo/log"
	R "github.com/metacubex/mihomo/rules"
	RC "github.com/metacubex/mihomo/rules/common"
)

// MeowX：让「引用了配置里不存在的代理组 / rule-provider」的规则不至于废掉整份配置。
//
// mihomo 的 parseRules 对这两种悬空引用都是硬失败（`proxy [X] not found` /
// `rule set [X] not found`）。第三方订阅与手写模板里这很常见——比如规则写了
// `RULE-SET,private,🏠 私有网络,no-resolve`，而 proxy-groups 里并没有这个组——
// 结果整份订阅连导入都过不去。这里在 UnmarshalRawConfig 之后、ParseRawConfig 之前
// 把这类规则处理掉：
//   - 目标不存在 → 改成 PASS（mihomo 内置出站，语义是「跳过这条、继续往下匹配」）；
//   - 引用的 rule-provider 不存在 → 这条规则无从执行，整条删掉。
// 其余错误照旧原样报给用户。

// mihomo 在 parseProxies 里预置的目标 + 没有显式定义时自动合成的 GLOBAL。
var meowBuiltinRuleTargets = []string{
	"DIRECT", "REJECT", "REJECT-DROP", "COMPATIBLE", "PASS", "PASS-RULE", "GLOBAL",
}

// meowSanitizeDanglingRules 原地改写 rawCfg 的 rules 与 sub-rules。
func meowSanitizeDanglingRules(rawCfg *config.RawConfig) {
	if rawCfg == nil {
		return
	}
	targets := make(map[string]struct{}, len(rawCfg.Proxy)+len(rawCfg.ProxyGroup)+len(meowBuiltinRuleTargets))
	for _, name := range meowBuiltinRuleTargets {
		targets[name] = struct{}{}
	}
	for _, list := range [][]map[string]any{rawCfg.Proxy, rawCfg.ProxyGroup} {
		for _, mapping := range list {
			if name, ok := mapping["name"].(string); ok {
				targets[name] = struct{}{}
			}
		}
	}
	subRules := make(map[string]struct{}, len(rawCfg.SubRules))
	for name := range rawCfg.SubRules {
		subRules[name] = struct{}{}
	}

	rawCfg.Rule = meowSanitizeRuleList(rawCfg.Rule, "rules", targets, subRules, rawCfg.RuleProvider)
	for name, list := range rawCfg.SubRules {
		rawCfg.SubRules[name] = meowSanitizeRuleList(list, "sub-rules["+name+"]", targets, subRules, rawCfg.RuleProvider)
	}
}

func meowSanitizeRuleList(
	rules []string,
	where string,
	targets map[string]struct{},
	subRules map[string]struct{},
	providers map[string]map[string]any,
) []string {
	out := make([]string, 0, len(rules))
	for _, line := range rules {
		tp, payload, target, params := RC.ParseRulePayload(line, true)
		if target == "" {
			out = append(out, line) // 格式本身有问题，交给 mihomo 原样报错
			continue
		}
		known := subRules
		if tp != "SUB-RULE" {
			known = targets
		}
		if _, ok := known[target]; !ok {
			if tp == "SUB-RULE" {
				// SUB-RULE 的目标是子规则名，改 PASS 只会变成另一种解析错误，只能删。
				log.Warnln("[Config] %s: 规则 %q 引用了不存在的子规则 %q，已删除", where, line, target)
				continue
			}
			log.Warnln("[Config] %s: 规则 %q 引用了不存在的出站 %q，已改为 PASS（跳过这条规则）", where, line, target)
			line = meowRebuildRule(tp, payload, "PASS", params)
			target = "PASS"
		}
		// 只有真的提到 RULE-SET 才去构造规则对象：ParseRule 对 GEOSITE/GEOIP 是会即时加载
		// geo 数据的，白跑一遍既慢又占内存（ParseRawConfig 随后还会再跑一遍）。
		if strings.Contains(strings.ToUpper(line), "RULE-SET,") {
			if missing := meowMissingProviders(tp, payload, target, params, providers); missing != "" {
				log.Warnln("[Config] %s: 规则 %q 引用了不存在的 rule-provider %q，已删除", where, line, missing)
				continue
			}
		}
		out = append(out, line)
	}
	return out
}

// meowMissingProviders 返回规则引用的第一个不存在的 rule-provider（都存在则返回空串）。
// 用 mihomo 自己的 ParseRule + ProviderNames，逻辑规则里嵌套的 RULE-SET 也能一并查到。
func meowMissingProviders(
	tp, payload, target string,
	params []string,
	providers map[string]map[string]any,
) string {
	parsed, err := R.ParseRule(tp, payload, target, params, nil)
	if err != nil || parsed == nil {
		return "" // 解析不了就别猜，让 mihomo 去报真正的错
	}
	for _, name := range parsed.ProviderNames() {
		if _, ok := providers[name]; !ok {
			return name
		}
	}
	return ""
}

// meowRebuildRule 按 mihomo 的字段顺序（类型, payload, 目标, 参数…）拼回规则行。
func meowRebuildRule(tp, payload, target string, params []string) string {
	parts := make([]string, 0, 3+len(params))
	parts = append(parts, tp)
	if payload != "" {
		parts = append(parts, payload)
	}
	parts = append(parts, target)
	parts = append(parts, params...)
	return strings.Join(parts, ",")
}
