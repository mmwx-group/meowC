import 'dart:async';

import 'package:bett_box/common/common.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../panel/account.dart';
import '../panel/client.dart';
import '../panel/mesh.dart';
import 'mesh.dart';
import 'meow_settings.dart';

export '../panel/mesh.dart'
    show
        MeshPathsSnapshot,
        MeshPathLink,
        MeshPathEnd,
        MeshRelayInfo,
        MeshRelaySession,
        MeshRelayConfig,
        MeshRelayState,
        MeshRelayApiException,
        parseMeshPeerRelay,
        validateMeshRelayForm;

// 喵窝设备中继的读取与设置（Design/mesh-peer-relay.md §2.4 / §2.6）：「组网」页 / 设备详情 / 中继设置页看得见时
// 每 15 秒读一次主控汇总的路径（`GET /user/mesh/paths`）与本账号的中继设备（`GET /user/mesh/relay`），看不见就不读。

/// 一台设备此刻走的路。
enum MeshPathKind { direct, peerRelay, derp, idle }

/// 显示用的路径：类型以本机内核的实时值为准，中继设备名 / 中继服务器名从主控数据补全。
@immutable
class MeshPathView {
  const MeshPathView(
    this.kind, {
    this.relayName = '',
    this.relayAddr = '',
    this.relayOther = false,
    this.derpName = '',
    this.derpRegion = '',
    this.fromPanel = false,
    this.stale = false,
    this.reportedAt,
  });

  final MeshPathKind kind;

  /// 经设备中继时主控认出的中继设备名（认不出为空）
  final String relayName;

  /// 中继的 `ip:port`
  final String relayAddr;

  /// 中继设备属于别的账号
  final bool relayOther;

  /// 经中继服务器时的服务器名（主控给的）与区域代码
  final String derpName;
  final String derpRegion;

  /// 本机内核里没有（或判不出）这台，按主控的记录显示
  final bool fromPanel;

  /// 主控的记录超过 3 分钟没更新（灰显、注「x 分钟前」）
  final bool stale;
  final DateTime? reportedAt;

  @override
  bool operator ==(Object other) =>
      other is MeshPathView &&
      other.kind == kind &&
      other.relayName == relayName &&
      other.relayAddr == relayAddr &&
      other.relayOther == relayOther &&
      other.derpName == derpName &&
      other.derpRegion == derpRegion &&
      other.fromPanel == fromPanel &&
      other.stale == stale &&
      other.reportedAt == reportedAt;

  @override
  int get hashCode => Object.hash(kind, relayName, relayAddr, relayOther, derpName, derpRegion, fromPanel, stale, reportedAt);
}

/// [local]：本机内核里的这台对端；[link]：主控记录的本机与它之间的连接；[paths]：整份主控数据（按地址 / 区域补名字）。
/// 都判不出 → null（不显示路径）。
MeshPathView? meshPathView({TsPeer? local, MeshPathLink? link, MeshPathsSnapshot? paths}) {
  if (local != null) {
    if (local.peerRelay.isNotEmpty) {
      final hostPort = parseMeshPeerRelay(local.peerRelay)?.hostPort ?? '';
      final via = (link?.path == 'peer_relay' ? link?.via : null) ?? paths?.viaForAddress(hostPort);
      return MeshPathView(MeshPathKind.peerRelay, relayName: via?.name ?? '', relayAddr: hostPort, relayOther: via?.isOther ?? false);
    }
    if (local.curAddr.isNotEmpty) return const MeshPathView(MeshPathKind.direct);
    if (local.active && local.relay.isNotEmpty) {
      final code = local.relay;
      final fromLink = link?.derp?.regionCode == code ? link?.derp?.name : null;
      final name = (fromLink != null && fromLink.isNotEmpty) ? fromLink : (paths?.derpForRegion(code)?.name ?? '');
      return MeshPathView(MeshPathKind.derp, derpName: name, derpRegion: code);
    }
    // 本机这会儿判不出（最近没流量）：有主控的记录就按它，没有就是空闲
    return _fromLink(link) ?? const MeshPathView(MeshPathKind.idle);
  }
  return _fromLink(link);
}

MeshPathView? _fromLink(MeshPathLink? link) {
  if (link == null) return null;
  final kind = switch (link.path) {
    'direct' => MeshPathKind.direct,
    'peer_relay' => MeshPathKind.peerRelay,
    'derp' => MeshPathKind.derp,
    _ => null,
  };
  if (kind == null) return null;
  return MeshPathView(
    kind,
    relayName: link.via?.name ?? '',
    relayAddr: link.viaAddr,
    relayOther: link.via?.isOther ?? false,
    derpName: link.derp?.name ?? '',
    derpRegion: link.derp?.regionCode ?? '',
    fromPanel: true,
    stale: link.stale,
    reportedAt: link.reportedAt,
  );
}

/// 开着中继、状态停在 pending 超过 3 分钟：提示「设备未响应」
const meshRelayPendingHint = Duration(minutes: 3);

bool meshRelayPendingStuck(MeshRelayConfig cfg, DateTime? pendingSince, DateTime now) =>
    cfg.enabled && cfg.state == MeshRelayState.pending && pendingSince != null && now.difference(pendingSince) >= meshRelayPendingHint;

@immutable
class MeshRelayViewState {
  const MeshRelayViewState({this.paths, this.relays = const {}, this.loadedAt, this.error, this.unsupported = false});

  final MeshPathsSnapshot? paths;

  /// 本账号配置过 / 上报过中继能力的设备（键 = 设备编号）
  final Map<int, MeshRelayConfig> relays;
  final DateTime? loadedAt;
  final String? error;

  /// 主控没有这些接口（回过 404）
  final bool unsupported;

  /// 这台设备能当中继（上报过中继能力）：只对它显示中继开关
  bool capable(int deviceId) => relays[deviceId]?.capable == true;

  /// 是本账号的中继设备（显示「中继」标签）：上报过能力，或主控 paths 里列为本账号的中继
  bool isRelay(int deviceId) => capable(deviceId) || (paths?.relayOf(deviceId)?.mine ?? false);

  MeshRelayViewState copyWith({
    MeshPathsSnapshot? paths,
    Map<int, MeshRelayConfig>? relays,
    DateTime? loadedAt,
    String? error,
    bool clearError = false,
    bool? unsupported,
  }) => MeshRelayViewState(
    paths: paths ?? this.paths,
    relays: relays ?? this.relays,
    loadedAt: loadedAt ?? this.loadedAt,
    error: clearError ? null : (error ?? this.error),
    unsupported: unsupported ?? this.unsupported,
  );
}

class MeshRelayController extends Notifier<MeshRelayViewState> {
  /// 页面轮询的节拍（[refresh] 在这之内的重复调用合并掉）
  static const every = Duration(seconds: 15);

  Future<void>? _inFlight;
  final Map<int, DateTime> _pendingSince = {};

  @override
  MeshRelayViewState build() {
    // 换账号 / 退出登录：从头来
    ref.watch(meowSettingProvider.select((s) => s.account.token));
    _pendingSince.clear();
    return const MeshRelayViewState();
  }

  String get _token => ref.read(meowSettingProvider).account.token;

  /// 开着中继、状态为 pending 的设备从什么时候起一直是 pending（本机看到的）
  DateTime? pendingSince(int deviceId) => _pendingSince[deviceId];

  void _note(MeshRelayConfig c) {
    if (c.enabled && c.state == MeshRelayState.pending) {
      _pendingSince.putIfAbsent(c.deviceId, DateTime.now);
    } else {
      _pendingSince.remove(c.deviceId);
    }
  }

  /// 读一次主控（页面看得见时每 [every] 调）。[force] = 不管离上次多久。
  Future<void> refresh({bool force = false}) {
    final at = state.loadedAt;
    if (!force && at != null && DateTime.now().difference(at) < every - const Duration(seconds: 2)) return Future.value();
    return _inFlight ??= _refresh().whenComplete(() => _inFlight = null);
  }

  Future<void> _refresh() async {
    final mesh = ref.read(meshProvider);
    final client = ref.read(panelClientProvider);
    final token = _token;
    if (mesh.deviceRelay == null || client == null || token.isEmpty) return;
    if (!meshRelayApiGate.allowed(client.host)) {
      state = state.copyWith(unsupported: true);
      return;
    }
    try {
      final paths = await client.meshPaths(token);
      Map<int, MeshRelayConfig>? relays;
      if (mesh.deviceRelayEnabled) {
        final list = await client.meshRelays(token);
        relays = {for (final c in list) c.deviceId: c};
        for (final c in list) {
          _note(c);
        }
      }
      if (_token != token) return;
      state = state.copyWith(paths: paths, relays: relays ?? const {}, loadedAt: DateTime.now(), clearError: true, unsupported: false);
    } catch (e) {
      if (_token != token) return;
      final unsupported = e is MeshRelayApiException && e.missingEndpoint;
      if (!unsupported) commonPrint.log('喵窝中继：读主控失败 $e');
      state = state.copyWith(error: e is PanelException ? e.message : '$e', unsupported: unsupported, loadedAt: DateTime.now());
    }
  }

  /// 读一台设备的中继配置（设置页打开时）
  Future<MeshRelayConfig?> load(int deviceId) async {
    final client = ref.read(panelClientProvider);
    final token = _token;
    if (client == null || token.isEmpty) return state.relays[deviceId];
    final c = await client.meshRelay(token, deviceId);
    if (c != null && _token == token) {
      _note(c);
      state = state.copyWith(relays: {...state.relays, deviceId: c});
    }
    return c;
  }

  /// 保存（`PUT /user/mesh/devices/{id}/relay`）。出错抛 [MeshRelayApiException]；设备不在了 / 管理员关了设备中继时顺带
  /// 重查设备列表 / 主控状态。
  Future<MeshRelayConfig?> save(MeshRelayConfig config) async {
    final client = ref.read(panelClientProvider);
    final token = _token;
    if (client == null || token.isEmpty) throw const PanelException('没有登录主控');
    try {
      final c = await client.meshSetRelay(token, config);
      if (c != null && _token == token) {
        // 刚保存的开启：从现在算 pending
        if (c.enabled && c.state == MeshRelayState.pending) _pendingSince[c.deviceId] = DateTime.now();
        _note(c);
        state = state.copyWith(relays: {...state.relays, c.deviceId: c});
      }
      unawaited(refresh(force: true));
      return c;
    } on MeshRelayApiException catch (e) {
      if (e.code == 'device_not_found' || e.code == 'device_relay_disabled') {
        unawaited(ref.read(meshProvider.notifier).refresh());
      }
      rethrow;
    }
  }
}

final meshRelayProvider = NotifierProvider<MeshRelayController, MeshRelayViewState>(MeshRelayController.new);
