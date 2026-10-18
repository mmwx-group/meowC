import 'dart:io';
import 'dart:typed_data';

import 'package:bett_box/models/models.dart';

/// 动态页的类型筛选（同 iOS 的 ActivityKindFilter）：全部 / APNs / DNS / 直连 / 代理，连接与日志共用一个选择。
enum ActivityKind {
  all('全部'),
  apns('APNs'),
  dns('DNS'),
  direct('直连'),
  proxy('代理');

  const ActivityKind(this.label);
  final String label;
}

/// Apple 推送服务（APNs）：`*.push.apple.com` + 推送服务器 IP 段（DNS 被污染时 iOS 直接按 IP 连）+ TCP 5223。
/// 与 iOS / macOS 引擎的 APNsTarget 同一份。
const apnsDomainSuffixes = ['push.apple.com', 'push-apple.com.akadns.net'];
const apnsCidrs = [
  '17.249.0.0/16', '17.252.0.0/16', '17.57.144.0/22', '17.188.128.0/18', '17.188.20.0/23',
  '2620:149:a44::/48', '2403:300:a42::/48', '2403:300:a51::/48', '2a01:b740:a42::/48',
];

/// 常见 DoH 服务（443 端口上的 DNS），同 iOS 的 DNSTarget。
const dohHosts = [
  'dns.google', 'dns.google.com', 'cloudflare-dns.com', 'one.one.one.one', 'dns.alidns.com', 'doh.pub',
  'dns.pub', 'doh.360.cn', 'dns.quad9.net', 'doh.opendns.com', 'dns.adguard-dns.com',
];
const dohSuffixes = ['.cloudflare-dns.com', '.dns.nextdns.io', '.dns.adguard-dns.com'];

bool _domainMatches(String host, String suffix) => host == suffix || host.endsWith('.$suffix');

bool isApnsTarget({required String host, required String ip, required int port, required bool tcp}) {
  final h = host.toLowerCase();
  if (h.isNotEmpty && apnsDomainSuffixes.any((s) => _domainMatches(h, s))) return true;
  if (tcp && port == 5223) return true;
  return ip.isNotEmpty && apnsCidrs.any((c) => cidrContains(c, ip));
}

bool isDnsTarget({required String host, required int port}) {
  if (port == 53 || port == 853) return true;
  final h = host.toLowerCase();
  return port == 443 && (dohHosts.contains(h) || dohSuffixes.any(h.endsWith));
}

/// [cidr] 是否包含 [ip]（v4 / v6 都认；格式不对返回 false）。
bool cidrContains(String cidr, String ip) {
  final slash = cidr.indexOf('/');
  if (slash < 0) return false;
  final net = InternetAddress.tryParse(cidr.substring(0, slash));
  final addr = InternetAddress.tryParse(ip);
  final bits = int.tryParse(cidr.substring(slash + 1));
  if (net == null || addr == null || bits == null || net.type != addr.type) return false;
  final Uint8List a = net.rawAddress, b = addr.rawAddress;
  var left = bits;
  for (var i = 0; i < a.length && left > 0; i++) {
    final take = left >= 8 ? 8 : left;
    final mask = (0xFF << (8 - take)) & 0xFF;
    if ((a[i] & mask) != (b[i] & mask)) return false;
    left -= take;
  }
  return true;
}

/// 一条连接属于哪些类：用途（APNs / DNS，可能都不是）+ 去向（直连 / 代理，二选一；拒绝的两样都不算）。
/// 去向看最终出站（mihomo 的 chains 第一个是叶子节点）。
Set<ActivityKind> connectionKinds(TrackerInfo c) {
  final m = c.metadata;
  final port = int.tryParse(m.destinationPort) ?? 0;
  final tcp = m.network.toLowerCase() == 'tcp';
  final leaf = c.chains.firstOrNull ?? '';
  return {
    if (isApnsTarget(host: m.host, ip: m.destinationIP, port: port, tcp: tcp)) ActivityKind.apns,
    if (isDnsTarget(host: m.host, port: port)) ActivityKind.dns,
    if (leaf == 'DIRECT') ActivityKind.direct,
    if (leaf.isNotEmpty && leaf != 'DIRECT' && !leaf.startsWith('REJECT')) ActivityKind.proxy,
  };
}

final _logTarget = RegExp(r'-->\s*(\S+?):(\d+)\b');
final _logUsing = RegExp(r'\busing\s+(\S+)');

/// 一行内核日志属于哪些类。mihomo 的连接日志形如
/// `[TCP] 10.0.0.2:51234 --> example.com:443 match DomainSuffix(example.com) using 节点选择[香港 01]`：
/// 目标地址认 APNs / DNS，`using` 后面认直连 / 代理；DNS 模块自己的日志（`[DNS] …`）也算 DNS 类。
Set<ActivityKind> logKinds(String payload) {
  final kinds = <ActivityKind>{};
  final target = _logTarget.firstMatch(payload);
  if (target != null) {
    var host = target.group(1)!;
    if (host.startsWith('[') && host.endsWith(']')) host = host.substring(1, host.length - 1);
    final port = int.tryParse(target.group(2)!) ?? 0;
    final isIp = InternetAddress.tryParse(host) != null;
    if (isApnsTarget(host: isIp ? '' : host, ip: isIp ? host : '', port: port, tcp: payload.contains('[TCP]'))) {
      kinds.add(ActivityKind.apns);
    }
    if (isDnsTarget(host: host, port: port)) kinds.add(ActivityKind.dns);
  }
  if (payload.contains('[DNS]')) kinds.add(ActivityKind.dns);
  final using = _logUsing.firstMatch(payload)?.group(1);
  if (using != null) {
    // 「组[叶子]」取方括号里的叶子
    final leaf = using.contains('[') && using.endsWith(']') ? using.substring(using.indexOf('[') + 1, using.length - 1) : using;
    if (leaf == 'DIRECT') {
      kinds.add(ActivityKind.direct);
    } else if (!leaf.startsWith('REJECT')) {
      kinds.add(ActivityKind.proxy);
    }
  }
  return kinds;
}

/// 连接行里规则的写法（同 iOS / 配置文件）：`GEOSITE,apple`、`DOMAIN-SUFFIX,example.com`、`MATCH`。
String ruleDisplay(String rule, String payload) {
  final name = _ruleNames[rule] ?? rule.toUpperCase();
  return payload.isEmpty ? name : '$name,$payload';
}

const _ruleNames = {
  'Domain': 'DOMAIN',
  'DomainSuffix': 'DOMAIN-SUFFIX',
  'DomainKeyword': 'DOMAIN-KEYWORD',
  'DomainRegex': 'DOMAIN-REGEX',
  'DomainWildcard': 'DOMAIN-WILDCARD',
  'GeoSite': 'GEOSITE',
  'GeoIP': 'GEOIP',
  'SrcGeoIP': 'SRC-GEOIP',
  'IPASN': 'IP-ASN',
  'SrcIPASN': 'SRC-IP-ASN',
  'IPCIDR': 'IP-CIDR',
  'SrcIPCIDR': 'SRC-IP-CIDR',
  'IPSuffix': 'IP-SUFFIX',
  'SrcIPSuffix': 'SRC-IP-SUFFIX',
  'SrcPort': 'SRC-PORT',
  'DstPort': 'DST-PORT',
  'InPort': 'IN-PORT',
  'InUser': 'IN-USER',
  'InName': 'IN-NAME',
  'InType': 'IN-TYPE',
  'Process': 'PROCESS-NAME',
  'ProcessPath': 'PROCESS-PATH',
  'ProcessNameRegex': 'PROCESS-NAME-REGEX',
  'ProcessPathRegex': 'PROCESS-PATH-REGEX',
  'RuleSet': 'RULE-SET',
  'Network': 'NETWORK',
  'DSCP': 'DSCP',
  'Uid': 'UID',
  'SubRules': 'SUB-RULE',
  'Match': 'MATCH',
};
