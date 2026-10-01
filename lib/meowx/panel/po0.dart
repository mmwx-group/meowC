import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

/// 用户在主控里登记的 po0 服务器（独立的防火墙白名单服务）：客户端把本机出口 IP POST 到 [url] 加白。
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

/// po0 服务器的 IP 列表（给直连规则用）：取 `ip` 字段，没有就取 url 的 host（Uri.host 已去掉 IPv6 方括号）；
/// 不是 IP 字面量的跳过；规范化后去重、保持顺序。
List<String> po0DirectIps(List<Po0Server> servers) {
  final out = <String>[];
  for (final s in servers) {
    var raw = s.ip.trim();
    if (raw.isEmpty) raw = Uri.tryParse(s.url)?.host ?? '';
    if (raw.startsWith('[') && raw.endsWith(']')) raw = raw.substring(1, raw.length - 1);
    final addr = InternetAddress.tryParse(raw);
    if (addr == null) continue;
    // 经 rawAddress 转一次得到规范写法（`2001:db8:0::1` → `2001:db8::1`），同一地址不同写法才能去重
    final ip = InternetAddress.fromRawAddress(addr.rawAddress).address.toLowerCase();
    if (!out.contains(ip)) out.add(ip);
  }
  return out;
}

/// 每个 po0 IP 一条直连规则（对齐 po0 官方脚本给 QX 的 `ip-cidr, <IP>/32, direct, no-resolve`）。
List<String> po0DirectRules(List<String> ips) => [
  for (final ip in ips)
    if (ip.contains(':')) 'IP-CIDR6,$ip/128,DIRECT,no-resolve' else 'IP-CIDR,$ip/32,DIRECT,no-resolve',
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
