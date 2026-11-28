import 'dart:async';

import 'package:bett_box/common/common.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../panel/account.dart';
import '../panel/mesh.dart';
import 'mesh.dart';
import 'meow_settings.dart';
import 'status.dart';
import 'tailscale_status.dart';

// 喵窝路径上报（Design/mesh-peer-relay.md §2.2 / §2.3；接口稿 POST /user/mesh/paths）：本机到各对端走的是直连、
// 设备中继还是中继服务器，报给主控汇总，别的设备与 po0 那一端据此显示「经哪台中继」。

/// 近这么久里握过手（或收发字节比上次上报多）的对端才报
const meshPathActiveWindow = Duration(minutes: 5);

/// §2.2：从内核里的一个对端算出上报项。顺序：设备中继 > 直连 > 中继服务器（区域代码）；都没有、或对端没有喵窝 IPv4 → null（不报）。
MeshPathPeer? meshPathPeerOf(TsPeer p) {
  final ip = p.addresses.where((a) => !a.contains(':')).firstOrNull ?? '';
  if (ip.isEmpty) return null;
  final common = (rx: p.rxBytes, tx: p.txBytes, hs: p.lastHandshake);
  if (p.peerRelay.isNotEmpty) {
    return MeshPathPeer(ip: ip, path: 'peer_relay', peerRelay: p.peerRelay, rxBytes: common.rx, txBytes: common.tx, lastHandshake: common.hs);
  }
  if (p.curAddr.isNotEmpty) {
    return MeshPathPeer(ip: ip, path: 'direct', endpoint: p.curAddr, rxBytes: common.rx, txBytes: common.tx, lastHandshake: common.hs);
  }
  if (p.relay.isNotEmpty) {
    return MeshPathPeer(ip: ip, path: 'derp', derpRegion: p.relay, rxBytes: common.rx, txBytes: common.tx, lastHandshake: common.hs);
  }
  return null;
}

/// 上一次**成功**上报时记下的东西。
@immutable
class MeshPathMemory {
  const MeshPathMemory({this.bytes = const {}, this.signature = '', this.hadPeers = false});

  /// 各对端（按喵窝 IPv4）当时的收 / 发字节数：判断「比上次上报有增长」
  final Map<String, ({int rx, int tx})> bytes;

  /// 当时报的各对端路径（排好序的 ip + 路径键）：判断「路径变了」
  final String signature;

  /// 当时报的不是空列表
  final bool hadPeers;
}

/// 这一刻该报什么。
@immutable
class MeshPathPlan {
  const MeshPathPlan({required this.peers, required this.signature, required this.bytes});

  /// 有活动、且能判出路径的对端
  final List<MeshPathPeer> peers;
  final String signature;

  /// 这一刻全部对端的计数（报成功后记进 [MeshPathMemory]）
  final Map<String, ({int rx, int tx})> bytes;

  /// 要不要发：有活动对端就发；没有时只在「从有到无」那一次发一份空列表，之后不发
  bool shouldSend(MeshPathMemory last) => peers.isNotEmpty || last.hadPeers;

  /// 和上次报的比，路径变了（某个对端的路径 / 中继地址变了，或者有对端加入 / 退出活动列表）
  bool pathChanged(MeshPathMemory last) => signature != last.signature;

  MeshPathMemory remember() => MeshPathMemory(bytes: bytes, signature: signature, hadPeers: peers.isNotEmpty);
}

/// §2.3：按内核里的对端与上次上报算这一刻的计划。
MeshPathPlan meshPathPlan(List<TsPeer> peers, {required MeshPathMemory last, required DateTime now}) {
  final out = <MeshPathPeer>[];
  final bytes = <String, ({int rx, int tx})>{};
  for (final p in peers) {
    final item = meshPathPeerOf(p);
    final ip = item?.ip ?? p.addresses.where((a) => !a.contains(':')).firstOrNull;
    if (ip == null || ip.isEmpty) continue;
    bytes[ip] = (rx: p.rxBytes, tx: p.txBytes);
    if (item == null) continue;
    final hs = p.lastHandshake;
    final recent = hs != null && now.difference(hs) <= meshPathActiveWindow;
    final prev = last.bytes[ip];
    // 没有上次的计数（刚启动 / 还没报过）时只看握手：内核的计数从启动起算，有流量就一定刚握过手
    final grew = prev != null && (p.rxBytes > prev.rx || p.txBytes > prev.tx);
    if (recent || grew) out.add(item);
  }
  out.sort((a, b) => a.ip.compareTo(b.ip));
  return MeshPathPlan(peers: out, signature: [for (final p in out) '${p.ip}=${p.pathKey}'].join(';'), bytes: bytes);
}

/// 定时报路径：每 [interval]（60 秒）一次；每 [checkEvery] 在本机问一次内核（不联网），路径变了就 [debounce]（5 秒）后补报；
/// 回前台、换网后补报；两次上报至少隔 [minGap]（5 秒，主控每台设备每 5 秒限一次）。失败不重试、不积压（下一轮报新状态），
/// 429 跳过这一轮。只在喵窝运行时跑（[isActive]）；Android 只有服务 isolate 时（磁贴 / 开机快速启动）不报，回前台补报。
///
/// 依赖全部经构造函数注入，方便单测；App 里由 [meshPathReporterProvider] 组装。
class MeshPathReporter {
  MeshPathReporter({
    required this.isActive,
    required this.fetch,
    required this.send,
    this.apiAvailable,
    this.connectivity,
    required this.log,
    this.interval = const Duration(seconds: 60),
    this.checkEvery = const Duration(seconds: 15),
    this.debounce = const Duration(seconds: 5),
    this.minGap = const Duration(seconds: 5),
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  /// 喵窝开着、代理在跑、登录了、主控支持设备中继（`mesh/status` 带 device_relay）
  final bool Function() isActive;

  /// 问内核喵窝节点的状态（本机 `self.id` 是上报用的设备编号）；拿不到 / 没在运行为 null
  final Future<TsStatus?> Function() fetch;

  /// 发给主控；出错抛异常（[MeshRelayApiException] 带状态码）
  final Future<void> Function(int deviceId, List<MeshPathPeer> peers) send;

  /// 主控接口能不能调（回过 404 的 1 小时内为 false）
  final bool Function()? apiAvailable;
  final Stream<List<ConnectivityResult>> Function()? connectivity;
  final void Function(String) log;

  final Duration interval;
  final Duration checkEvery;
  final Duration debounce;
  final Duration minGap;
  final DateTime Function() _now;

  MeshPathMemory _memory = const MeshPathMemory();

  /// 最近一次**发出去**的路径（不论成败）：路径变化的判断跟它比——失败后不因为「和上次成功的不一样」反复补报（不重试）
  String? _attempted;
  Timer? _periodic;
  Timer? _checker;
  Timer? _pending;
  StreamSubscription<List<ConnectivityResult>>? _connSub;
  Set<ConnectivityResult>? _lastConn;
  DateTime? _lastAttempt;
  bool _reporting = false;
  bool _again = false;
  String _lastError = '';

  MeshPathMemory get memory => _memory;
  bool get isWatching => _periodic != null;

  /// 喵窝启停 / 主控开关变了（以及启动时）调：可以报 → 起定时器，并马上看一次；否则停掉。
  void sync() {
    if (!isActive()) {
      stop();
      return;
    }
    if (_periodic != null) return;
    _periodic = Timer.periodic(interval, (_) => unawaited(report()));
    _checker = Timer.periodic(checkEvery, (_) => unawaited(check()));
    final conn = connectivity;
    if (conn != null) {
      try {
        _connSub = conn().listen((results) {
          final set = results.toSet();
          if (_lastConn != null && setEquals(set, _lastConn)) return;
          final first = _lastConn == null;
          _lastConn = set;
          if (first || results.every((r) => r == ConnectivityResult.none)) return;
          // 换网后路径要重新打通：等 [debounce] 再报
          _schedule(debounce);
        }, onError: (Object e) => log('喵窝路径：网络变化监听出错 $e'));
      } catch (e) {
        log('喵窝路径：监听网络变化失败 $e');
      }
    }
    _schedule(Duration.zero);
  }

  /// 回到前台：补报一次（受 [minGap] 约束）
  void onForeground() {
    if (isWatching) _schedule(Duration.zero);
  }

  /// 在本机看一次内核（页面上的轮询拿到的状态也可以经 [observe] 交进来）：路径变了就防抖补报
  Future<void> check() async {
    if (!isActive()) return;
    final st = await fetch();
    if (st != null) observe(st);
  }

  void observe(TsStatus st) {
    if (!isWatching || !st.running) return;
    final plan = meshPathPlan(st.peers, last: _memory, now: _now());
    if (plan.signature != (_attempted ?? _memory.signature) && plan.shouldSend(_memory)) _schedule(debounce);
  }

  void _schedule(Duration delay) {
    final p = _pending;
    if (p != null && p.isActive) return; // 已经排着一次（先到的那次不推迟：防抖的意思是变化后最多等这么久）
    _pending = Timer(delay, () {
      _pending = null;
      unawaited(report());
    });
  }

  /// 报一次（定时、补报都走这里）：在飞时合并成再报一次；离上次不到 [minGap] 就推到那时。
  Future<void> report() async {
    if (!isActive()) return;
    if (_reporting) {
      _again = true;
      return;
    }
    final last = _lastAttempt;
    if (last != null) {
      final wait = minGap - _now().difference(last);
      if (wait > Duration.zero) {
        _pending?.cancel();
        _pending = null;
        _schedule(wait);
        return;
      }
    }
    _reporting = true;
    try {
      await _reportOnce();
    } finally {
      _reporting = false;
      if (_again) {
        _again = false;
        _schedule(minGap);
      }
    }
  }

  Future<void> _reportOnce() async {
    if (apiAvailable != null && !apiAvailable!()) return;
    final st = await fetch();
    if (st == null || !st.running) return;
    final id = st.self?.id;
    if (id == null) return;
    final plan = meshPathPlan(st.peers, last: _memory, now: _now());
    if (!plan.shouldSend(_memory)) return;
    _lastAttempt = _now();
    _attempted = plan.signature;
    try {
      await send(id, plan.peers);
      _memory = plan.remember();
      if (_lastError.isNotEmpty) log('喵窝路径：上报恢复');
      _lastError = '';
    } catch (e) {
      // 不重试、不积压：下一轮按那时的状态报。429 = 主控限流，跳过这一轮
      final why = e is MeshRelayApiException && e.rateLimited ? '主控限流，跳过这一轮' : '$e';
      if (why != _lastError) log('喵窝路径：上报失败 $why');
      _lastError = why;
    }
  }

  void stop() {
    _periodic?.cancel();
    _periodic = null;
    _checker?.cancel();
    _checker = null;
    _pending?.cancel();
    _pending = null;
    unawaited(_connSub?.cancel());
    _connSub = null;
    _lastConn = null;
    _again = false;
    _attempted = null;
    // 下次开起来从头算（主控那边旧记录 3 分钟后标 stale、30 分钟后不再列出）
    _memory = const MeshPathMemory();
  }
}

/// 现在该不该报路径（[MeshPathReporter.isActive]，也是 meow_root 里监听的值）。
final meshPathReportActiveProvider = Provider<bool>((ref) {
  final enabled = ref.watch(meowSettingProvider.select((s) => s.mesh.enabled && s.account.token.isNotEmpty));
  final running = ref.watch(isRunningProvider);
  final supported = ref.watch(meshProvider.select((s) => s.availability == MeshAvailability.available && s.deviceRelay != null));
  return enabled && running && supported;
});

final meshPathReporterProvider = Provider<MeshPathReporter>((ref) {
  final reporter = MeshPathReporter(
    isActive: () => ref.read(meshPathReportActiveProvider),
    fetch: () async => (await fetchTailscaleStatus(meshOutboundName)).status,
    send: (id, peers) async {
      final client = ref.read(panelClientProvider);
      final token = ref.read(meowSettingProvider).account.token;
      if (client == null || token.isEmpty) return;
      await client.meshReportPaths(token, deviceId: id, peers: peers);
    },
    apiAvailable: () {
      final client = ref.read(panelClientProvider);
      return client != null && meshRelayApiGate.allowed(client.host);
    },
    connectivity: () => Connectivity().onConnectivityChanged,
    log: commonPrint.log,
  );
  // 回前台：从后台 / 最小化回来（hidden → inactive）
  final lifecycle = AppLifecycleListener(onShow: reporter.onForeground);
  ref.onDispose(() {
    lifecycle.dispose();
    reporter.stop();
  });
  return reporter;
});
