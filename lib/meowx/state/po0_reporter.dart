import 'dart:async';
import 'dart:convert';

import 'package:bett_box/clash/clash.dart';
import 'package:bett_box/common/common.dart';
import 'package:bett_box/enum/enum.dart';
import 'package:collection/collection.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:bett_box/state.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../panel/account.dart';
import '../panel/po0.dart';
import 'meow_settings.dart';
import 'status.dart';

/// po0 客户端 IP 加白：把本机出口 IP 上报到用户在主控里登记的 po0 服务器。
///
/// 上报由 Go 核心的 `meowPo0Report` 直连发出（与 DIRECT 出站同一条拨号路径，绕开 TUN / 本地混合端口——
/// po0 只加白「发出请求的来源 IP」，经代理发出加进去的是节点出口 IP）。
/// 一切以设置里的「po0 加白」开关（`MeowSettings.po0Enabled`，默认关）为准：关着不拉列表、不上报。
/// 打开后：登录 / 启动拿到列表后立刻报；网络切换时报；每 10 分钟兜底重报（po0 一台只有 5 个名额、
/// 所有用户共用、最久没上报的先被挤掉）。关闭 / 登出即清空并停止。
///
/// 依赖全部经构造函数注入，方便单测；App 里由 [po0ReporterProvider] 组装。
class Po0Reporter {
  Po0Reporter({
    required this.isEnabled,
    required this.fetchServers,
    required this.send,
    required this.connectivity,
    this.currentConnectivity,
    this.onDirectIps,
    required this.log,
    this.interval = const Duration(minutes: 10),
    this.connectivityDebounce = const Duration(seconds: 3),
  });

  /// 设置开关
  final bool Function() isEnabled;

  /// 从主控拉列表；返回 null 表示未登录 / 没有主控（此时停掉一切）
  final Future<List<Po0Server>?> Function() fetchServers;

  /// 交给核心直连 POST，返回核心的 JSON 数组原文
  final Future<String> Function(List<String> urls) send;

  /// 网络变化事件
  final Stream<List<ConnectivityResult>> Function() connectivity;

  /// 当前网络状态，开始监听时拿来当基线（Android 的回调会反复推同一组状态，只有变了才报）
  final Future<List<ConnectivityResult>> Function()? currentConnectivity;
  final void Function(String) log;

  /// po0 服务器 IP 集合变了（拿到新列表 / 列表变空 / 停止时清空）：调用方据此更新直连规则并热重载配置
  final void Function(List<String> ips)? onDirectIps;

  /// 定时兜底间隔
  final Duration interval;

  /// 网络变化后等路由 / DHCP 稳定再报
  final Duration connectivityDebounce;

  /// 登录后紧接着 refreshExtras 也会来一次；这个间隔内只拉一次列表
  static const refreshDedupe = Duration(seconds: 30);

  List<Po0Server> _servers = const [];
  Timer? _timer;
  StreamSubscription<List<ConnectivityResult>>? _connSub;
  Timer? _connDebounce;
  Set<ConnectivityResult>? _lastConn;
  Future<void>? _refreshing;
  DateTime? _refreshedAt;
  bool _reporting = false;
  bool _reportAgain = false;

  List<Po0Server> get servers => _servers;

  /// 定时器与网络监听是否在跑
  bool get isWatching => _timer != null;

  /// 拉一次列表并立刻上报（启动后 / 登录后 / refreshExtras / 定时）。开关关着直接停掉并返回。
  /// [force] 无视去重间隔（开关刚打开、定时到点）。
  Future<void> refresh({bool force = false}) {
    if (!isEnabled()) {
      stop();
      return Future.value();
    }
    final inFlight = _refreshing;
    if (inFlight != null) return inFlight;
    if (!force && _refreshedAt != null && DateTime.now().difference(_refreshedAt!) < refreshDedupe) {
      return Future.value();
    }
    return _refreshing = _refresh().whenComplete(() => _refreshing = null);
  }

  Future<void> _refresh() async {
    List<Po0Server>? list;
    try {
      list = await fetchServers();
    } catch (e) {
      // 拉不到就沿用上一份列表，定时上报照旧
      log('po0 服务器列表拉取失败：$e');
      list = _servers;
    }
    if (list == null) {
      stop();
      return;
    }
    _servers = list;
    _refreshedAt = DateTime.now();
    _setDirectIps(po0DirectIps(list));
    if (_servers.isEmpty) return;
    _ensureWatchers();
    await report();
  }

  /// 用当前列表上报一次；在飞时合并成再报一次。开关关着不报。
  Future<void> report() async {
    if (!isEnabled() || _servers.isEmpty) return;
    if (_reporting) {
      _reportAgain = true;
      return;
    }
    _reporting = true;
    try {
      await _reportOnce(_servers);
    } finally {
      _reporting = false;
      if (_reportAgain) {
        _reportAgain = false;
        unawaited(report());
      }
    }
  }

  Future<void> _reportOnce(List<Po0Server> servers) async {
    String raw;
    try {
      raw = await send([for (final s in servers) s.url]);
    } catch (e) {
      log('po0 上报失败：核心调用异常 $e');
      return;
    }
    final results = Po0ReportResult.parseList(raw);
    if (results.isEmpty) {
      log('po0 上报失败：核心无响应');
      return;
    }
    for (final r in results) {
      final name = servers.firstWhereOrNull((s) => s.url == r.url)?.name ?? r.url;
      log(describeResult(name, r));
    }
  }

  /// 一条上报结果的日志文案。
  static String describeResult(String name, Po0ReportResult r) {
    if (r.error.isNotEmpty) return 'po0 加白 $name 失败：${r.error}';
    if (r.tokenInvalid) return 'po0 加白 $name 失败：po0 token 无效';
    if (!r.ok) return 'po0 加白 $name 失败：HTTP ${r.status}';
    final w = r.whitelist;
    if (w == null) return 'po0 加白 $name 失败：响应无法解析';
    return 'po0 加白 $name：白名单 ${w.count}/${w.limit}，当前 IP ${w.currentIp}${w.enabled ? '' : '（白名单未启用）'}';
  }

  void _ensureWatchers() {
    _timer ??= Timer.periodic(interval, (_) => unawaited(refresh(force: true)));
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

  List<String> _directIps = const [];

  void _setDirectIps(List<String> ips) {
    if (listEquals(ips, _directIps)) return;
    _directIps = ips;
    onDirectIps?.call(ips);
  }

  /// 开关关闭 / 登出 / 账户失效：清空列表、停掉定时器与网络监听，撤掉直连规则。
  /// [notify] 为 false 时不回调（provider 销毁时用）。
  void stop({bool notify = true}) {
    _timer?.cancel();
    _timer = null;
    _connDebounce?.cancel();
    _connDebounce = null;
    unawaited(_connSub?.cancel());
    _connSub = null;
    _lastConn = null;
    _servers = const [];
    _refreshedAt = null;
    if (notify) {
      // 首次 stop 时 _directIps 可能还是初始空表，但设置里可能留着上次的 IP：总是回调一次，由调用方比对
      _directIps = const [];
      onDirectIps?.call(const []);
    }
  }
}

final po0ReporterProvider = Provider<Po0Reporter>((ref) {
  final debug = debugPo0Urls;
  final reporter = Po0Reporter(
    isEnabled: () => debug.isNotEmpty || ref.read(meowSettingProvider).po0Enabled,
    fetchServers: () async {
      if (debug.isNotEmpty) {
        return [
          for (final (i, u) in debug.indexed)
            Po0Server(serverId: -1 - i, name: 'debug${i + 1}', ip: Uri.tryParse(u)?.host ?? '', token: '', url: u),
        ];
      }
      final token = ref.read(meowSettingProvider).account.token;
      final client = ref.read(panelClientProvider);
      if (token.isEmpty || client == null) return null;
      return client.po0Servers(token);
    },
    send: (urls) => clashCore.clashInterface.invoke<String>(
      method: ActionMethod.meowPo0Report,
      data: json.encode({'urls': urls}),
      // 核心每个 url 10s 超时、并发发出；再留几秒给桥层
      timeout: const Duration(seconds: 15),
    ),
    connectivity: () => Connectivity().onConnectivityChanged,
    currentConnectivity: () => Connectivity().checkConnectivity(),
    onDirectIps: (ips) {
      final settings = ref.read(meowSettingProvider);
      if (listEquals(settings.po0DirectIps, ips)) return;
      ref.read(meowSettingProvider.notifier).updateState((s) => s.copyWith(po0DirectIps: ips));
      commonPrint.log(ips.isEmpty ? 'po0 直连规则已撤掉' : 'po0 直连规则：${ips.join(', ')}');
      // 与「绕过代理」等覆写同一方式热生效：规则在 patchRawConfig 里拼，连着就重新应用配置
      if (ref.read(isRunningProvider)) globalState.appController.applyProfileDebounce(silence: true);
    },
    log: commonPrint.log,
  );
  ref.onDispose(() => reporter.stop(notify: false));
  return reporter;
});
