import 'package:bett_box/models/meow.dart';

import '../panel/po0.dart';
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

/// 返回要前置到规则表最前的规则（po0 直连 → 绕过代理 → 推送直连）。
/// po0 直连只在「po0 加白」开关打开（或 debug 注入 [debugPo0Urls]）时生效，IP 来自最近一次拿到的服务器列表。
List<String> meowPrependRules(MeowSettings meow, {bool? debugPo0}) => [
  if (meow.po0Enabled || (debugPo0 ?? debugPo0Urls.isNotEmpty)) ...po0DirectRules(meow.po0DirectIps),
  ...bypassRules(meow.bypassDomains, meow.bypassCidrs),
  if (meow.pushDirect) ...pushDirectRules,
];

void applyMeowAuthentication(Map<String, dynamic> rawConfig, MeowSettings meow) {
  final u = meow.localProxy.username.trim();
  if (u.isEmpty) return;
  rawConfig['authentication'] = ['$u:${meow.localProxy.password}'];
  // 本机免认证（mihomo 默认 skip-auth-prefixes 为空）：App 自己经 127.0.0.1:mixed-port 的请求不带凭据
  rawConfig['skip-auth-prefixes'] ??= ['127.0.0.1/32', '::1/128'];
}
