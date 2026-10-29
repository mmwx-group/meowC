import 'dart:async';
import 'dart:convert';

import 'package:bett_box/clash/clash.dart';
import 'package:bett_box/common/common.dart';
import 'package:bett_box/enum/enum.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../panel/ggy.dart';
import 'meow_settings.dart';

/// GGY（咕咕云）客户端 IP 加白：用本机出口 IP 打开用户填的每个 token 的白名单分享链接。
///
/// 上报由 Go 核心直连发出（与 po0 同一个 `meowPo0Report` 通道，参数带 `kind: ggy`：GET、照常校验证书），
/// 绕开 TUN / 本地混合端口——GGY 只加白「打开链接的来源 IP」，经代理发出加进去的是节点出口 IP。不加分流规则（与 po0 不同）。
/// 一切以设置里的「GGY 加白」开关（`MeowSettings.ggyEnabled`，默认关）为准，开着且至少有一个 token 时：
/// 启动后、开关刚打开、新增 token 时立刻报；网络切换时报；每 10 分钟兜底重报（调度照抄 [Po0Reporter]）。
/// 关掉或 token 删光即停。本机偏好：退出登录不清，没登录也报。
///
/// 依赖全部经构造函数注入，方便单测；App 里由 [ggyReporterProvider] 组装。
class GgyReporter {
  GgyReporter({
    required this.isEnabled,
    required this.tokens,
    required this.send,
    required this.connectivity,
    this.currentConnectivity,
    required this.log,
    this.onResults,
    this.interval = const Duration(minutes: 10),
    this.connectivityDebounce = const Duration(seconds: 3),
  });

  /// 设置开关
  final bool Function() isEnabled;

  /// 用户填的 token（每次现取）
  final List<String> Function() tokens;

  /// 交给核心直连 GET，返回核心的 JSON 数组原文
  final Future<String> Function(List<String> urls) send;

  /// 网络变化事件
  final Stream<List<ConnectivityResult>> Function() connectivity;

  /// 当前网络状态，开始监听时拿来当基线（Android 的回调会反复推同一组状态，只有变了才报）
  final Future<List<ConnectivityResult>> Function()? currentConnectivity;
  final void Function(String) log;

  /// 每个 token 最近一次的结论变了（键 = token；删掉的 token、关掉开关后都不在里面）
  final void Function(Map<String, GgyResult> results)? onResults;

  /// 定时兜底间隔
  final Duration interval;

  /// 网络变化后等路由 / DHCP 稳定再报
  final Duration connectivityDebounce;

  Map<String, GgyResult> _results = const {};
  Timer? _timer;
  StreamSubscription<List<ConnectivityResult>>? _connSub;
  Timer? _connDebounce;
  Set<ConnectivityResult>? _lastConn;
  bool _reporting = false;
  bool _reportAgain = false;

  Map<String, GgyResult> get results => _results;

  /// 定时器与网络监听是否在跑
  bool get isWatching => _timer != null;

  /// 当前要报的 token：开关关着为空
  List<String> _active() => isEnabled() ? ggyReportTokens(tokens()) : const [];

  /// 开关 / token 列表变了（以及启动时）调：开着且有 token → 起定时器与网络监听，[reportNow] 时立刻报一次；
  /// 否则停掉。删掉的 token 的结论一并丢掉。
  Future<void> sync({bool reportNow = false}) async {
    if (_active().isEmpty) {
      stop();
      return;
    }
    _record(const {});
    _ensureWatchers();
    if (reportNow) await report();
  }

  /// 把每个 token 报一次；在飞时合并成再报一次。开关关着 / 没有 token 不报。
  Future<void> report() async {
    final list = _active();
    if (list.isEmpty) return;
    if (_reporting) {
      _reportAgain = true;
      return;
    }
    _reporting = true;
    try {
      await _reportOnce(list);
    } finally {
      _reporting = false;
      if (_reportAgain) {
        _reportAgain = false;
        unawaited(report());
      }
    }
  }

  Future<void> _reportOnce(List<String> list) async {
    String raw;
    try {
      raw = await send([for (final t in list) ggyReportUrl(t)]);
    } catch (e) {
      log('GGY 加白失败：核心调用异常 ${redactGgy('$e', list)}');
      final now = DateTime.now();
      _record({for (final t in list) t: GgyResult(kind: GgyResultKind.failed, reason: '核心调用异常', at: now)});
      return;
    }
    final parsed = parseGgyReport(raw, list);
    final now = DateTime.now();
    final fresh = <String, GgyResult>{};
    for (final t in list) {
      final r = parsed[t] ?? GgyResult(kind: GgyResultKind.failed, reason: '核心无响应', at: now);
      fresh[t] = r;
      log(r.logLine(t));
    }
    _record(fresh);
  }

  /// 并入新结论，只留还在列表里的 token（上报期间可能删了 token / 关了开关），变了才回调。
  void _record(Map<String, GgyResult> fresh) {
    final keep = _active().toSet();
    final next = {
      for (final e in {..._results, ...fresh}.entries)
        if (keep.contains(e.key)) e.key: e.value,
    };
    if (mapEquals(next, _results)) return;
    _results = next;
    onResults?.call(next);
  }

  void _ensureWatchers() {
    _timer ??= Timer.periodic(interval, (_) => unawaited(report()));
    if (_connSub != null) return;
    final seed = currentConnectivity;
    if (seed != null) {
      seed().then((r) => _lastConn ??= r.toSet(), onError: (_) {});
    }
    _connSub = connectivity().listen((results) {
      final set = results.toSet();
      if (_lastConn != null && setEquals(set, _lastConn)) return;
      _lastConn = set;
      if (results.isEmpty || results.every((r) => r == ConnectivityResult.none)) return;
      _connDebounce?.cancel();
      _connDebounce = Timer(connectivityDebounce, () => unawaited(report()));
    });
  }

  /// 开关关闭 / token 删光：停掉定时器与网络监听，清掉结论。[notify] 为 false 时不回调（provider 销毁时用）。
  void stop({bool notify = true}) {
    _timer?.cancel();
    _timer = null;
    _connDebounce?.cancel();
    _connDebounce = null;
    unawaited(_connSub?.cancel());
    _connSub = null;
    _lastConn = null;
    if (_results.isNotEmpty) {
      _results = const {};
      if (notify) onResults?.call(const {});
    }
  }
}

/// 每个 token 最近一次的结论（只在内存里；GGY token 页的「上一次结果」）。键 = token。
final ggyResultsProvider = StateProvider<Map<String, GgyResult>>((ref) => const {});

final ggyReporterProvider = Provider<GgyReporter>((ref) {
  final reporter = GgyReporter(
    isEnabled: () => ref.read(meowSettingProvider).ggyEnabled,
    tokens: () => ref.read(meowSettingProvider).ggyTokens,
    send: (urls) => clashCore.clashInterface.invoke<String>(
      method: ActionMethod.meowPo0Report,
      data: json.encode({'kind': 'ggy', 'urls': urls}),
      // 核心每个 url 10s 超时、并发发出；再留几秒给桥层
      timeout: const Duration(seconds: 15),
    ),
    connectivity: () => Connectivity().onConnectivityChanged,
    currentConnectivity: () => Connectivity().checkConnectivity(),
    log: commonPrint.log,
    onResults: (r) => ref.read(ggyResultsProvider.notifier).state = r,
  );
  ref.onDispose(() => reporter.stop(notify: false));
  return reporter;
});
