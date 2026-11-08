import 'dart:async';
import 'dart:convert';

import 'package:bett_box/clash/clash.dart';
import 'package:bett_box/common/common.dart';
import 'package:bett_box/enum/enum.dart';
import 'package:bett_box/models/meow.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../panel/akile.dart';
import 'meow_settings.dart';

/// AkileCDN 白名单：把本机**直连**出口 IPv4 写进用户所选 AkileCDN 规则的入口白名单（规格：MeowX 仓库
/// Design/akile-whitelist.md）。
///
/// 查出口 IP 与 PUT 都由 Go 核心直连发出（`ActionMethod.meowAkile`，见 core/meow_akile.go：与 po0 / GGY 同一个直连
/// dialer，绕开 TUN / 本地混合端口、只按 IPv4 查出口），这里只管时机与结论。一切以设置里的「AkileCDN 白名单」开关
/// （`MeowSettings.akileEnabled`，默认关）为准，开着、Key 合法且至少有一个节点时：
/// - 启动后、开关刚打开、换 Key 时把全部节点报一次；新加节点只报这一个；
/// - 网络变化、回前台时全部报一次（回前台 30 秒内只算一次）；
/// - 每 10 分钟一轮「定时轮」：出口 IP 与这个节点上一次成功写入的 IP 相同就不写（一条规则只放一个 IP，多台设备都开时
///   无条件覆盖会互相抢；只在事件或 IP 真变了时写）。
/// 删节点、关开关不触发上报；关掉 / Key 删掉 / 节点删光即停，结论清空。本机偏好：退出登录不清，没登录也报。
/// 「上一次成功写入的 IP」只在内存里（结论里），重启后第一轮一定写。
///
/// 依赖全部经构造函数注入，方便单测；App 里由 [akileReporterProvider] 组装。
class AkileReporter {
  AkileReporter({
    required this.isEnabled,
    required this.apiKey,
    required this.nodes,
    required this.send,
    required this.connectivity,
    this.currentConnectivity,
    required this.log,
    this.onResults,
    this.interval = const Duration(minutes: 10),
    this.connectivityDebounce = const Duration(seconds: 3),
    this.foregroundThrottle = const Duration(seconds: 30),
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  /// 设置开关
  final bool Function() isEnabled;

  /// 存着的 API Key（每次现取）
  final String Function() apiKey;

  /// 存着的节点（每次现取）
  final List<MeowAkileNode> Function() nodes;

  /// 交给核心（参数 JSON → 回包 JSON），[timeout] 是桥层等回包的上限
  final Future<String> Function(String params, Duration timeout) send;

  /// 网络变化事件
  final Stream<List<ConnectivityResult>> Function() connectivity;

  /// 当前网络状态，开始监听时拿来当基线（Android 的回调会反复推同一组状态，只有变了才报）
  final Future<List<ConnectivityResult>> Function()? currentConnectivity;
  final void Function(String) log;

  /// 各节点最近一次的结论变了（键 = 规则 ID；删掉的节点、关掉开关后都不在里面）
  final void Function(Map<int, AkileResult> results)? onResults;

  /// 定时轮间隔
  final Duration interval;

  /// 网络变化后等路由 / DHCP 稳定再报
  final Duration connectivityDebounce;

  /// 回前台触发的上报至少隔这么久（来回切 App 时别每次都写一遍，20 个节点也会撞到 120 次 / 分钟的上限）
  final Duration foregroundThrottle;
  final DateTime Function() _now;

  Map<int, AkileResult> _results = const {};
  Timer? _timer;
  StreamSubscription<List<ConnectivityResult>>? _connSub;
  Timer? _connDebounce;
  Set<ConnectivityResult>? _lastConn;
  DateTime? _lastForeground;
  bool _reporting = false;

  /// 在飞时又要报：合并成一次（全是定时轮才算定时轮；有一次要全部就全部）
  ({bool timer, Set<int>? only})? _pending;

  Map<int, AkileResult> get results => _results;

  /// 定时器与网络监听是否在跑
  bool get isWatching => _timer != null;

  String? _key() {
    if (!isEnabled()) return null;
    final k = apiKey();
    return isValidAkileKey(k) ? k : null;
  }

  /// 当前要报的节点：开关关着 / Key 不合法为空
  List<MeowAkileNode> _active() => _key() == null ? const [] : akileReportNodes(nodes());

  /// 开关 / Key / 节点列表变了（以及启动时）调：可以报 → 起定时器与网络监听，[reportNow] 时立刻报一次（[only] 不为
  /// null 时只报这几条规则：新加的节点）；否则停掉。删掉的节点的结论一并丢掉。
  Future<void> sync({bool reportNow = false, Set<int>? only}) async {
    if (_active().isEmpty) {
      stop();
      return;
    }
    _record(const {});
    _ensureWatchers();
    if (reportNow) await report(only: only);
  }

  /// 回到前台：开着就报一次（[foregroundThrottle] 内只算一次）。
  void onForeground() {
    if (!isWatching) return;
    final now = _now();
    final last = _lastForeground;
    if (last != null && now.difference(last) < foregroundThrottle) return;
    _lastForeground = now;
    unawaited(report());
  }

  /// 报一轮：[timer] = 定时轮（IP 没变的节点不写）；[only] 只报这几条规则。在飞时合并成再报一次。
  Future<void> report({bool timer = false, Set<int>? only}) async {
    if (_active().isEmpty) return;
    if (_reporting) {
      final p = _pending;
      _pending = p == null
          ? (timer: timer, only: only == null ? null : {...only})
          : (timer: p.timer && timer, only: p.only == null || only == null ? null : {...p.only!, ...only});
      return;
    }
    _reporting = true;
    try {
      await _reportOnce(timer: timer, only: only);
    } finally {
      _reporting = false;
      final next = _pending;
      _pending = null;
      if (next != null) unawaited(report(timer: next.timer, only: next.only));
    }
  }

  Future<void> _reportOnce({required bool timer, Set<int>? only}) async {
    final key = _key();
    if (key == null) return;
    final list = [
      for (final n in akileReportNodes(nodes()))
        if (only == null || only.contains(n.ruleId)) n,
    ];
    if (list.isEmpty) return;
    final params = json.encode({
      'op': 'report',
      'key': key,
      'timer': timer,
      'nodes': [
        for (final n in list)
          {
            'rule_id': n.ruleId,
            'name': n.name,
            if (timer && _results[n.ruleId]?.okIp != null) 'skip_ip': _results[n.ruleId]!.okIp,
          },
      ],
    });
    String raw;
    try {
      // 核心：查出口 IP 至多 5 秒 + 每个节点至多 10 秒，再留几秒给桥层
      raw = await send(params, Duration(seconds: 10 + 10 * list.length));
    } catch (e) {
      log('$akileTitle失败：核心调用异常 ${redactAkile('$e', key)}');
      final now = _now();
      _record({for (final n in list) n.ruleId: AkileResult(kind: AkileResultKind.failed, error: '核心调用异常', at: now)});
      return;
    }
    final report = parseAkileReport(raw, list, key: key, at: _now());
    if (report.error.isNotEmpty) {
      log('$akileTitle失败：${report.error}');
    } else if (report.ipError.isNotEmpty) {
      log('$akileTitle：查不到本机直连出口 IPv4（${report.ipError}）');
    } else {
      for (final n in list) {
        final r = report.results[n.ruleId];
        if (r != null) log(r.logLine(n.name, n.ruleId, key: key));
      }
    }
    _record(report.results);
  }

  /// 并入新结论，只留还在列表里的节点（上报期间可能删了节点 / 关了开关），变了才回调。
  void _record(Map<int, AkileResult> fresh) {
    final keep = {for (final n in _active()) n.ruleId};
    final next = {
      for (final e in {..._results, ...fresh}.entries)
        if (keep.contains(e.key)) e.key: e.value,
    };
    if (mapEquals(next, _results)) return;
    _results = next;
    onResults?.call(next);
  }

  void _ensureWatchers() {
    _timer ??= Timer.periodic(interval, (_) => unawaited(report(timer: true)));
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

  /// 开关关闭 / Key 删掉 / 节点删光：停掉定时器与网络监听，清掉结论。[notify] 为 false 时不回调（provider 销毁时用）。
  void stop({bool notify = true}) {
    _timer?.cancel();
    _timer = null;
    _connDebounce?.cancel();
    _connDebounce = null;
    unawaited(_connSub?.cancel());
    _connSub = null;
    _lastConn = null;
    _lastForeground = null;
    if (_results.isNotEmpty) {
      _results = const {};
      if (notify) onResults?.call(const {});
    }
  }
}

/// 各节点最近一次的结论（只在内存里；「AkileCDN 节点」页的「上一次结果」）。键 = 规则 ID。
final akileResultsProvider = StateProvider<Map<int, AkileResult>>((ref) => const {});

/// 调核心 `meowAkile`（参数 JSON → 回包 JSON）。
Future<String> invokeMeowAkile(String params, Duration timeout) =>
    clashCore.clashInterface.invoke<String>(method: ActionMethod.meowAkile, data: params, timeout: timeout);

/// 「从订阅添加节点」查规则：用 Key 按端口查（核心直连 GET /rules）。测试里换掉它。
final akileRulesLookupProvider = Provider<Future<AkileRulesLookup> Function(String key, int port)>((ref) {
  return (key, port) async {
    try {
      final raw = await invokeMeowAkile(
        json.encode({'op': 'rules', 'key': key, 'port': port}),
        const Duration(seconds: 15),
      );
      return parseAkileRules(raw, key: key);
    } catch (e) {
      return AkileRulesLookup(error: '核心调用异常 ${redactAkile('$e', key)}');
    }
  };
});

final akileReporterProvider = Provider<AkileReporter>((ref) {
  final reporter = AkileReporter(
    isEnabled: () => ref.read(meowSettingProvider).akileEnabled,
    apiKey: () => ref.read(meowSettingProvider).akileKey,
    nodes: () => ref.read(meowSettingProvider).akileNodes,
    send: invokeMeowAkile,
    connectivity: () => Connectivity().onConnectivityChanged,
    currentConnectivity: () => Connectivity().checkConnectivity(),
    log: commonPrint.log,
    onResults: (r) => ref.read(akileResultsProvider.notifier).state = r,
  );
  // 回前台：从后台 / 最小化回来（hidden → inactive），不算窗口只是失焦再聚焦
  final lifecycle = AppLifecycleListener(onShow: reporter.onForeground);
  ref.onDispose(() {
    lifecycle.dispose();
    reporter.stop(notify: false);
  });
  return reporter;
});
