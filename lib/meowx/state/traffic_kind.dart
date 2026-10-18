import 'package:bett_box/models/models.dart';

/// 动态页的类型筛选（对应 iOS 的 ActivityKindFilter）：全部 / 推送 / DNS / 直连 / 代理，连接与日志共用一个选择。
/// iOS 的「APNs」在安卓 / Windows 上换成「推送」：Google 推送（GMS / FCM）。
enum ActivityKind {
  all('全部'),
  push('推送'),
  dns('DNS'),
  direct('直连'),
  proxy('代理');

  const ActivityKind(this.label);
  final String label;
}

/// Google 推送（GMS / FCM）：FCM 长连接 `mtalk.google.com`（含 `alt1-mtalk.google.com` 这类）、
/// FCM / 旧 GCM 的接口域名，以及 FCM 专用的 TCP 5228–5230。
const pushDomainSuffixes = [
  'mtalk.google.com',
  'fcm.googleapis.com',
  'fcmtoken.googleapis.com',
  'fcmregistrations.googleapis.com',
  'android.googleapis.com',
  'gcm.googleapis.com',
  'android.apis.google.com',
];
const pushPorts = {5228, 5229, 5230};

/// 常见 DoH 服务（443 端口上的 DNS），同 iOS 的 DNSTarget。
const dohHosts = [
  'dns.google', 'dns.google.com', 'cloudflare-dns.com', 'one.one.one.one', 'dns.alidns.com', 'doh.pub',
  'dns.pub', 'doh.360.cn', 'dns.quad9.net', 'doh.opendns.com', 'dns.adguard-dns.com',
];
const dohSuffixes = ['.cloudflare-dns.com', '.dns.nextdns.io', '.dns.adguard-dns.com'];

/// 后缀匹配：本身或子域名；`alt1-mtalk.google.com` 这种前缀带编号的也算 mtalk。
bool _domainMatches(String host, String suffix) =>
    host == suffix || host.endsWith('.$suffix') || (suffix == 'mtalk.google.com' && RegExp(r'^alt\d+-mtalk\.google\.com$').hasMatch(host));

bool isPushTarget({required String host, required int port, required bool tcp}) {
  final h = host.toLowerCase();
  if (h.isNotEmpty && pushDomainSuffixes.any((s) => _domainMatches(h, s))) return true;
  return tcp && pushPorts.contains(port);
}

bool isDnsTarget({required String host, required int port}) {
  if (port == 53 || port == 853) return true;
  final h = host.toLowerCase();
  return port == 443 && (dohHosts.contains(h) || dohSuffixes.any(h.endsWith));
}

/// 一条连接属于哪些类：用途（推送 / DNS，可能都不是）+ 去向（直连 / 代理，二选一；拒绝的两样都不算）。
/// 去向看最终出站（mihomo 的 chains 第一个是叶子节点）。
Set<ActivityKind> connectionKinds(TrackerInfo c) {
  final m = c.metadata;
  final port = int.tryParse(m.destinationPort) ?? 0;
  final tcp = m.network.toLowerCase() == 'tcp';
  final leaf = c.chains.firstOrNull ?? '';
  return {
    if (isPushTarget(host: m.host, port: port, tcp: tcp)) ActivityKind.push,
    if (isDnsTarget(host: m.host, port: port)) ActivityKind.dns,
    if (leaf == 'DIRECT') ActivityKind.direct,
    if (leaf.isNotEmpty && leaf != 'DIRECT' && !leaf.startsWith('REJECT')) ActivityKind.proxy,
  };
}

final _logTarget = RegExp(r'-->\s*(\S+?):(\d+)\b');
final _logUsing = RegExp(r'\busing\s+(\S+)');

/// 一行内核日志属于哪些类。mihomo 的连接日志形如
/// `[TCP] 10.0.0.2:51234 --> example.com:443 match DomainSuffix(example.com) using 节点选择[香港 01]`：
/// 目标地址认推送 / DNS，`using` 后面认直连 / 代理；DNS 模块自己的日志（`[DNS] …`）也算 DNS 类。
Set<ActivityKind> logKinds(String payload) {
  final kinds = <ActivityKind>{};
  final target = _logTarget.firstMatch(payload);
  if (target != null) {
    var host = target.group(1)!;
    if (host.startsWith('[') && host.endsWith(']')) host = host.substring(1, host.length - 1);
    final port = int.tryParse(target.group(2)!) ?? 0;
    if (isPushTarget(host: host, port: port, tcp: payload.contains('[TCP]'))) kinds.add(ActivityKind.push);
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
