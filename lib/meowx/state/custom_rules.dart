// 自定义规则（直连 / 代理 / 拒绝）：规范化、主代理组推断、规则生成、按连接查找——纯函数，可单测。
// 与 iOS / macOS 同一口径：动作三种，「代理」固定走订阅的主代理组；匹配 DOMAIN / DOMAIN-SUFFIX，只有 IP 时 IP-CIDR。

import 'package:bett_box/models/meow.dart';

import 'overrides.dart';

const customRuleHostInvalidMessage = '域名或 IP 格式不合法（示例：example.com、https://www.example.com/path、1.2.3.4）';

/// 规范化后的输入：[value] 是小写域名或 IP；[ip] = 是 IP；[suffixHint] = 用户写了 `+.` / `.` 前缀（想要含子域名）。
typedef CustomRuleHost = ({String value, bool ip, bool suffixHint});

/// 把用户输入（可能是整条链接）规范成域名或 IP：去协议头、用户名、路径 / 查询、端口，小写、去尾点。
/// IPv6 可写成 `[2001:db8::1]:443` 或裸地址。不合法（含通配符、空、标签非法、网段）返回 null。
CustomRuleHost? normalizeCustomRuleHost(String input) {
  var s = input.trim();
  // 网段（10.0.0.0/8）不是「IP + 路径」：自定义规则只认单个 IP，别悄悄截成网络地址
  if (s.contains('/') && normalizeCidr(s) != null) return null;
  s = s.replaceFirst(RegExp(r'^[a-zA-Z][a-zA-Z0-9+.-]*://'), '');
  final cut = s.indexOf(RegExp(r'[/?#]'));
  if (cut >= 0) s = s.substring(0, cut);
  final at = s.lastIndexOf('@');
  if (at >= 0) s = s.substring(at + 1);
  String host;
  if (s.startsWith('[')) {
    final end = s.indexOf(']');
    if (end < 0) return null;
    host = s.substring(1, end);
  } else if (':'.allMatches(s).length == 1) {
    host = s.substring(0, s.indexOf(':'));   // host:port
  } else {
    host = s;   // 不带端口，或裸 IPv6
  }
  host = host.trim().toLowerCase();
  while (host.endsWith('.')) {
    host = host.substring(0, host.length - 1);
  }
  if (host.isEmpty || host.contains('%')) return null;
  if (!host.contains('/')) {
    final ip = normalizeCidr(host);
    if (ip != null) return (value: ip, ip: true, suffixHint: false);
  }
  final d = normalizeDomain(host);
  if (d == null || d.startsWith('*.') || d.contains('*')) return null;
  final suffix = d.startsWith('+.');
  return (value: suffix ? d.substring(2) : d, ip: false, suffixHint: suffix);
}

const _builtinTargets = {'DIRECT', 'REJECT', 'REJECT-DROP', 'PASS', 'COMPATIBLE'};

/// 订阅的主代理组（「代理」动作走它）：
/// ① 兜底规则 MATCH 指向的组（指向 DIRECT / REJECT / PASS 或指向的不是代理组时跳过）；
/// ② 第一个 select 类型的代理组；③ 名叫 GLOBAL 的组，否则第一个代理组；④ 一个组都没有 → 内置的 GLOBAL。
/// [proxyGroups] 是配置里的 `proxy-groups`，[rules] 是订阅规则（字符串列表），类型不对的一律当没有。
String resolveMainProxyGroup(Object? proxyGroups, Object? rules) {
  final groups = <(String, String)>[
    if (proxyGroups is List)
      for (final g in proxyGroups)
        if (g is Map && g['name'] is String && (g['name'] as String).isNotEmpty) (g['name'] as String, '${g['type'] ?? ''}'.toLowerCase()),
  ];
  final names = {for (final g in groups) g.$1};
  if (rules is List) {
    for (final r in rules) {
      if (r is! String) continue;
      final parts = r.split(',').map((p) => p.trim()).toList();
      final kind = parts.first.toUpperCase();
      if (kind != 'MATCH' && kind != 'FINAL') continue;
      final target = parts.length >= 2 ? parts[1] : '';
      if (!_builtinTargets.contains(target.toUpperCase()) && (names.contains(target) || target == 'GLOBAL')) return target;
      break;   // 只看第一条兜底（后面的永远匹配不到）
    }
  }
  for (final g in groups) {
    if (g.$2 == 'select') return g.$1;
  }
  if (names.contains('GLOBAL')) return 'GLOBAL';
  return groups.isEmpty ? 'GLOBAL' : groups.first.$1;
}

/// 一条自定义规则对应的 mihomo 规则行；存下的值不合法（手改过配置等）返回 null、跳过。
String? customRuleLine(MeowCustomRule rule, String proxyTarget) {
  final target = switch (rule.action) {
    MeowRuleAction.direct => 'DIRECT',
    MeowRuleAction.reject => 'REJECT',
    MeowRuleAction.proxy => proxyTarget,
  };
  if (rule.match == MeowRuleMatch.ip) {
    final ip = rule.value.contains('/') ? null : normalizeCidr(rule.value);
    if (ip == null) return null;
    return ip.contains(':') ? 'IP-CIDR6,$ip/128,$target,no-resolve' : 'IP-CIDR,$ip/32,$target,no-resolve';
  }
  final h = normalizeCustomRuleHost(rule.value);
  if (h == null || h.ip || h.value != rule.value) return null;
  return '${rule.match == MeowRuleMatch.suffix ? 'DOMAIN-SUFFIX' : 'DOMAIN'},${h.value},$target';
}

/// 全部自定义规则的规则行（列表顺序 = 优先级）。
List<String> customRuleLines(List<MeowCustomRule> rules, String proxyTarget) => [
  for (final r in rules) ?customRuleLine(r, proxyTarget),
];

/// 这条连接命中的第一条自定义规则（按列表顺序；没有返回 null）。[host] 为空时只按 [ip] 找。
MeowCustomRule? customRuleFor(List<MeowCustomRule> rules, {required String host, String ip = ''}) {
  final h = host.trim().toLowerCase();
  final a = ip.trim().toLowerCase();
  for (final r in rules) {
    final hit = switch (r.match) {
      MeowRuleMatch.domain => h.isNotEmpty && h == r.value,
      MeowRuleMatch.suffix => h.isNotEmpty && (h == r.value || h.endsWith('.${r.value}')),
      MeowRuleMatch.ip => a.isNotEmpty && a == r.value,
    };
    if (hit) return r;
  }
  return null;
}

/// 加一条（或改同一个值 + 匹配方式那条的动作）：已有的原位改；新的放最前——后加的更具体、该先匹配
/// （比如已有「含子域名 google.com → 代理」，再给 www.google.com 设直连）。
List<MeowCustomRule> upsertCustomRule(List<MeowCustomRule> list, MeowCustomRule rule) {
  final i = list.indexWhere((r) => r.value == rule.value && r.match == rule.match);
  if (i >= 0) return [...list]..[i] = rule;
  return [rule, ...list];
}

/// 编辑第 [index] 条：原位替换；改完与别的条目重复（同值同匹配方式）时去掉那条。
List<MeowCustomRule> replaceCustomRule(List<MeowCustomRule> list, int index, MeowCustomRule rule) {
  final out = <MeowCustomRule>[];
  for (final (i, r) in list.indexed) {
    if (i == index) {
      out.add(rule);
    } else if (r.value != rule.value || r.match != rule.match) {
      out.add(r);
    }
  }
  return out;
}

/// 动作的显示文字：代理带上实际会走的组名（「代理（节点选择）」）。
String customRuleActionLabel(MeowRuleAction action, String mainGroup) =>
    action == MeowRuleAction.proxy ? '代理（$mainGroup）' : action.label;

