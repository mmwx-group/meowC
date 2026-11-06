import 'dart:convert';

import 'package:bett_box/clash/clash.dart';
import 'package:bett_box/enum/enum.dart';
import 'package:flutter/foundation.dart';

/// 内核里 tailscale 出站（喵窝 / 订阅里的组网节点）的状态（核心 meowTailscaleStatus，见 core/meow_tailscale.go
/// 与 core/Clash.Meta/adapter/outbound/tailscale_status.go）。
class TsStatus {
  const TsStatus({required this.state, this.authUrl = '', this.self, this.peers = const [], this.health = const []});

  /// NotStarted / NoState / NeedsLogin / NeedsMachineAuth / Stopped / Starting / Running
  final String state;
  final String authUrl;

  /// 本机（登记过才有）
  final TsPeer? self;
  final List<TsPeer> peers;
  final List<String> health;

  bool get running => state == 'Running';
  bool get needsLogin => state == 'NeedsLogin';

  static TsStatus? parse(Object? o) {
    if (o is! Map) return null;
    return TsStatus(
      state: o['state']?.toString() ?? '',
      authUrl: o['authURL']?.toString() ?? '',
      self: TsPeer.parse(o['self']),
      peers: [for (final p in (o['peers'] is List ? o['peers'] as List : const [])) ?TsPeer.parse(p)],
      health: [for (final h in (o['health'] is List ? o['health'] as List : const [])) h.toString()],
    );
  }

  /// 对端里找主控设备列表的那一台：先按编号（Headscale 的 StableID 就是数字编号），再按地址
  TsPeer? peerFor({int? id, String ip = ''}) {
    for (final p in peers) {
      if (id != null && p.id == id) return p;
    }
    if (ip.isEmpty) return null;
    for (final p in peers) {
      if (p.addresses.contains(ip)) return p;
    }
    return null;
  }

  /// 一行状态（「组网」页 Tailscale 那一项）
  String get stateText => switch (state) {
    'Running' => '已连接',
    'NeedsLogin' => '需要登录',
    'NeedsMachineAuth' => '等待管理员批准这台设备',
    'Stopped' => '已停止',
    'NotStarted' => '还没启动',
    _ => '连接中…',
  };
}

class TsPeer {
  const TsPeer({
    this.id,
    required this.name,
    this.dnsName = '',
    this.addresses = const [],
    this.online = false,
    this.active = false,
    this.curAddr = '',
    this.relay = '',
    this.lastSeen,
  });

  final int? id;
  final String name;
  final String dnsName;
  final List<String> addresses;
  final bool online;
  final bool active;

  /// 直连用的地址（空 = 没打通直连，走中继）
  final String curAddr;
  final String relay;
  final DateTime? lastSeen;

  bool get direct => curAddr.isNotEmpty;

  /// 「直连」/「中继 · 区域」（MeowX 同一写法）
  String get pathText => direct ? '直连' : (relay.isEmpty ? '中继' : '中继 · $relay');

  static TsPeer? parse(Object? o) {
    if (o is! Map) return null;
    return TsPeer(
      id: int.tryParse(o['id']?.toString() ?? ''),
      name: o['name']?.toString() ?? '',
      dnsName: o['dnsName']?.toString() ?? '',
      addresses: [for (final a in (o['addresses'] is List ? o['addresses'] as List : const [])) a.toString()],
      online: o['online'] == true,
      active: o['active'] == true,
      curAddr: o['curAddr']?.toString() ?? '',
      relay: o['relay']?.toString() ?? '',
      lastSeen: DateTime.tryParse(o['lastSeen']?.toString() ?? ''),
    );
  }
}

/// 核心的回包：{status: …|null, error?}。没有这个出站 → (null, null)；旧核心不认这个动作 → 抛出 / 回 null，按拿不到处理。
({TsStatus? status, String? error}) parseTsStatusResponse(String? raw) {
  if (raw == null || raw.isEmpty) return (status: null, error: null);
  try {
    final o = json.decode(raw);
    if (o is! Map) return (status: null, error: null);
    final err = o['error']?.toString();
    return (status: TsStatus.parse(o['status']), error: (err == null || err.isEmpty) ? null : err);
  } catch (_) {
    return (status: null, error: null);
  }
}

/// 单测换掉问核心的那一步（不碰核心）。
@visibleForTesting
Future<({TsStatus? status, String? error})> Function(String name)? debugFetchTailscaleStatus;

/// 问核心名字是 [name] 的 tailscale 出站的状态（没启动的会先启动）。
Future<({TsStatus? status, String? error})> fetchTailscaleStatus(String name, {Duration timeout = const Duration(seconds: 5)}) async {
  final debug = debugFetchTailscaleStatus;
  if (debug != null) return debug(name);
  try {
    final raw = await clashCore.clashInterface.invoke<String?>(
      method: ActionMethod.meowTailscaleStatus,
      data: json.encode({'name': name, 'timeout': timeout.inMilliseconds}),
      timeout: timeout + const Duration(seconds: 3),
    );
    return parseTsStatusResponse(raw);
  } catch (e) {
    return (status: null, error: null);
  }
}
