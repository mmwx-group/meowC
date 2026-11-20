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

/// po0 白名单里的一项：`ip` 可能是精确 IP，也可能是 `x.x.x.0/24`（服务端按 C 段加白）；[slot] 有值 = 钉在这个槽位、
/// 不会被挤掉，null = 普通条目（名单满了按写入时间先进先出挤掉最旧的）。
class Po0WhitelistEntry {
  const Po0WhitelistEntry({required this.ip, this.slot});

  final String ip;
  final int? slot;

  @override
  bool operator ==(Object other) => other is Po0WhitelistEntry && other.ip == ip && other.slot == slot;

  @override
  int get hashCode => Object.hash(ip, slot);
}

/// po0 成功应答（照 po0 官方脚本 reallinzc/po0fw 的读法）：`{enabled, whitelist, limit, currentIp}`。
/// `whitelist` 每项是 `{ip, slot}`，旧版服务端是纯 IP 字符串（= 没有槽位），两种都认。
/// 老版 po0 可能只回个确认、缺字段（规格 §1.1「缺字段时信 200」）：`enabled` 缺省按开启，其余缺了就是 null。
class Po0Whitelist {
  const Po0Whitelist({required this.enabled, this.entries, this.limit, this.currentIp});

  /// 只有应答里明写 `enabled: false` 才是 false
  final bool enabled;

  /// 整份名单，按应答顺序；应答里没有 `whitelist` 数组时为 null
  final List<Po0WhitelistEntry>? entries;
  final int? limit;

  /// po0 看到的本机出口（可能是 `x.x.x.0/24`）；没有 / 空串时为 null
  final String? currentIp;

  /// 白名单里现有条目数（没有名单算 0）
  int get count => entries?.length ?? 0;

  /// 解析不出（空正文 / 不是 JSON 对象）→ null。
  static Po0Whitelist? parse(String body) {
    final decoded = _jsonObject(body);
    if (decoded == null) return null;
    final list = decoded['whitelist'];
    final ip = decoded['currentIp']?.toString().trim() ?? '';
    return Po0Whitelist(
      enabled: decoded['enabled'] != false,
      entries: list is! List
          ? null
          : [
              for (final e in list)
                if (e is String)
                  Po0WhitelistEntry(ip: e.trim())
                else if (e is Map)
                  Po0WhitelistEntry(ip: e['ip']?.toString().trim() ?? '', slot: Po0Server._int(e['slot'])),
            ],
      limit: Po0Server._int(decoded['limit']),
      currentIp: ip.isEmpty ? null : ip,
    );
  }
}

Map<dynamic, dynamic>? _jsonObject(String body) {
  if (body.trim().isEmpty) return null;
  try {
    final decoded = json.decode(body);
    return decoded is Map ? decoded : null;
  } on FormatException {
    return null;
  }
}

/// 同段判断（同 po0 官方脚本 `sameC24`）：两边字符串相等算同一个；任一边以 `/24` 结尾时，去掉 `/24` 后按 `.` 分成 4 段，
/// 前三段相同算同一个；两边都是精确 IP 时必须全等。IPv6 只按全等。
bool po0SameC24(String a, String b) {
  final x = a.trim(), y = b.trim();
  if (x.isEmpty || y.isEmpty) return false;
  if (x == y) return true;
  if (!x.endsWith('/24') && !y.endsWith('/24')) return false;
  List<String>? parts(String s) {
    final ip = s.endsWith('/24') ? s.substring(0, s.length - 3) : s;
    final p = ip.split('.');
    return p.length == 4 ? p : null;
  }

  final px = parts(x), py = parts(y);
  if (px == null || py == null) return false;
  return px[0] == py[0] && px[1] == py[1] && px[2] == py[2];
}

/// 上报地址里的槽位（`?slot=N`）；没有 / 写错 → null。
int? po0SlotFromUrl(String url) => int.tryParse(Uri.tryParse(url)?.queryParameters['slot'] ?? '');

enum Po0ResultKind {
  /// 200、防火墙开着、名单里有本机
  success,

  /// 200、`enabled == false`
  disabled,

  /// 200、防火墙开着但名单里没有本机
  notApplied,

  /// 403 且上报地址带槽位：本机 IP 已占用这台 po0 的另一个槽位
  slotConflict,

  /// 403 且不带槽位：token 无效
  invalidToken,

  /// 其它状态码 / 连不上 / 应答无法解析
  failed,
}

/// 槽位冲突的说明（列表行与气泡里同一句）
const po0SlotConflictMessage = '槽位冲突：本机 IP 已在这台 po0 的其它槽位，先到 po0 面板删除旧槽位';

/// 每台 po0 上一次上报的结论（五端同一份规格：MeowX 仓库 Design/po0-ggy-results.md §1.3）。
/// 键是这台 po0 的上报地址（含 token，只当键用、不显示）；结论里的文字绝不带完整 token。
class Po0Result {
  const Po0Result({
    required this.kind,
    this.message = '',
    required this.date,
    this.enabled,
    this.limit,
    this.currentIp,
    this.entries,
    this.slot,
  });

  final Po0ResultKind kind;

  /// 失败原因 / 冲突说明；成功时空（已脱敏）
  final String message;
  final DateTime date;

  /// 200 时有
  final bool? enabled;
  final int? limit;

  /// po0 看到的本机出口（可能是 /24）；403 正文是 JSON 且带 currentIp 时也记下
  final String? currentIp;

  /// 200 时的整份名单，按应答顺序；应答里没有名单（老版 po0）时为 null，气泡里不画名单
  final List<Po0WhitelistEntry>? entries;

  /// 这次上报用的槽位（上报地址里的 `?slot=N`）
  final int? slot;

  /// 有 200 的名单可画（气泡里画名单）
  bool get hasWhitelist => kind == Po0ResultKind.success || kind == Po0ResultKind.disabled || kind == Po0ResultKind.notApplied;

  /// 名单里哪一项是本机（与 [currentIp] 同段）；没有 → -1
  int get selfIndex {
    final ip = currentIp, list = entries;
    if (ip == null || ip.isEmpty || list == null) return -1;
    return list.indexWhere((e) => po0SameC24(e.ip, ip));
  }

  bool get ok => kind == Po0ResultKind.success;

  /// 判断核心回来的一条结果。[raw] 是核心的原始结果（状态码 + 应答原文 / 错误），槽位从上报地址里取。
  static Po0Result judge(Po0ReportResult raw, {DateTime? at}) {
    final when = at ?? DateTime.now();
    final slot = po0SlotFromUrl(raw.url);
    if (raw.error.isNotEmpty) {
      return Po0Result(kind: Po0ResultKind.failed, message: po0ErrorText(raw.error), date: when, slot: slot);
    }
    if (raw.status == 403) {
      final ip = _jsonObject(raw.body)?['currentIp']?.toString().trim();
      return Po0Result(
        kind: slot == null ? Po0ResultKind.invalidToken : Po0ResultKind.slotConflict,
        message: slot == null ? '' : po0SlotConflictMessage,
        date: when,
        currentIp: ip == null || ip.isEmpty ? null : ip,
        slot: slot,
      );
    }
    if (raw.status != 200) {
      return Po0Result(kind: Po0ResultKind.failed, message: 'HTTP ${raw.status}', date: when, slot: slot);
    }
    final w = Po0Whitelist.parse(raw.body);
    if (w == null) return Po0Result(kind: Po0ResultKind.failed, message: '应答无法解析', date: when, slot: slot);
    // 名单与 currentIp 都有才比得了；缺一个（老版 po0 只回个确认）无从比对，信 200
    final list = w.entries, ip = w.currentIp;
    final missed = list != null && ip != null && !list.any((e) => po0SameC24(e.ip, ip));
    return Po0Result(
      kind: !w.enabled ? Po0ResultKind.disabled : (missed ? Po0ResultKind.notApplied : Po0ResultKind.success),
      date: when,
      enabled: w.enabled,
      limit: w.limit,
      currentIp: ip,
      entries: list,
      slot: slot,
    );
  }

  /// 列表行文字（不含时间）。
  String get summary => switch (kind) {
    Po0ResultKind.success => '已加白$_countSuffix',
    Po0ResultKind.disabled => 'po0 没有开启防火墙',
    Po0ResultKind.notApplied => '加白未生效$_countSuffix',
    Po0ResultKind.slotConflict => po0SlotConflictMessage,
    Po0ResultKind.invalidToken => 'token 无效',
    Po0ResultKind.failed => '失败：$message',
  };

  /// 名单条数与 limit 都知道时的「 · 条数/limit」，缺一个就不写
  String get _countSuffix {
    final list = entries, l = limit;
    return list == null || l == null ? '' : ' · ${list.length}/$l';
  }

  /// 气泡里的概况：`防火墙已开启 · 名单 <条数>/<limit>`（条数或 limit 不知道时只写「防火墙已开启」）/ `防火墙未开启`。
  String get overview {
    if (enabled == false) return '防火墙未开启';
    final suffix = _countSuffix;
    return suffix.isEmpty ? '防火墙已开启' : '防火墙已开启 · 名单${suffix.substring(2)}';
  }

  @override
  bool operator ==(Object other) =>
      other is Po0Result &&
      other.kind == kind &&
      other.message == message &&
      other.date == date &&
      other.enabled == enabled &&
      other.limit == limit &&
      other.currentIp == currentIp &&
      other.slot == slot &&
      _listEq(other.entries ?? const [], entries ?? const []) &&
      (other.entries == null) == (entries == null);

  @override
  int get hashCode => Object.hash(kind, message, date, enabled, limit, currentIp, slot, Object.hashAll(entries ?? const []));
}

bool _listEq<T>(List<T> a, List<T> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// Go 的 url.Error 写成 `Post "<整个上报地址>": <原因>`：地址对用户没用，只留原因
final _urlErrorPrefix = RegExp(r'^[A-Za-z]+ "[^"]*": ');

/// 核心回的错误 → 界面里的失败原因：去掉 url.Error 带的整个地址，剩下的 token 换成脱敏写法。
String po0ErrorText(String error) => redactPo0(error.trim().replaceFirst(_urlErrorPrefix, ''));

/// 列表里一台 po0 的脱敏写法：`地址 · pgnfw_••••<后4位>[@N]`（地址、token 与槽位都从上报地址里取）。
/// 取不出地址的退回只给脱敏 token。
String po0UrlLabel(String url) {
  final uri = Uri.tryParse(url);
  if (uri == null) return redactPo0(url);
  final seg = uri.pathSegments;
  final i = seg.indexOf('firewall');
  final token = i >= 0 && i + 1 < seg.length ? seg[i + 1] : '';
  final slot = uri.queryParameters['slot'];
  final masked = maskPo0Token(slot == null || slot.isEmpty ? token : '$token@$slot');
  final host = uri.host.contains(':') ? '[${uri.host}]' : uri.host;
  final address = uri.hasPort ? '$host:${uri.port}' : host;
  return address.isEmpty ? masked : '$address · $masked';
}

/// 自定义条目在列表 / 气泡里的名字与副标题（规格 §4）：有备注时标题 = 备注、副标题 = `地址 · 脱敏 token`；
/// 没备注时照旧（标题 = 地址、副标题 = 脱敏 token）。
(String title, String subtitle) po0CustomLabels(Po0CustomServer c) {
  final masked = maskPo0Token(c.token);
  final note = c.note.trim();
  return note.isEmpty ? (c.address, masked) : (note, '${c.address} · $masked');
}
