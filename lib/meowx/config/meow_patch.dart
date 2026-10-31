import 'package:bett_box/models/meow.dart';

import '../panel/po0.dart';
import '../state/custom_rules.dart';
import '../state/overrides.dart';

/// fake-ip 缺省过滤（与 iOS 端补默认时一致）。
const defaultFakeIpFilter = [
  '*.lan',
  '*.local',
  '*.localdomain',
  'localhost.ptlogin2.qq.com',
  '+.msftconnecttest.com',
  '+.msftncsi.com',
  'time.*.com',
  'ntp.*.com',
  '+.market.xiaomi.com',
  '+.stun.*.*',
  '+.stun.*.*.*',
  'lens.l.google.com',
  '*.n.n.srv.nintendo.net',
  '+.srv.nintendo.net',
  '*.mcdn.bilivideo.cn',
];

const defaultFakeIpRange = '198.18.0.1/16';

/// 订阅声明的 enhanced-mode（未声明 → null）。
String? declaredDnsMode(Map<String, dynamic> rawConfig) {
  final dns = rawConfig['dns'];
  if (dns is! Map) return null;
  final v = dns['enhanced-mode']?.toString();
  return (v == null || v.isEmpty) ? null : v;
}

/// 给定设置与订阅声明，算出实际生效的 enhanced-mode（follow：声明 fake-ip 才 fake-ip，其它一律 redir-host）。
String effectiveDnsMode(MeowDnsMode mode, String? declared) => switch (mode) {
  MeowDnsMode.fakeIp => 'fake-ip',
  MeowDnsMode.redirHost => 'redir-host',
  MeowDnsMode.follow => declared == 'fake-ip' ? 'fake-ip' : 'redir-host',
};

/// MeowX 的 DNS 模式：只动 dns 段——强制 enable，写 enhanced-mode；fake-ip 时缺 range / filter 才补默认。
/// follow 不改任何东西（订阅怎么写就怎么用，包括未声明时由 mihomo 取默认）。
/// 在 Bettbox patchRawConfig 的 dns 覆写之后调用，就地修改 rawConfig。
void applyMeowDns(Map<String, dynamic> rawConfig, MeowDnsMode mode) {
  if (mode == MeowDnsMode.follow) return;
  final dns = switch (rawConfig['dns']) {
    Map m => m.cast<String, dynamic>(),
    _ => <String, dynamic>{},
  };
  dns['enable'] = true;
  dns['enhanced-mode'] = effectiveDnsMode(mode, null);
  if (mode == MeowDnsMode.fakeIp) {
    final range = dns['fake-ip-range']?.toString();
    if (range == null || range.isEmpty) dns['fake-ip-range'] = defaultFakeIpRange;
    final filter = dns['fake-ip-filter'];
    if (filter is! List || filter.isEmpty) dns['fake-ip-filter'] = List<String>.from(defaultFakeIpFilter);
  }
  rawConfig['dns'] = dns;
}

/// MeowX IPv6：覆盖顶层 `ipv6` 与 `dns.ipv6`（默认开）。mihomo 的 `ipv6:false` 会禁掉拨 v6 节点服务器、不解析 AAAA，
/// 导致 v6 节点连不上（iOS / Mac 的自研引擎没这限制、v6 节点一直能拨）。这是我们这层的权威值，盖过「高级 · 内核配置」里那两个开关。
/// 在 Bettbox 写回 `rawConfig['ipv6']` 与 `rawConfig['dns']` 之后调用。
void applyMeowIpv6(Map<String, dynamic> rawConfig, bool ipv6) {
  rawConfig['ipv6'] = ipv6;
  if (rawConfig['dns'] is Map) {
    (rawConfig['dns'] as Map)['ipv6'] = ipv6;
  }
}

/// MeowX 用户覆写：DNS 劫持 → hosts；绕过 / 推送直连 → 规则最前；本地代理凭据 → authentication。
/// 在 Bettbox 拼好 hosts 之后调用（hosts 部分），规则部分在 rules 写回 rawConfig 前调用。
void applyMeowHosts(Map<String, dynamic> rawConfig, MeowSettings meow) {
  if (meow.dnsHijack.isEmpty) return;
  final hosts = switch (rawConfig['hosts']) {
    Map m => m.cast<String, dynamic>(),
    _ => <String, dynamic>{},
  };
  for (final e in meow.dnsHijack.entries) {
    hosts[e.key] = e.value;
  }
  rawConfig['hosts'] = hosts;
}

/// 返回要前置到规则表最前的规则（po0 直连 → 绕过代理 → 推送直连 → 自定义规则）。
/// 自定义规则排在绕过代理 / 推送直连之后（同 iOS：绕过表与推送直连先于全部规则判断，用户开着的这两项不被自定义规则盖掉），
/// 仍在全部订阅规则之前。「阻止 QUIC」的规则排在这些之前（见 [meowRuleTable]）。
/// 以前最后还有一组主控直连（登录的主控 + 订阅域名），2026-10-29 用户要求去掉：主控按订阅规则走，同 iOS / macOS。
/// po0 直连只在「po0 加白」开关打开（或 debug 注入 [debugPo0Urls]）时生效，主机（IP 或域名）来自最近一次的上报目标
/// （主控列表 + 自己添加的）。
/// [proxyGroups] / [rules]：要交给内核的那份配置的代理组与订阅规则，自定义规则的「代理」据此推断主代理组
/// （[resolveMainProxyGroup]）。
List<String> meowPrependRules(
  MeowSettings meow, {
  bool? debugPo0,
  Object? proxyGroups,
  Object? rules,
}) => [
  if (meow.po0Enabled || (debugPo0 ?? debugPo0Urls.isNotEmpty)) ...po0DirectRules(meow.po0DirectHosts),
  ...bypassRules(meow.bypassDomains, meow.bypassCidrs),
  if (meow.pushDirect) ...pushDirectRules,
  if (meow.customRules.isNotEmpty) ...customRuleLines(meow.customRules, resolveMainProxyGroup(proxyGroups, rules)),
];

/// 写回 `rawConfig['rules']` 的整张规则表：阻止 QUIC → MeowX 前置规则（[meowPrependRules]）→ 订阅规则（Bettbox 处理过的）。
/// 阻止 QUIC 排在全部 MeowX 前置规则之前，自定义规则命中的域名也照样丢 UDP 443（同 iOS：QUIC 在收包处就丢、先于一切规则）；
/// 副作用是绕过代理 / 推送直连 / po0 直连的 UDP 443 也被丢（po0 的上报走 TCP，不受影响）。
/// [rules] 也用来推断自定义规则「代理」的主代理组（不含阻止 QUIC 的规则）。在 Bettbox 的 `patchRawConfig` 末尾调用。
List<dynamic> meowRuleTable(
  MeowSettings meow, {
  List<String> quicRules = const [],
  required List<dynamic> rules,
  Object? proxyGroups,
  bool? debugPo0,
}) => [
  ...quicRules,
  ...meowPrependRules(meow, debugPo0: debugPo0, proxyGroups: proxyGroups, rules: rules),
  ...rules,
];

void applyMeowAuthentication(Map<String, dynamic> rawConfig, MeowSettings meow) {
  final u = meow.localProxy.username.trim();
  if (u.isEmpty) return;
  rawConfig['authentication'] = ['$u:${meow.localProxy.password}'];
  // 本机免认证（mihomo 默认 skip-auth-prefixes 为空）：App 自己经 127.0.0.1:mixed-port 的请求不带凭据
  rawConfig['skip-auth-prefixes'] ??= ['127.0.0.1/32', '::1/128'];
}
