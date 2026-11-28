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
    this.peerRelay = '',
    this.peerRelayVia = '',
    this.rxBytes = 0,
    this.txBytes = 0,
    this.lastHandshake,
  });

  final int? id;
  final String name;
  final String dnsName;
  final List<String> addresses;
  final bool online;
  final bool active;

  /// 直连用的地址（空 = 没打通直连）
  final String curAddr;

  /// 经中继服务器（DERP）时的区域代码（如 meowx-7 / meowx-7-alt）
  final String relay;
  final DateTime? lastSeen;

  /// 经设备中继时的中继地址（`ip:port:vni:N`；空 = 没走设备中继）。走设备中继时 curAddr 为空、relay 照样有值，
  /// 所以判路径要先看它（喵窝设备中继，Design/mesh-peer-relay.md §2.2）
  final String peerRelay;

  /// 中继设备的名字（内核拿 [peerRelay] 的 IP 对本机设备列表里各设备上报的公网端点认出来的；认不出 / 旧内核为空）
  final String peerRelayVia;

  /// 与这台之间收 / 发的字节数（本机 WireGuard 计数，旧内核没有为 0）
  final int rxBytes;
  final int txBytes;

  /// 最近一次 WireGuard 握手成功的时刻（没握过手 / 旧内核为 null）
  final DateTime? lastHandshake;

  bool get direct => curAddr.isNotEmpty;
  bool get viaPeerRelay => peerRelay.isNotEmpty;

  /// 「经设备中继」/「直连」/「中继 · 区域」/「空闲」（MeowX 同一写法）。顺序同路径上报：设备中继 > 直连 > 中继服务器。
  /// 设备之间按需打通：最近没流量、也没有直连地址的还没真正连过（relay 只是对方的家中继），以前一律写成「中继」，
  /// 要访问一次才变「直连」，看着像没打通
  String get pathText {
    if (viaPeerRelay) return peerRelayVia.isEmpty ? '经设备中继' : '经 ${meshShortName(peerRelayVia)} 中继';
    if (direct) return '直连';
    if (!active) return '空闲';
    return relay.isEmpty ? '中继' : '中继 · $relay';
  }

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
      peerRelay: o['peerRelay']?.toString() ?? '',
      peerRelayVia: o['peerRelayVia']?.toString() ?? '',
      rxBytes: _int(o['rxBytes']),
      txBytes: _int(o['txBytes']),
      lastHandshake: DateTime.tryParse(o['lastHandshake']?.toString() ?? ''),
    );
  }
}

/// 设备名的短名：去掉 MagicDNS 后缀（「home-openwrt.meowx.internal.」→「home-openwrt」，本来就是短名的原样）
String meshShortName(String name) {
  final s = name.endsWith('.') ? name.substring(0, name.length - 1) : name;
  final i = s.indexOf('.');
  return i <= 0 ? s : s.substring(0, i);
}

int _int(Object? v) => switch (v) {
  int i => i,
  num n => n.toInt(),
  String s => int.tryParse(s) ?? 0,
  _ => 0,
};

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
