import 'dart:convert';
import 'dart:io';

import 'package:bett_box/models/meow.dart';
import 'package:flutter/foundation.dart';

/// 用户在主控里登记的 po0 服务器（独立的防火墙白名单服务）：客户端把本机出口 IP POST 到 [url] 加白。
/// 客户端里自己添加的条目也经 [po0CustomTarget] 转成它，一起上报。
class Po0Server {
  const Po0Server({required this.serverId, required this.name, required this.ip, required this.token, required this.url, this.slot});

  final int serverId;
  final String name;
  final String ip;
  final String token;

  /// 固定槽位，主控没设时为 null。
  final int? slot;

  /// 主控已拼好的完整上报地址（IPv6 已加方括号、有槽位时带 `?slot=N`），直接 POST。
  final String url;

  /// 解析 `GET /user/po0-servers` 的应答：`{"success":true,"servers":[...]}`；没有服务器 / 形状不对 → 空列表。
  static List<Po0Server> parse(dynamic json) {
    if (json is! Map || json['success'] != true || json['servers'] is! List) return const [];
    final out = <Po0Server>[];
    for (final s in json['servers'] as List) {
      if (s is! Map) continue;
      final url = s['url']?.toString() ?? '';
      if (url.isEmpty) continue;
      out.add(
        Po0Server(
          serverId: _int(s['server_id']) ?? 0,
          name: s['name']?.toString() ?? '',
          ip: s['ip']?.toString() ?? '',
          token: s['token']?.toString() ?? '',
          slot: _int(s['slot']),
          url: url,
        ),
      );
    }
    return out;
  }

  static int? _int(dynamic v) => switch (v) {
    int x => x,
    num x => x.toInt(),
    String x => int.tryParse(x),
    _ => null,
  };
}

/// 仅 debug 生效的联调注入：`--dart-define=MEOWX_PO0_URLS=url1,url2,...` 时不问主控、直接用这些上报地址，
/// 并视为开关已打开、不需要登录；refresh / 定时 / 网络变化 / 直连规则逻辑照常。release 包里恒为空。
final List<String> debugPo0Urls = kDebugMode
    ? const String.fromEnvironment('MEOWX_PO0_URLS').split(',').map((e) => e.trim()).where((e) => e.isNotEmpty).toList()
    : const [];

// ---- 自定义 po0 服务器（地址 + token，三端同一套规则：iOS / macOS / meowC） ----

const po0AddressEmptyMessage = '请填写加白服务器地址';
const po0AddressInvalidMessage = '地址格式不合法（示例：1.2.3.4、1.2.3.4:8443、[2001:db8::1]:8443、fw.example.com）';
const po0AddressPathMessage = '只填主机与端口，不要带路径、查询串或用户名';
const po0AddressPortMessage = '端口范围 1–65535';
const po0AddressV6PortMessage = 'IPv6 带端口时要写成 [地址]:端口';
const po0TokenEmptyMessage = '请填写 token';
const po0TokenInvalidMessage = 'token 格式不合法：应为 pgnfw_ 开头，可带 @槽位（如 pgnfw_xxxx@2）';

/// 与主控同一个正则。
final po0TokenPattern = RegExp(r'^pgnfw_[A-Za-z0-9_-]{4,200}(@[0-9]{1,2})?$');

final _scheme = RegExp(r'^https?://', caseSensitive: false);
final _domainLabel = RegExp(r'^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$');
final _digits = RegExp(r'^[0-9]+$');

bool _isIPv4(String s) {
  final p = s.split('.');
  if (p.length != 4) return false;
  for (final x in p) {
    if (x.isEmpty || x.length > 3 || !_digits.hasMatch(x)) return false;
    if (int.parse(x) > 255 || (x.length > 1 && x.startsWith('0'))) return false;
  }
  return true;
}

/// IPv6 字面量（不带方括号）；带 `%` zone 的不算。
bool _isIPv6(String s) {
  if (!s.contains(':') || s.contains('%')) return false;
  try {
    Uri.parseIPv6Address(s);
    return true;
  } on FormatException {
    return false;
  }
}

/// 域名（[s] 已小写）：每段 1–63 个字母 / 数字 / 连字符、不以连字符开头或结尾，没有空段。
/// 全由数字和点组成的不算域名——那是 IPv4，交给 [_isIPv4]（`1.2.3`、`1.2.3.999` 因此不会被当成域名放过）。
bool _isDomain(String s) {
  if (s.isEmpty || s.length > 253 || RegExp(r'^[0-9.]+$').hasMatch(s)) return false;
  return s.split('.').every(_domainLabel.hasMatch);
}

/// 地址规范化（与主控、iOS / macOS 同一套）：trim → 去掉开头的 `https://` / `http://`（不分大小写）→ 去掉结尾连续的 `/`，
/// 剩下的必须是 `host` 或 `host:port`：IPv4（四段、每段 0–255、不带前导 0；全由数字和点组成的一律按 IPv4 判）、
/// IPv6（带端口必须写成 `[v6]:port`，不带端口裸写或带方括号都行；`::ffff:1.2.3.4` 也算；带 `%` zone 的不收）或域名。
/// 返回 `(规范形式, null)` 或 `(null, 出错提示)`。规范形式：host 小写（IPv6 只转小写、不压缩不展开），IPv6 一律带方括号，
/// 端口去掉前导 0。
(String?, String?) parsePo0Address(String input) {
  var s = input.trim();
  s = s.replaceFirst(_scheme, '');
  while (s.endsWith('/')) {
    s = s.substring(0, s.length - 1);
  }
  if (s.isEmpty) return (null, po0AddressEmptyMessage);
  if (s.contains(RegExp(r'[/?#@]'))) return (null, po0AddressPathMessage);
  if (s.contains(RegExp(r'\s'))) return (null, po0AddressInvalidMessage);
  s = s.toLowerCase();

  String host;
  String? port;
  if (s.startsWith('[')) {
    final close = s.indexOf(']');
    if (close < 0) return (null, po0AddressInvalidMessage);
    host = s.substring(1, close);
    final rest = s.substring(close + 1);
    if (!_isIPv6(host)) return (null, po0AddressInvalidMessage);
    if (rest.isNotEmpty) {
      if (!rest.startsWith(':')) return (null, po0AddressInvalidMessage);
      port = rest.substring(1);
    }
  } else if (':'.allMatches(s).length > 1) {
    // 两个以上冒号只能是不带端口的裸 IPv6
    if (!_isIPv6(s)) {
      final last = s.lastIndexOf(':');
      return (null, _isIPv6(s.substring(0, last)) ? po0AddressV6PortMessage : po0AddressInvalidMessage);
    }
    host = s;
  } else {
    final colon = s.indexOf(':');
    host = colon < 0 ? s : s.substring(0, colon);
    if (colon >= 0) port = s.substring(colon + 1);
    if (!_isIPv4(host) && !_isDomain(host)) return (null, po0AddressInvalidMessage);
  }

  String? portOut;
  if (port != null) {
    final digits = _digits.hasMatch(port) ? port.replaceFirst(RegExp(r'^0+'), '') : null;
    final n = digits == null || digits.length > 5 ? null : int.tryParse(digits.isEmpty ? '0' : digits);
    if (n == null || n < 1 || n > 65535) return (null, po0AddressPortMessage);
    portOut = '$n';
  }
  final h = host.contains(':') ? '[$host]' : host;
  return (portOut == null ? h : '$h:$portOut', null);
}

/// 规范化地址；不合法返回 null。
String? normalizePo0Address(String input) => parsePo0Address(input).$1;

/// token 校验：trim 后匹配 [po0TokenPattern]；合法返回 null。
String? validatePo0Token(String input) {
  final t = input.trim();
  if (t.isEmpty) return po0TokenEmptyMessage;
  return po0TokenPattern.hasMatch(t) ? null : po0TokenInvalidMessage;
}

/// 上报地址：`https://<规范化地址>/api/firewall/<token 去掉 @槽位>/add`，带 `@N` 时加 `?slot=N`。
/// [address] 须已规范化、[token] 须已校验。
String po0ReportUrl(String address, String token) {
  final t = token.trim();
  final at = t.indexOf('@');
  final key = at < 0 ? t : t.substring(0, at);
  final slot = at < 0 ? '' : '?slot=${t.substring(at + 1)}';
  return 'https://$address/api/firewall/$key/add$slot';
}

/// token 的脱敏写法：`pgnfw_` + `••••` + 密钥部分（`pgnfw_` 之后、`@` 之前）的最后 4 个字符，有槽位再加 `@N`；
/// 密钥部分少于 8 个字符时只留 `pgnfw_••••`（加槽位）。不是 `pgnfw_` 开头的一律 `••••`。
/// 例：`pgnfw_abcd1234wxyz@2` → `pgnfw_••••wxyz@2`。
String maskPo0Token(String token) {
  const prefix = 'pgnfw_';
  final t = token.trim();
  if (!t.startsWith(prefix)) return '••••';
  final at = t.indexOf('@');
  final key = t.substring(prefix.length, at < 0 ? t.length : at);
  final slot = at < 0 ? '' : t.substring(at);
  return '$prefix••••${key.length < 8 ? '' : key.substring(key.length - 4)}$slot';
}

final _urlTokenSegment = RegExp(r'/api/firewall/([^/?#"\s]+)');
final _bareToken = RegExp(r'pgnfw_[A-Za-z0-9_-]+(@[0-9]{1,2})?');

/// 把一段文字（上报地址、核心回的错误——Go 的 url.Error 会把整个 url 带上）里的 po0 token 换成脱敏写法：
/// 先换上报地址里 `/api/firewall/<token>` 那一段，再换散落的 `pgnfw_…`。写日志 / 界面前都过一遍。
String redactPo0(String text) => text
    .replaceAllMapped(_urlTokenSegment, (m) => '/api/firewall/${maskPo0Token(m[1]!)}')
    .replaceAllMapped(_bareToken, (m) => maskPo0Token(m[0]!));

/// 自定义条目 → 上报目标；地址或 token 不合法的跳过（存进来时已校验，这里兜底）。
/// 名字（只用于日志）= 地址 + 脱敏 token。
Po0Server? po0CustomTarget(Po0CustomServer c) {
  final address = normalizePo0Address(c.address);
  final token = c.token.trim();
  if (address == null || validatePo0Token(token) != null) return null;
  final at = token.indexOf('@');
  return Po0Server(
    serverId: 0,
    name: '$address（${maskPo0Token(token)}）',
    ip: '',
    token: token,
    slot: at < 0 ? null : int.tryParse(token.substring(at + 1)),
    url: po0ReportUrl(address, token),
  );
}

/// 上报目标 = 主控下发的 + 自己添加的（追加在后），按上报地址去重、保持顺序。
List<Po0Server> mergePo0Servers(List<Po0Server> panel, List<Po0CustomServer> custom) {
  final seen = <String>{};
  return [
    for (final s in [...panel, ...custom.map(po0CustomTarget).nonNulls])
      if (seen.add(s.url)) s,
  ];
}

/// po0 服务器的主机列表（给直连规则用）：取上报地址的 host（Uri.host 已去掉 IPv6 方括号、转小写），解析不出才退回 `ip` 字段。
/// IP 规范化（`2001:db8:0::1` → `2001:db8::1`）；域名小写；两样都不是的跳过；去重、保持顺序。
List<String> po0DirectHosts(List<Po0Server> servers) {
  final out = <String>[];
  for (final s in servers) {
    var raw = Uri.tryParse(s.url)?.host ?? '';
    if (raw.isEmpty) raw = s.ip.trim();
    if (raw.startsWith('[') && raw.endsWith(']')) raw = raw.substring(1, raw.length - 1);
    final host = _directHost(raw);
    if (host != null && !out.contains(host)) out.add(host);
  }
  return out;
}

String? _directHost(String raw) {
  final addr = InternetAddress.tryParse(raw);
  // 经 rawAddress 转一次得到规范写法，同一地址不同写法才能去重
  if (addr != null) return InternetAddress.fromRawAddress(addr.rawAddress).address.toLowerCase();
  final d = raw.toLowerCase();
  return _isDomain(d) ? d : null;
}

/// 每个 po0 主机一条直连规则：IP 对齐 po0 官方脚本给 QX 的 `ip-cidr, <IP>/32, direct, no-resolve`；
/// 域名用 `DOMAIN,<host>,DIRECT`（不带 no-resolve）。也接受旧版落盘的纯 IP 列表。
List<String> po0DirectRules(List<String> hosts) => [
  for (final h in hosts)
    if (InternetAddress.tryParse(h) case final ip?)
      ip.type == InternetAddressType.IPv6 ? 'IP-CIDR6,$h/128,DIRECT,no-resolve' : 'IP-CIDR,$h/32,DIRECT,no-resolve'
    else if (_isDomain(h.toLowerCase()))
      'DOMAIN,${h.toLowerCase()},DIRECT',
];

/// 一次上报的结果：核心返回的 HTTP 状态码 + po0 响应体（或拨号 / 超时错误）。
class Po0ReportResult {
  const Po0ReportResult({required this.url, this.status = 0, this.body = '', this.error = ''});

  final String url;
  final int status;
  final String body;

  /// 请求没发出去 / 没等到应答时的原因（此时 [status] 为 0）
  final String error;

  bool get ok => status == 200;

  /// 403 = po0 token 无效
  bool get tokenInvalid => status == 403;

  /// 解析核心 `meowPo0Report` 返回的 JSON 数组。
  static List<Po0ReportResult> parseList(String raw) {
    if (raw.isEmpty) return const [];
    final dynamic decoded;
    try {
      decoded = json.decode(raw);
    } catch (_) {
      return const [];
    }
    if (decoded is! List) return const [];
    return [
      for (final r in decoded)
        if (r is Map)
          Po0ReportResult(
            url: r['url']?.toString() ?? '',
            status: Po0Server._int(r['status']) ?? 0,
            body: r['body']?.toString() ?? '',
            error: r['error']?.toString() ?? '',
          ),
    ];
  }

  /// po0 成功应答：`{enabled, whitelist:[{ip, slot}], limit, currentIp}`。解析不出（不是 JSON / 缺字段）→ null。
  Po0Whitelist? get whitelist => Po0Whitelist.parse(body);
}

class Po0Whitelist {
  const Po0Whitelist({required this.enabled, required this.count, required this.limit, required this.currentIp});

  final bool enabled;

  /// 白名单里现有条目数
  final int count;
  final int limit;
  final String currentIp;

  static Po0Whitelist? parse(String body) {
    if (body.isEmpty) return null;
    final dynamic decoded;
    try {
      decoded = json.decode(body);
    } catch (_) {
      return null;
    }
    if (decoded is! Map) return null;
    final list = decoded['whitelist'];
    return Po0Whitelist(
      enabled: decoded['enabled'] == true,
      count: list is List ? list.length : 0,
      limit: Po0Server._int(decoded['limit']) ?? 0,
      currentIp: decoded['currentIp']?.toString() ?? '',
    );
  }
}
