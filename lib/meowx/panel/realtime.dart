import 'dart:convert';
import 'dart:io';

import '../config/subscription_meta.dart';
import '../state/format.dart';

// 主控实时通道（入口即时切换 + 订阅自动更新，规格 MeowX 仓库 Design/entry-realtime.md）现在在 Go 内核里
// （core/Clash.Meta 的 component/panelrt；桥层 core/meow_realtime.go），这里只是 Dart 一侧的调用与回包解析：
// 以前 Dart 自己连 `/api/secure/ws`，安卓上界面一收通道就断，入口切换也到不了内核；
// 同一主控两条连接（Dart 一条、内核一条）还会多占主控每个用户 16 条的名额，所以 Dart 这条整个去掉了。

/// 核心 `meowRealtime` 动作（参数 → 回包 JSON）。
typedef RealtimeSend = Future<String> Function(Map<String, Object?> params);

/// 内核通道的各个操作。[send] 在 App 里是 `clashCore.clashInterface.invoke(meowRealtime)`，测试里换掉。
class CoreRealtime {
  const CoreRealtime(this.send);

  final RealtimeSend send;

  Future<Map<String, dynamic>> _call(Map<String, Object?> params) async {
    final raw = await send(params);
    if (raw.isEmpty) return const {'error': '核心没有回应'};
    try {
      final v = json.decode(raw);
      return v is Map ? v.cast<String, dynamic>() : const {'error': '回包无法解析'};
    } on FormatException {
      return const {'error': '回包无法解析'};
    }
  }

  /// 要连哪些主控 + 手上各订阅的 rev（桥层落盘，代理运行时才接到内核上）。回错误文字，成功回 null。
  Future<String?> configure(RealtimePlan plan) async {
    final r = await _call({
      'op': 'configure',
      'channels': [for (final c in plan.channels) c.toJson()],
      'subs': [for (final s in plan.subs) s.toJson()],
    });
    final e = r['error']?.toString() ?? '';
    return e.isEmpty ? null : e;
  }

  /// 待更新队列（内核通知过、Dart 还没处理完的订阅变更）。
  Future<List<SubChange>> pending() async {
    final items = (await _call({'op': 'pending'}))['items'];
    if (items is! List) return const [];
    return [
      for (final it in items)
        if (it is Map) SubChange.fromJson(it.cast<String, dynamic>()),
    ];
  }

  Future<void> ack(List<SubChange> items) async {
    if (items.isEmpty) return;
    await _call({
      'op': 'ack',
      'items': [for (final it in items) it.toJson()],
    });
  }

  /// 清掉来自这个主控的入口覆盖（退出登录、这个主控的订阅都删了）。回清掉的条数。
  Future<int> clear(String base) async {
    if (base.isEmpty) return 0;
    final n = (await _call({'op': 'clear', 'source': base}))['cleared'];
    return n is num ? n.toInt() : 0;
  }

  /// 换网：退避中的通道提前重连。
  Future<void> kick() => _call({'op': 'kick'});

  Future<List<EntryOverride>> entries() async => parseEntryOverrides((await _call({'op': 'entries'}))['entries']);
}

/// 入口覆盖表的一条（内核 entryoverride.View）：主控把节点 [server] 指定成这几个入口 IP。
class EntryOverride {
  const EntryOverride({
    required this.server,
    required this.ips,
    this.rev = 0,
    this.chainId = 0,
    this.source = '',
    this.updatedAt = 0,
    this.active = false,
    this.ports,
  });

  final String server;
  final List<String> ips;
  final int rev;
  final int chainId;

  /// 来自哪个主控（规范化的 base）
  final String source;

  /// 本机换上这份入口的时间（毫秒）
  final int updatedAt;

  /// 当前配置里有节点的 server 等于这个键（只有这时内核才会用它）
  final bool active;

  /// 这个入口的端口（规格 §1「入口端口」，2026-11-17 加）：节点端口在里面才算转发节点。
  /// null = 老主控没给，照旧只比 server；空 = 链上还没有节点，不匹配任何节点。
  /// 为什么要它：转发链入口所在的机器上另开的直连节点 server 和入口键一样，只比 server 会被当成转发节点。
  final List<int>? ports;

  factory EntryOverride.fromJson(Map<String, dynamic> j) => EntryOverride(
    server: j['server']?.toString() ?? '',
    ips: [
      for (final ip in (j['ips'] is List ? j['ips'] as List : const []))
        if (ip.toString().isNotEmpty) ip.toString(),
    ],
    rev: (j['rev'] as num?)?.toInt() ?? 0,
    chainId: (j['chainId'] as num?)?.toInt() ?? 0,
    source: j['source']?.toString() ?? '',
    updatedAt: (j['updatedAt'] as num?)?.toInt() ?? 0,
    active: j['active'] == true,
    ports: j['ports'] is List ? [for (final p in j['ports'] as List) if (p is num) p.toInt()] : null,
  );

  /// 端口 [port] 的节点用不用这条覆盖：没给端口集合（老主控）时都用。
  bool matchesPort(int? port) => ports == null || (port != null && ports!.contains(port));

  @override
  bool operator ==(Object other) =>
      other is EntryOverride &&
      other.server == server &&
      other.rev == rev &&
      other.active == active &&
      other.updatedAt == updatedAt &&
      other.ips.join(',') == ips.join(',') &&
      other.ports?.join(',') == ports?.join(',');

  @override
  int get hashCode => Object.hash(server, rev, active, updatedAt, ips.join(','), ports?.join(','));
}

/// 解析核心 `entries` 的列表；只留有 IP 的。
List<EntryOverride> parseEntryOverrides(Object? list) {
  if (list is! List) return const [];
  return [
    for (final it in list)
      if (it is Map) EntryOverride.fromJson(it.cast<String, dynamic>()),
  ].where((e) => e.server.isNotEmpty && e.ips.isNotEmpty).toList();
}

/// 节点 server 的规范写法（同内核 entryoverride.NormalizeKey）：IPv6 去方括号与 zone、IPv4-mapped 还原成 IPv4，
/// 按地址字节比；域名小写、去掉结尾的点。
String entryKeyOf(String server) {
  var s = server.trim();
  if (s.startsWith('[') && s.endsWith(']')) s = s.substring(1, s.length - 1);
  final zone = s.indexOf('%');
  final bare = zone > 0 ? s.substring(0, zone) : s;
  final ip = InternetAddress.tryParse(bare);
  if (ip != null) {
    final raw = ip.rawAddress;
    // ::ffff:a.b.c.d → a.b.c.d
    if (raw.length == 16 && raw.sublist(0, 10).every((b) => b == 0) && raw[10] == 0xff && raw[11] == 0xff) {
      return raw.sublist(12).join('.');
    }
    return raw.length == 4 ? raw.join('.') : raw.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }
  var host = s.toLowerCase();
  while (host.endsWith('.')) {
    host = host.substring(0, host.length - 1);
  }
  return host;
}

/// 节点（[server] + [port]）现在生效的主控指定入口；没有为 null。主控给了端口集合时节点端口要在里面（规格 §6）。
EntryOverride? entryOverrideFor(String server, List<EntryOverride> entries, {int? port}) {
  if (server.trim().isEmpty) return null;
  final key = entryKeyOf(server);
  for (final e in entries) {
    if (e.active && e.ips.isNotEmpty && entryKeyOf(e.server) == key && e.matchesPort(port)) return e;
  }
  return null;
}

/// 节点详情里的一行：「主控指定入口 203.0.113.11, 203.0.113.12 · 3 分钟前」（时间是本机换上这份入口的时间）。
String entryOverrideLabel(EntryOverride e, {DateTime? now}) {
  final ips = e.ips.join(', ');
  if (e.updatedAt <= 0) return '主控指定入口 $ips';
  return '主控指定入口 $ips · ${fmtRelative(DateTime.fromMillisecondsSinceEpoch(e.updatedAt), now)}';
}
