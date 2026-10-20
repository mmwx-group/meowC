// 自定义规则（直连 / 代理 / 拒绝）：规范化、主代理组推断、规则生成、按连接查找——纯函数，可单测。
// 与 iOS / macOS 同一口径：动作三种，「代理」固定走订阅的主代理组；匹配 DOMAIN / DOMAIN-SUFFIX，只有 IP 时 IP-CIDR。

import 'dart:io';

import 'package:bett_box/models/meow.dart';
import 'package:flutter/foundation.dart';

import 'overrides.dart';

const customRuleHostInvalidMessage = '域名或 IP 格式不合法（示例：example.com、https://www.example.com/path、1.2.3.4）';

/// 规范化后的输入：[value] 是小写域名或 IP；[ip] = 是 IP；[suffixHint] = 用户写了 `+.` / `.` 前缀（想要含子域名）。
typedef CustomRuleHost = ({String value, bool ip, bool suffixHint});

final _hostLabel = RegExp(r'^[a-z0-9_-]{1,63}$');

/// 把用户输入（可能是整条链接）规范成域名或 IP：去协议头、用户名、路径 / 查询、端口，小写、去尾点。
/// 域名标签只含 a-z0-9-_（同 iOS，`_dmarc.example.com` 这类合法）；IPv6 可写成 `[2001:db8::1]:443` 或裸地址，
/// 统一成内核回报的标准写法（`2001:0db8::1` → `2001:db8::1`，`::ffff:1.2.3.4` → `1.2.3.4`）；
/// `+.1.2.3.4` / `.1.2.3.4` 按单个 IP 算（同 `1.2.3.4`）。不合法（含通配符、空、标签非法、网段）返回 null。
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
  // `+.` / `.` 前缀 = 想要含子域名；剥掉之后是 IP 的按单个 IP 算（不然存成「含子域名 1.2.3.4」、生成时又被丢掉）
  final suffix = host.startsWith('+.') || host.startsWith('.');
  final bare = host.startsWith('+.') ? host.substring(2) : (host.startsWith('.') ? host.substring(1) : host);
  if (normalizeCidr(bare) != null) {
    final ip = _canonicalIp(bare);
    return ip == null ? null : (value: ip, ip: true, suffixHint: false);
  }
  // 通配符 `*` 不在标签字符集里，照样不合法
  if (bare.isEmpty || bare.length > 253 || !bare.split('.').every(_hostLabel.hasMatch)) return null;
  return (value: bare, ip: false, suffixHint: suffix);
}

/// IP 的标准写法：IPv4 原样；IPv6 按 inet_ntop 输出（与内核回报的连接目标同一写法），IPv4-mapped 转成 IPv4
/// （内核把这种目标当 IPv4 匹配，写成 IP-CIDR6 永远不命中）。
String? _canonicalIp(String ip) {
  if (!ip.contains(':')) return ip;
  final raw = InternetAddress.tryParse(ip)?.rawAddress;
  if (raw == null || raw.length != 16) return null;
  final mapped = raw.take(10).every((b) => b == 0) && raw[10] == 0xff && raw[11] == 0xff;
  return mapped ? raw.sublist(12).join('.') : InternetAddress.fromRawAddress(raw).address;
}

const _builtinTargets = {'DIRECT', 'REJECT', 'REJECT-DROP', 'PASS', 'COMPATIBLE'};

/// 订阅的主代理组（「代理」动作走它）：
/// ① 兜底规则 MATCH 指向的组（指向 DIRECT / REJECT / PASS 或指向的不是代理组时跳过）；
/// ② 第一个 select 类型的代理组；③ 名叫 GLOBAL 的组，否则第一个代理组；④ 一个组都没有 → null（「代理」规则不生成，
/// 交给订阅规则——内置的 GLOBAL 在规则模式下没人选过、默认是 DIRECT，同 iOS）。
/// [proxyGroups] 是配置里的 `proxy-groups`，[rules] 是订阅规则（字符串列表），类型不对的一律当没有。
String? resolveMainProxyGroup(Object? proxyGroups, Object? rules) {
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
  return groups.isEmpty ? null : groups.first.$1;
}

/// 实际交给内核的那份配置算出的主代理组（订阅 id, 组名），界面上「代理（组名）」优先用它。
/// 在 Bettbox 的 `patchRawConfig` 里经 [captureMainProxyGroup] 更新（同 `captureNodeKeys`）。
final appliedMainProxyGroup = ValueNotifier<(String, String?)?>(null);

/// 记下当前订阅交给内核的主代理组：[proxyGroups] / [rules] 是 Bettbox 规则覆写、停用组处理之后的那份。
void captureMainProxyGroup(String profileId, Object? proxyGroups, Object? rules) =>
    appliedMainProxyGroup.value = (profileId, resolveMainProxyGroup(proxyGroups, rules));

/// 一条自定义规则对应的 mihomo 规则行；存下的值不合法或不是标准写法（手改过配置等）返回 null、跳过。
/// 动作是「代理」而没有主代理组（[proxyTarget] 为 null）时也不生成，交给订阅规则（同 iOS）。
String? customRuleLine(MeowCustomRule rule, String? proxyTarget) {
  final target = switch (rule.action) {
    MeowRuleAction.direct => 'DIRECT',
    MeowRuleAction.reject => 'REJECT',
    MeowRuleAction.proxy => proxyTarget,
  };
  if (target == null) return null;
  final h = normalizeCustomRuleHost(rule.value);
  if (h == null || h.value != rule.value || h.ip != (rule.match == MeowRuleMatch.ip)) return null;
  if (h.ip) return h.value.contains(':') ? 'IP-CIDR6,${h.value}/128,$target,no-resolve' : 'IP-CIDR,${h.value}/32,$target,no-resolve';
  return '${rule.match == MeowRuleMatch.suffix ? 'DOMAIN-SUFFIX' : 'DOMAIN'},${h.value},$target';
}

/// 全部自定义规则的规则行（列表顺序 = 优先级）。
List<String> customRuleLines(List<MeowCustomRule> rules, String? proxyTarget) => [
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
/// （比如已有「含子域名 google.com → 代理」，再给 www.google.com 设直连）。满 [overridesLimit] 条时不再新增、原样返回
/// （同 iOS `CustomRule.upserting`）。
List<MeowCustomRule> upsertCustomRule(List<MeowCustomRule> list, MeowCustomRule rule) {
  final i = list.indexWhere((r) => r.value == rule.value && r.match == rule.match);
  if (i >= 0) return [...list]..[i] = rule;
  if (list.length >= overridesLimit) return list;
  return [rule, ...list];
}

/// 连接详情里点动作：去掉同值同匹配方式的旧条目、新的放最前——点了就生效，前面有更宽的规则（「含子域名」父域名）
/// 也压得住。满 [overridesLimit] 条时新增无效（见 [upsertCustomRule]）。
List<MeowCustomRule> promoteCustomRule(List<MeowCustomRule> list, MeowCustomRule rule) => upsertCustomRule([
  for (final r in list)
    if (r.value != rule.value || r.match != rule.match) r,
], rule);

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

/// 动作的显示文字：代理带上实际会走的组名（「代理（节点选择）」）；没有主代理组时只写「代理」。
String customRuleActionLabel(MeowRuleAction action, String? mainGroup) =>
    action == MeowRuleAction.proxy && mainGroup != null && mainGroup.isNotEmpty ? '代理（$mainGroup）' : action.label;

