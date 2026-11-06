import 'dart:async';
import 'dart:io';

import 'package:bett_box/clash/clash.dart';
import 'package:bett_box/common/common.dart';
import 'package:bett_box/models/models.dart';
import 'package:bett_box/providers/providers.dart';
import 'package:bett_box/state.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../config/mesh_config.dart';
import '../panel/account.dart';
import '../panel/client.dart';
import '../panel/mesh.dart';
import 'meow_settings.dart';
import 'status.dart';

export '../config/mesh_config.dart' show NetworkingMode, meshOutboundName;
export '../panel/mesh.dart' show MeshDevice, MeshSite;

/// 喵窝的运行时数据（不落盘）。生成运行配置的 `patchRawConfig` 在 globalState 里跑、拿不到 Riverpod，经这里取。
///
/// - 入网 key：一次性、10 分钟过期，只在内存里；这台设备登记成功（状态文件里有了设备编号）就丢掉，
///   之后生成的配置不再带它（设备密钥已在状态目录里）。
/// - 本机 IPv4：判断站点网段和当前所在网络重叠（重叠的这次不接入，本地优先）。
/// 安卓的服务 isolate（磁贴 / 开机快速启动）里这些都是空的：不带 key、不判重叠，登记过的设备照常上线。
class MeshRuntime {
  /// 主控签的 key 10 分钟过期，留一分钟余量
  static const keyTtl = Duration(minutes: 9);

  String? _authKey;
  DateTime? _authKeyAt;

  String? get authKey {
    final at = _authKeyAt;
    if (_authKey == null || at == null || DateTime.now().difference(at) >= keyTtl) return null;
    return _authKey;
  }

  void setAuthKey(String? key) {
    _authKey = key;
    _authKeyAt = key == null ? null : DateTime.now();
  }

  List<String> localIPv4s = const [];

  /// 当前订阅（去掉之前）里的 Tailscale 组网节点名：「组网」页据此判断 Tailscale 那一项可不可选
  final subscriptionNodes = ValueNotifier<List<String>>(const []);

  /// 每生成一份带喵窝节点的运行配置（当前订阅）加一：内核的 tailscale 出站是懒启动的（第一次有连接才连控制服务器），
  /// MeshController 据此在配置生效后「叫醒」它一次，设备才会上线、别的设备才连得进来
  final epoch = ValueNotifier<int>(0);

  MeshInjection? injection(MeowSettings meow) {
    final m = meow.mesh;
    if (!m.enabled || m.controlUrl.isEmpty) return null;
    return MeshInjection(
      controlUrl: m.controlUrl,
      hostname: m.hostname.isEmpty ? meshHostname('', fallback: _fallbackHostname) : m.hostname,
      magicDns: m.magicDns,
      sites: meshActiveSites(m.routes, localIPv4s),
      authKey: authKey,
    );
  }
}

String get _fallbackHostname => Platform.isAndroid ? 'meowx-android' : 'meowx-windows';

final meshRuntime = MeshRuntime();

/// `patchRawConfig`（lib/state.dart）末尾调：按「组网」改写运行配置——去掉订阅里的组网节点（喵窝开着 / 选了关闭时）、
/// 注入喵窝节点。返回改写后的订阅规则与要排在整张规则表最前面的规则。[current] = 生成的是当前订阅（不是导出 / 预览别的档）。
({List<dynamic> rules, List<String> prepend}) applyNetworkingToConfig(
  Map<String, dynamic> rawConfig,
  List<dynamic> rules,
  MeowSettings meow, {
  required bool current,
}) {
  final mesh = meshRuntime.injection(meow);
  final patch = applyMeowNetworking(rawConfig, rules, stripTailscale: stripsSubscriptionTailscale(meow), mesh: mesh);
  if (current) {
    if (!listEquals(meshRuntime.subscriptionNodes.value, patch.subscriptionTailscaleNodes)) {
      meshRuntime.subscriptionNodes.value = patch.subscriptionTailscaleNodes;
    }
    if (mesh != null) meshRuntime.epoch.value++;
  }
  if (patch.removed.isNotEmpty) commonPrint.log('组网：运行配置去掉了节点 ${patch.removed.join(', ')}');
  return (rules: patch.rules, prepend: patch.prependRules);
}

/// 当前订阅里的 Tailscale 组网节点名（应用配置时记下的）。
final subscriptionTailscaleNodesProvider = Provider<List<String>>((ref) {
  void changed() => ref.invalidateSelf();
  meshRuntime.subscriptionNodes.addListener(changed);
  ref.onDispose(() => meshRuntime.subscriptionNodes.removeListener(changed));
  return meshRuntime.subscriptionNodes.value;
});

/// 本机当前的 IPv4（判断站点网段重叠用，MeshController 在网络变化时更新）。
final meshLocalIPv4sProvider = StateProvider<List<String>>((ref) => const []);

/// 喵窝开着时要进 TUN 的网段（设备地址段 + 这次接入的站点网段）：Bettbox 的 updateParams 据此调整 TUN 路由
/// （安卓「绕过私有网络」时补进路由、桌面从排除的私网段里挖掉），站点网段才进得了隧道。
final meshTunRoutesProvider = Provider<List<String>>(
  (ref) => meshTunRoutes(ref.watch(meowSettingProvider.select((s) => s.mesh)), ref.watch(meshLocalIPv4sProvider)),
);

/// 按喵窝网段调整 TUN 路由（Bettbox 的 updateParams 用；生成运行配置时 applyMeowNetworking 对 tun 段做同样的事）。
Tun meshAdjustTun(Tun tun, List<String> meshRoutes) {
  if (meshRoutes.isEmpty) return tun;
  final r = meshAdjustRoutes(tun.routeAddress, tun.routeExcludeAddress, meshRoutes);
  return tun.copyWith(routeAddress: r.routeAddress, routeExcludeAddress: r.routeExclude);
}

/// 现在「组网」选的是哪个。
final networkingModeProvider = Provider<NetworkingMode>((ref) {
  final s = ref.watch(meowSettingProvider.select((s) => (s.mesh.enabled, s.tailscaleNodes)));
  final has = ref.watch(subscriptionTailscaleNodesProvider).isNotEmpty;
  if (s.$1) return NetworkingMode.mesh;
  if (has && s.$2) return NetworkingMode.tailscale;
  return NetworkingMode.off;
});

enum MeshAvailability {
  /// 还没问过主控（没登录 / 刚启动）
  unknown,
  available,
  notAdmin,

  /// 主控没开喵窝 / 还在启动（带主控给的说明）
  unavailable,
}

MeshAvailability meshAvailabilityOf(String? reason) => switch (reason) {
  null => MeshAvailability.unknown,
  '' => MeshAvailability.available,
  'not_admin' => MeshAvailability.notAdmin,
  _ => MeshAvailability.unavailable,
};

/// 主控不可用原因码 → 给人看的话（主控给了说明就用它）。
String meshReasonText(String reason, String message) {
  if (message.isNotEmpty) return message;
  return switch (reason) {
    'disabled' => '主控没有开启喵窝',
    'starting' => '主控的喵窝正在启动',
    'not_admin' => '只有管理员账号可以使用',
    _ => '主控暂不可用（$reason）',
  };
}

/// 喵窝此刻在哪一步（首页卡片 / 「组网」页的状态行）。
enum MeshPhase {
  off,

  /// 开着、但代理没在跑：连上之后入网
  idle,

  /// 正在向主控申请入网 key
  enrolling,

  /// 拿到 key、等这台设备在控制服务器上登记
  joining,

  /// 登记过了、主控还没看到它在线
  connecting,
  connected,
  failed,
}

class MeshState {
  const MeshState({
    this.availability = MeshAvailability.unknown,
    this.message = '',
    this.devices = const [],
    this.sites = const [],
    this.devicesComplete = false,
    this.devicesAt,
    this.stateNodeId,
    this.stateNodeIdAt,
    this.busy = false,
    this.enrolling = false,
    this.error,
  });

  final MeshAvailability availability;

  /// 不可用时主控的说明
  final String message;
  final List<MeshDevice> devices;
  final List<MeshSite> sites;

  /// 设备列表是主控完整给出的（Headscale 出错时主控只回一部分，不能据此判断「这台设备被删了」）
  final bool devicesComplete;
  final DateTime? devicesAt;

  /// 状态目录里这台设备在控制服务器上的编号（= 主控设备 ID）；没登记过为 null
  final int? stateNodeId;

  /// [stateNodeId] 变成现在这个值的时刻
  final DateTime? stateNodeIdAt;
  final bool busy;
  final bool enrolling;

  /// 最近一次出错（入网 / 问主控）
  final String? error;

  /// 本机这台（状态文件里的编号，拿不到时用上次记下的）
  MeshDevice? selfDevice(int? fallbackId) {
    final id = stateNodeId ?? fallbackId;
    if (id == null) return null;
    for (final d in devices) {
      if (d.id == id) return d;
    }
    return null;
  }

  /// 除本机外在线的设备数
  int onlineOthers(int? fallbackId) {
    final self = selfDevice(fallbackId);
    return devices.where((d) => d.online && d.id != self?.id).length;
  }

  /// 状态文件里的设备在主控里已经没有了（被删了）：要重新入网。要设备列表是在看到这个编号 5 秒以后、完整拿到的才算，
  /// 免得刚登记、列表还是旧的时候误判（误判会让主控删掉刚登记的设备）
  bool get stateNodeDeleted {
    final id = stateNodeId, at = devicesAt, since = stateNodeIdAt;
    if (id == null || at == null || since == null || !devicesComplete) return false;
    if (at.difference(since) < const Duration(seconds: 5)) return false;
    return !devices.any((d) => d.id == id);
  }

  MeshState copyWith({
    MeshAvailability? availability,
    String? message,
    List<MeshDevice>? devices,
    List<MeshSite>? sites,
    bool? devicesComplete,
    DateTime? devicesAt,
    int? stateNodeId,
    bool clearStateNodeId = false,
    DateTime? stateNodeIdAt,
    bool? busy,
    bool? enrolling,
    String? error,
    bool clearError = false,
  }) => MeshState(
    availability: availability ?? this.availability,
    message: message ?? this.message,
    devices: devices ?? this.devices,
    sites: sites ?? this.sites,
    devicesComplete: devicesComplete ?? this.devicesComplete,
    devicesAt: devicesAt ?? this.devicesAt,
    stateNodeId: clearStateNodeId ? null : (stateNodeId ?? this.stateNodeId),
    stateNodeIdAt: clearStateNodeId ? null : (stateNodeIdAt ?? this.stateNodeIdAt),
    busy: busy ?? this.busy,
    enrolling: enrolling ?? this.enrolling,
    error: clearError ? null : (error ?? this.error),
  );
}

/// 喵窝的阶段：只看开关、代理在不在跑与主控 / 状态文件的情况。
MeshPhase meshPhase({required bool enabled, required bool running, required MeshState state, int? fallbackId}) {
  if (!enabled) return MeshPhase.off;
  if (!running) return MeshPhase.idle;
  if (state.enrolling) return MeshPhase.enrolling;
  final self = state.selfDevice(fallbackId);
  if (self != null && self.online) return MeshPhase.connected;
  if (state.error != null) return MeshPhase.failed;
  if (state.stateNodeId == null) return MeshPhase.joining;
  return MeshPhase.connecting;
}

/// 一行状态（首页卡片、「我的」里「组网」行的行尾）。
String meshPhaseText(MeshPhase phase, MeshState state, {int? fallbackId}) => switch (phase) {
  MeshPhase.off => state.availability == MeshAvailability.unavailable
      ? (state.message.isEmpty ? '主控没有开启喵窝' : state.message)
      : '关闭',
  MeshPhase.idle => '已打开 · 连接后入网',
  MeshPhase.enrolling => '正在向主控申请入网…',
  MeshPhase.joining => '正在入网…',
  MeshPhase.connecting => '连接中…',
  MeshPhase.connected => switch (state.onlineOthers(fallbackId)) {
    0 => '已连接',
    final n => '已连接 · $n 台在线',
  },
  MeshPhase.failed => '失败：${state.error}',
};

/// 喵窝（Design/meshnet.md §8）：问主控能不能用（只给管理员）、开关、入网、设备与站点、退出。
///
/// - 开关 = `MeowSettings.mesh`（控制地址 + MagicDNS 后缀 + 站点网段，不含密钥），生成运行配置时注入「喵窝」节点；
///   开 / 关、站点网段变了都要重新应用配置（代理在跑时）。
/// - 入网 key：这台设备还没登记（状态目录里没有设备编号）或在主控被删了时，经加密通道现签一把一次性 key，
///   放进下一份运行配置；登记成功就丢。登记过的设备重连只靠状态目录里的设备密钥。
/// - 内核的 tailscale 出站懒启动：每份带喵窝的配置生效后叫醒它一次（拿它测一次延迟），设备才上线。
/// - 状态：内核不对外给 tailnet 状态，「已连接」看主控设备列表里本机在不在线，本机编号从 tsnet 的状态文件读。
///   只在页面 / 首页卡片看得见、App 在前台时问主控（[tick]），不在后台定时联网。
class MeshController extends Notifier<MeshState> {
  /// 叫醒用的地址：随便一个喵窝里的地址（结果不重要，tailscale 出站收到连接就会启动）
  static const _wakeUrl = 'http://100.100.100.100/';

  /// 配置生效、旧节点被回收（内核按 GC 关掉过期的出站）之后再叫醒，免得新旧两个节点同时拿着同一份设备密钥上线
  static const _wakeDelay = Duration(seconds: 5);

  DateTime? _lastEnrollAt;
  DateTime? _statusAt;
  Future<void>? _refreshing;
  Timer? _wakeTimer;
  Timer? _fastTimer;
  DateTime? _fastUntil;
  Timer? _localDebounce;
  StreamSubscription<List<ConnectivityResult>>? _connSub;

  MeowMesh get _mesh => ref.read(meowSettingProvider).mesh;
  bool get _running => ref.read(isRunningProvider);
  String get _token => ref.read(meowSettingProvider).account.token;

  void _updateMesh(MeowMesh Function(MeowMesh m) f) {
    final notifier = ref.read(meowSettingProvider.notifier);
    final before = ref.read(meowSettingProvider);
    final after = f(before.mesh);
    if (after != before.mesh) notifier.updateState((s) => s.copyWith(mesh: after));
  }

  @override
  MeshState build() {
    final m = ref.read(meowSettingProvider).mesh;
    ref.listen<bool>(isRunningProvider, (prev, next) {
      if (next && prev != true) {
        unawaited(_refreshLocal());
        _scheduleWake();
      }
    });
    ref.listen<String>(meowSettingProvider.select((s) => s.account.token), (prev, next) {
      if (next.isNotEmpty && next != prev && ref.read(initProvider)) unawaited(refresh());
    });
    ref.listen<bool>(initProvider, (prev, next) {
      if (next && prev != true && _token.isNotEmpty) unawaited(refresh());
    });
    ref.listen<bool>(meowSettingProvider.select((s) => s.mesh.enabled), (_, on) => _syncWatchers(on));
    meshRuntime.epoch.addListener(_scheduleWake);
    ref.onDispose(() {
      meshRuntime.epoch.removeListener(_scheduleWake);
      _wakeTimer?.cancel();
      _fastTimer?.cancel();
      _localDebounce?.cancel();
      unawaited(_connSub?.cancel());
    });
    Future.microtask(() => _syncWatchers(_mesh.enabled));
    return MeshState(availability: meshAvailabilityOf(m.panelReason), message: m.panelMessage);
  }

  // ---------------------------------------------------------------------------------------------------------------
  // 主控

  /// 问主控能不能用，能用就顺带拉设备与站点（开着时把控制地址 / 站点网段写回设置）。并发调用合成一次。
  Future<void> refresh() => _refreshing ??= _refresh().whenComplete(() => _refreshing = null);

  Future<void> _refresh() async {
    final token = _token;
    final client = ref.read(panelClientProvider);
    if (token.isEmpty || client == null) {
      state = state.copyWith(availability: MeshAvailability.unknown);
      return;
    }
    final MeshPanelStatus status;
    try {
      status = await client.meshStatus(token);
    } catch (e) {
      commonPrint.log('喵窝：问主控失败 $e');
      if (_mesh.enabled) state = state.copyWith(error: _message(e));
      return;
    }
    if (_token != token) return;
    _statusAt = DateTime.now();
    if (!status.available) {
      state = state.copyWith(
        availability: meshAvailabilityOf(status.reason),
        message: meshReasonText(status.reason, status.message),
        devices: const [],
        sites: const [],
        devicesComplete: false,
      );
      _updateMesh((m) => m.copyWith(panelReason: status.reason, panelMessage: status.message));
      return;
    }
    state = state.copyWith(availability: MeshAvailability.available, message: '');
    final before = _mesh;
    _updateMesh(
      (m) => m.copyWith(
        panelReason: '',
        panelMessage: '',
        controlUrl: m.enabled && status.controlUrl.isNotEmpty ? status.controlUrl : m.controlUrl,
        magicDns: m.enabled ? status.magicDns : m.magicDns,
      ),
    );
    final changed = before.enabled && (_mesh.controlUrl != before.controlUrl || _mesh.magicDns != before.magicDns);
    _lastStatus = status;
    await _refreshDevices(client, token, reapplyIfChanged: changed);
  }

  MeshPanelStatus? _lastStatus;

  Future<void> _refreshDevices(PanelClient client, String token, {bool reapplyIfChanged = false}) async {
    final MeshDeviceList list;
    try {
      list = await client.meshDevices(token);
    } catch (e) {
      commonPrint.log('喵窝：拉设备列表失败 $e');
      return;
    }
    if (_token != token) return;
    state = state.copyWith(
      devices: list.devices,
      sites: list.sites,
      devicesComplete: list.complete,
      devicesAt: DateTime.now(),
    );
    var changed = reapplyIfChanged;
    if (_mesh.enabled && list.complete) {
      final routes = [for (final s in list.sites) s.advertised];
      if (!listEquals(routes, _mesh.routes)) {
        _updateMesh((m) => m.copyWith(routes: routes));
        changed = true;
      }
    }
    final self = state.selfDevice(null);
    if (self != null && self.id != _mesh.nodeId) _updateMesh((m) => m.copyWith(nodeId: self.id));
    if (changed && _mesh.enabled) _reapplyLater('控制地址 / 站点网段有变化');
  }

  /// 页面 / 首页卡片看得见时定期调：读状态文件；离上次问主控超过 [devicesEvery] 就再问一次；该入网就入网。
  /// App 在后台时不问主控。
  Future<void> tick({Duration devicesEvery = const Duration(seconds: 30)}) async {
    await _readStateFile();
    final foreground = WidgetsBinding.instance.lifecycleState == null ||
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
    if (!foreground || _token.isEmpty) return;
    final at = state.devicesAt;
    final statusStale = _statusAt == null || DateTime.now().difference(_statusAt!) > const Duration(minutes: 5);
    if (statusStale || state.availability != MeshAvailability.available) {
      await refresh();
    } else if (at == null || DateTime.now().difference(at) >= devicesEvery) {
      final client = ref.read(panelClientProvider);
      if (client != null) await _refreshDevices(client, _token);
    }
    await _maybeEnroll();
  }

  // ---------------------------------------------------------------------------------------------------------------
  // 开关

  /// 打开 / 关掉。开：主控得说可用；这台设备没登记过（或在主控被删了）就先要一把入网 key，再写设置。
  /// 关：删设置（设备留在主控里，再打开直接上线）。[apply] = 代理在跑时重新应用配置（「组网」切换时调用方自己统一应用一次）。
  /// 返回是否已经是想要的状态。
  Future<bool> setEnabled(bool on, {bool apply = true}) async {
    if (state.busy) return false;
    if (on == _mesh.enabled) return true;
    state = state.copyWith(busy: true, clearError: true);
    try {
      if (on) {
        await refresh();
        if (state.availability != MeshAvailability.available) {
          state = state.copyWith(error: state.availability == MeshAvailability.unavailable ? state.message : (state.error ?? '主控没有开放喵窝'));
          return false;
        }
        final status = _lastStatus;
        await _readStateFile();
        // 喵窝关着、节点不在跑，状态文件不会正好在这时更新：设备列表完整、里面没有它就是被删了
        final stale = state.stateNodeId != null && state.devicesComplete && !state.devices.any((d) => d.id == state.stateNodeId);
        final previous = stale ? state.stateNodeId : _mesh.nodeId;
        if (stale) {
          // 设备在主控里已经删了（退出过喵窝 / 管理员删的）：状态目录里的设备密钥没用了，清掉重新入网（喵窝关着，节点早已不在）
          await _deleteStateDir();
          state = state.copyWith(clearStateNodeId: true);
        }
        final hostname = _mesh.hostname.isNotEmpty ? _mesh.hostname : await _deviceHostname();
        if (state.stateNodeId == null && meshRuntime.authKey == null) {
          final ok = await _enroll(hostname: hostname, previous: previous, force: true);
          if (!ok) return false;
        }
        _updateMesh(
          (m) => m.copyWith(
            enabled: true,
            hostname: hostname,
            controlUrl: (status?.controlUrl ?? '').isNotEmpty ? status!.controlUrl : m.controlUrl,
            magicDns: status?.magicDns ?? m.magicDns,
            routes: [for (final s in state.sites) s.advertised],
          ),
        );
        if (_mesh.controlUrl.isEmpty) {
          _updateMesh((m) => m.copyWith(enabled: false));
          state = state.copyWith(error: '主控没有给出控制地址');
          return false;
        }
        commonPrint.log('喵窝：打开（${state.sites.length} 个站点）');
        unawaited(_refreshLocal());
      } else {
        _updateMesh((m) => m.copyWith(enabled: false));
        meshRuntime.setAuthKey(null);
        commonPrint.log('喵窝：关闭');
      }
      if (apply) await _apply();
      return true;
    } finally {
      state = state.copyWith(busy: false);
    }
  }

  /// 切换「组网」：先把两边的开关写好，代理在跑时只重新应用一次配置。切到喵窝失败（主控不可用、入网失败）时原样不动。
  Future<bool> setMode(NetworkingMode mode) async {
    final meow = ref.read(meowSettingProvider);
    if (mode == ref.read(networkingModeProvider)) return true;
    final previousTs = meow.tailscaleNodes;
    void setTs(bool on) => ref.read(meowSettingProvider.notifier).updateState((s) => s.copyWith(tailscaleNodes: on));
    switch (mode) {
      case NetworkingMode.mesh:
        setTs(false);
        if (!await setEnabled(true, apply: false)) {
          setTs(previousTs);
          return false;
        }
      case NetworkingMode.tailscale:
        if (_mesh.enabled && !await setEnabled(false, apply: false)) return false;
        setTs(true);
      case NetworkingMode.off:
        if (_mesh.enabled && !await setEnabled(false, apply: false)) return false;
        setTs(false);
    }
    commonPrint.log('组网切到 ${mode.name}');
    await _apply();
    return true;
  }

  /// 退出喵窝：从主控删掉这台设备，再关掉开关（下次打开是新设备，重新入网）。
  Future<void> leave() async {
    if (state.busy) return;
    final id = state.stateNodeId ?? _mesh.nodeId ?? state.selfDevice(null)?.id;
    final client = ref.read(panelClientProvider);
    if (id != null && client != null && _token.isNotEmpty) {
      state = state.copyWith(busy: true, clearError: true);
      try {
        await client.meshDeleteDevice(_token, id);
        commonPrint.log('喵窝：已从主控删除这台设备（$id）');
      } catch (e) {
        // 设备已经不在了照样往下走；别的错（连不上主控）停在这里，让用户重试
        if (!_message(e).contains('不存在')) {
          state = state.copyWith(busy: false, error: _message(e));
          return;
        }
      }
      state = state.copyWith(busy: false);
    }
    _updateMesh((m) => m.copyWith(nodeId: null));
    // 喵窝开着时由「组网」统一切到关闭（订阅组网节点也保持关），只重新应用一次
    await setMode(NetworkingMode.off);
    await refresh();
  }

  /// 退出登录：喵窝跟着账号走，关掉（设备留在主控里，换回这个账号再打开直接上线）。
  void accountLoggedOut() {
    meshRuntime.setAuthKey(null);
    final wasOn = _mesh.enabled;
    state = const MeshState();
    _statusAt = null;
    _lastStatus = null;
    _updateMesh((m) => m.copyWith(enabled: false, panelReason: null, panelMessage: ''));
    if (wasOn) _reapplyLater('退出登录，关掉喵窝');
  }

  // ---------------------------------------------------------------------------------------------------------------
  // 入网与叫醒

  /// 开着、代理在跑、这台设备还没登记（或在主控被删了）、手上也没有 key：要一把，并重新应用配置
  Future<void> _maybeEnroll() async {
    if (!_mesh.enabled || _mesh.controlUrl.isEmpty || !_running || state.busy) return;
    if (meshRuntime.authKey != null) return;
    final deleted = state.stateNodeDeleted;
    if (state.stateNodeId != null && !deleted) return;
    final ok = await _enroll(hostname: _mesh.hostname.isEmpty ? await _deviceHostname() : _mesh.hostname, previous: deleted ? state.stateNodeId : _mesh.nodeId);
    if (ok) await _apply();
  }

  /// 向主控要一把一次性入网 key（自动的 30 秒内最多一次，用户点的 10 秒；主控那边每个账号每分钟限 5 次）
  Future<bool> _enroll({required String hostname, int? previous, bool force = false}) async {
    if (state.enrolling) return false;
    final last = _lastEnrollAt;
    if (last != null && DateTime.now().difference(last) < Duration(seconds: force ? 10 : 30)) return false;
    final client = ref.read(panelClientProvider);
    final token = _token;
    if (client == null || token.isEmpty) return false;
    _lastEnrollAt = DateTime.now();
    state = state.copyWith(enrolling: true, clearError: true);
    try {
      final r = await client.meshEnroll(
        token,
        hostname: hostname,
        os: Platform.isAndroid ? 'Android' : 'Windows',
        version: _appVersion,
        previousNodeId: previous,
      );
      meshRuntime.setAuthKey(r.authKey);
      _updateMesh(
        (m) => m.copyWith(
          hostname: hostname,
          controlUrl: r.controlUrl.isNotEmpty ? r.controlUrl : m.controlUrl,
          magicDns: r.magicDns.isNotEmpty ? r.magicDns : m.magicDns,
          routes: r.sites.isEmpty ? m.routes : [for (final s in r.sites) s.advertised],
        ),
      );
      if (r.sites.isNotEmpty) state = state.copyWith(sites: r.sites);
      commonPrint.log('喵窝：已申请入网 key');
      _startFast();
      return true;
    } catch (e) {
      commonPrint.log('喵窝：申请入网失败 $e');
      state = state.copyWith(error: _message(e));
      return false;
    } finally {
      state = state.copyWith(enrolling: false);
    }
  }

  /// 重新应用配置。代理没在跑时也要应用：Bettbox 点连接时只在订阅档改过时才重新生成配置，
  /// 不应用的话下次连接用的还是打开喵窝之前的那份（没有喵窝节点）
  Future<void> _apply() async {
    try {
      await globalState.appController.applyProfile(silence: true);
    } catch (e) {
      commonPrint.log('喵窝：重新应用配置失败 $e');
    }
    if (_running) _startFast();
  }

  /// 设置变了、要重新生成配置（合并成一次；App 还没初始化完时不动，初始化时自己会生成）
  void _reapplyLater(String why) {
    if (!ref.read(initProvider)) return;
    commonPrint.log('喵窝：$why，重新应用配置');
    globalState.appController.applyProfileDebounce(silence: true);
  }

  void _scheduleWake() {
    if (!_mesh.enabled) return;
    _wakeTimer?.cancel();
    _wakeTimer = Timer(_wakeDelay, () => unawaited(_wake()));
  }

  Future<void> _wake() async {
    if (!_mesh.enabled || !_running) return;
    try {
      final d = await clashCore.getDelay(_wakeUrl, meshOutboundName);
      commonPrint.log('喵窝：叫醒节点（${d.value}）');
    } catch (e) {
      commonPrint.log('喵窝：叫醒节点失败 $e');
    }
    _startFast();
  }

  /// 打开 / 入网 / 重新应用之后的 90 秒里每 3 秒看一次状态文件与主控（捕捉登记成功、上线），之后停
  void _startFast() {
    _fastUntil = DateTime.now().add(const Duration(seconds: 90));
    _fastTimer ??= Timer.periodic(const Duration(seconds: 3), (_) {
      final until = _fastUntil;
      if (until == null || DateTime.now().isAfter(until) || !_mesh.enabled) {
        _fastTimer?.cancel();
        _fastTimer = null;
        return;
      }
      unawaited(tick(devicesEvery: const Duration(seconds: 6)));
    });
  }

  // ---------------------------------------------------------------------------------------------------------------
  // 状态文件与本机网络

  Future<String> _stateDirPath() async => p.join(await appPath.homeDirPath, meshStateDir);

  Future<void> _readStateFile() async {
    int? id;
    try {
      final f = File(p.join(await _stateDirPath(), meshStateFile));
      if (await f.exists()) id = meshNodeIdFromState(await f.readAsString());
    } catch (_) {}
    if (id == state.stateNodeId) return;
    state = id == null ? state.copyWith(clearStateNodeId: true) : state.copyWith(stateNodeId: id, stateNodeIdAt: DateTime.now());
    if (id != null) {
      // 登记成功：key 用过了，之后的配置不再带它；记下编号（重新入网时让主控删掉旧的）
      if (meshRuntime.authKey != null) {
        meshRuntime.setAuthKey(null);
        commonPrint.log('喵窝：这台设备已登记（$id）');
      }
      if (id != _mesh.nodeId) _updateMesh((m) => m.copyWith(nodeId: id));
    }
  }

  Future<void> _deleteStateDir() async {
    try {
      final dir = Directory(await _stateDirPath());
      if (await dir.exists()) await dir.delete(recursive: true);
    } catch (e) {
      commonPrint.log('喵窝：清理状态目录失败 $e');
    }
  }

  void _syncWatchers(bool on) {
    if (!on) {
      unawaited(_connSub?.cancel());
      _connSub = null;
      return;
    }
    unawaited(_refreshLocal());
    try {
      _connSub ??= Connectivity().onConnectivityChanged.listen(
        (_) {
          _localDebounce?.cancel();
          _localDebounce = Timer(const Duration(seconds: 3), () => unawaited(_refreshLocal()));
        },
        onError: (Object e) => commonPrint.log('喵窝：网络变化监听出错 $e'),
      );
    } catch (e) {
      commonPrint.log('喵窝：监听网络变化失败 $e');
    }
  }

  static bool _virtualInterface(String name) {
    final n = name.toLowerCase();
    return const ['tun', 'vpn', 'tap', 'ppp', 'meowx', 'wintun', 'tailscale', 'utun', 'wg'].any(n.contains);
  }

  /// 本机物理网卡的 IPv4（不含隧道 / 虚拟网卡、喵窝与 fake-ip 地址）。站点网段和它们重叠的这次不接入；变了就重新应用配置
  Future<void> _refreshLocal() async {
    if (!_mesh.enabled) return;
    final List<String> ips;
    try {
      final list = await NetworkInterface.list(includeLoopback: false, type: InternetAddressType.IPv4);
      final mesh = Ipv4Cidr.parse(meshDeviceCidr)!, fake = Ipv4Cidr.parse('198.18.0.0/15')!;
      ips = [
        for (final iface in list)
          if (!_virtualInterface(iface.name))
            for (final a in iface.addresses)
              if (parseIpv4(a.address) case final v? when !mesh.contains(v) && !fake.contains(v)) a.address,
      ]..sort();
    } catch (e) {
      commonPrint.log('喵窝：读本机网卡失败 $e');
      return;
    }
    if (listEquals(ips, meshRuntime.localIPv4s)) return;
    final before = meshActiveSites(_mesh.routes, meshRuntime.localIPv4s);
    meshRuntime.localIPv4s = ips;
    ref.read(meshLocalIPv4sProvider.notifier).state = ips;
    final after = meshActiveSites(_mesh.routes, ips);
    if (!listEquals(before, after)) _reapplyLater('接入的站点网段变了（${after.join(', ')}）');
  }

  // ---------------------------------------------------------------------------------------------------------------

  static String get _appVersion {
    try {
      return globalState.packageInfo.version;
    } catch (_) {
      return '';
    }
  }

  /// 设备名：安卓取机型、Windows 取计算机名，规范化后报给控制服务器
  static Future<String> _deviceHostname() async {
    var raw = '';
    try {
      if (Platform.isAndroid) {
        raw = (await DeviceInfoPlugin().androidInfo).model;
      } else {
        raw = Platform.localHostname;
      }
    } catch (_) {}
    return meshHostname(raw, fallback: _fallbackHostname);
  }

  static String _message(Object e) => e is PanelException ? e.message : e.toString();
}

final meshProvider = NotifierProvider<MeshController, MeshState>(MeshController.new);

/// 「组网」里显不显示喵窝：登录的是管理员（主控说过可用 / 没开），或者已经开着。
final meshVisibleProvider = Provider<bool>((ref) {
  final availability = ref.watch(meshProvider.select((s) => s.availability));
  final s = ref.watch(meowSettingProvider.select((s) => (s.mesh.enabled, s.account.token.isNotEmpty)));
  return s.$1 || (s.$2 && (availability == MeshAvailability.available || availability == MeshAvailability.unavailable));
});

/// 「组网」入口要不要列出：喵窝可见，或订阅里有组网节点，或现在开着一个。
final networkingEntryVisibleProvider = Provider<bool>(
  (ref) =>
      ref.watch(meshVisibleProvider) ||
      ref.watch(subscriptionTailscaleNodesProvider).isNotEmpty ||
      ref.watch(networkingModeProvider) != NetworkingMode.off,
);
