import 'dart:async';
import 'dart:convert';
import 'dart:isolate';

import 'package:bett_box/clash/clash.dart';
import 'package:bett_box/common/common.dart';
import 'package:bett_box/enum/enum.dart';
import 'package:bett_box/models/models.dart';
import 'package:bett_box/providers/providers.dart';
import 'package:bett_box/state.dart';
import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app/meow_tab.dart';
import 'meow_settings.dart';
import 'status.dart';

/// 桌面形态（Windows）。`--dart-define=MEOWX_PREVIEW_DESKTOP=true` 只用于在 Android 模拟器上预览桌面布局，正式包不带。
final isDesktopUi = system.isWindows || const bool.fromEnvironment('MEOWX_PREVIEW_DESKTOP');

// ---------------------------------------------------------------------------
// 开关：首页主卡与 Windows 侧栏的电源键共用一份状态

enum ConnPhase { off, connecting, on }

class PowerState {
  const PowerState({this.busy = false, this.optimistic});
  final bool busy;

  /// 点下去到核心真正起 / 停之间的乐观值
  final bool? optimistic;
}

class PowerController extends Notifier<PowerState> {
  @override
  PowerState build() => const PowerState();

  Future<void> toggle() async {
    if (state.busy) return;
    final isStart = ref.read(isRunningProvider);
    state = PowerState(busy: true, optimistic: !isStart);
    try {
      await globalState.appController.updateStatus(!isStart);
    } catch (e) {
      commonPrint.log('updateStatus failed: $e');
    } finally {
      state = const PowerState();
    }
  }
}

final powerProvider = NotifierProvider<PowerController, PowerState>(PowerController.new);

/// 有可启动的配置（内置直连档也算）。
final hasProfileProvider = Provider<bool>((ref) {
  return ref.watch(startButtonSelectorStateProvider).hasProfile && ref.watch(currentProfileProvider) != null;
});

final connPhaseProvider = Provider<ConnPhase>((ref) {
  if (ref.watch(isRunningProvider)) return ConnPhase.on;
  final power = ref.watch(powerProvider);
  if (power.optimistic == true || ref.watch(isRestartingCoreProvider)) return ConnPhase.connecting;
  return ConnPhase.off;
});

/// 电源键此刻能不能点。
final powerEnabledProvider = Provider<bool>((ref) {
  return ref.watch(hasProfileProvider) && !ref.watch(powerProvider).busy && !ref.watch(isRestartingCoreProvider);
});

/// 切换出站模式（手选即取消「直连档自动设的 direct」标记）。
void setOutboundMode(WidgetRef ref, Mode mode) {
  ref.read(meowSettingProvider.notifier).updateState((s) => s.copyWith(autoDirectMode: false));
  globalState.appController.changeMode(mode);
}

String modeLabel(Mode m) => switch (m) {
  Mode.rule => '规则',
  Mode.global => '全局',
  Mode.direct => '直连',
};

// ---------------------------------------------------------------------------
// 当前节点：主组沿选中链解析到叶子

class CurrentNode {
  const CurrentNode({required this.group, required this.path, required this.leaf, this.testUrl});

  /// 主组（当前模式下的第一个可见组）
  final String group;

  /// 从主组到叶子之前的组名链（如 [节点选择, 自动选择]）
  final List<String> path;

  /// 叶子节点名；主组还没有选中时为空
  final String leaf;
  final String? testUrl;

  String get pathText => path.join(' › ');

  @override
  bool operator ==(Object other) =>
      other is CurrentNode &&
      other.group == group &&
      other.leaf == leaf &&
      other.testUrl == testUrl &&
      const ListEquality<String>().equals(other.path, path);

  @override
  int get hashCode => Object.hash(group, leaf, testUrl, Object.hashAll(path));
}

/// 没有代理组（直连档 / 没有配置）→ null。
final currentNodeProvider = Provider<CurrentNode?>((ref) {
  final first = ref.watch(currentGroupsStateProvider.select((s) => s.value.firstOrNull));
  if (first == null) return null;
  final path = <String>[first.name];
  var name = first.name;
  final seen = <String>{name};
  while (true) {
    final next = ref.watch(getSelectedProxyNameProvider(name));
    if (next == null || next.isEmpty) break;   // 不是组（已到叶子）或还没有选中
    name = next;
    if (!seen.add(name)) break;
    path.add(name);
  }
  if (path.length == 1) return CurrentNode(group: first.name, path: path, leaf: '', testUrl: first.testUrl);
  final leaf = path.removeLast();
  return CurrentNode(group: first.name, path: path, leaf: leaf, testUrl: first.testUrl);
});

/// 当前节点的延迟（没测过 → null，超时 → 负数，与 [getDelayProvider] 同口径）。
final currentNodeDelayProvider = Provider<int?>((ref) {
  final node = ref.watch(currentNodeProvider);
  if (node == null || node.leaf.isEmpty) return null;
  return ref.watch(getDelayProvider(proxyName: node.leaf, testUrl: node.testUrl));
});

// ---------------------------------------------------------------------------
// 连接计数 / 内存：壳统一轮询，首页指标与侧栏角标共用

class ConnStats {
  const ConnStats({this.total = 0, this.proxied = 0, this.direct = 0, this.memory = 0});
  final int total, proxied, direct, memory;

  ConnStats copyWith({int? total, int? proxied, int? direct, int? memory}) => ConnStats(
    total: total ?? this.total,
    proxied: proxied ?? this.proxied,
    direct: direct ?? this.direct,
    memory: memory ?? this.memory,
  );

  @override
  bool operator ==(Object other) =>
      other is ConnStats && other.total == total && other.proxied == proxied && other.direct == direct && other.memory == memory;

  @override
  int get hashCode => Object.hash(total, proxied, direct, memory);
}

/// 三个连接计数。
typedef ConnCounts = ({int total, int proxied, int direct});

const ConnCounts _noConns = (total: 0, proxied: 0, direct: 0);

/// 计数口径（两种取法共用）：chains 首项 = 实际落地的出站——DIRECT 记直连，REJECT 开头的两边都不记，其余记代理。
ConnCounts _tally(Iterable<String> firstHops) {
  var total = 0, proxied = 0, direct = 0;
  for (final first in firstHops) {
    total++;
    if (first == 'DIRECT') {
      direct++;
    } else if (!first.startsWith('REJECT')) {
      proxied++;
    }
  }
  return (total: total, proxied: proxied, direct: direct);
}

/// 一份连接列表的三个计数。
ConnCounts countConnections(List<TrackerInfo> conns) => _tally(conns.map((c) => c.chains.firstOrNull ?? ''));

/// 直接从核心回的快照 JSON（`{"connections":[…]}`）里数，不建 TrackerInfo。
ConnCounts countConnectionsJson(String raw) {
  final data = json.decode(raw);
  final list = data is Map ? data['connections'] : null;
  if (list is! List) return _noConns;
  return _tally(
    list.map((c) {
      final chains = c is Map ? c['chains'] : null;
      final first = chains is List ? chains.firstOrNull : null;
      return first is String ? first : '';
    }),
  );
}

/// 顶层函数：交给新 isolate 的闭包只带着 [raw] 这一个字符串。
Future<ConnCounts> _countOffMain(String raw) => Isolate.run(() => countConnectionsJson(raw));

/// 向核心要连接快照的两种取法。默认问核心，只有测试会换掉。
class ConnSource {
  const ConnSource();

  /// 完整列表：动态页、宽屏首页的「活跃连接」卡要逐条显示。
  Future<List<TrackerInfo>> list() => clashCore.getConnections();

  /// 只要三个计数（壳自己轮询时）：解析和计数都在后台 isolate 里做完，回到 UI 线程的只有三个整数，
  /// 不把 N 个 TrackerInfo 建出来再搬回主堆。
  Future<ConnCounts> counts() async {
    final raw = await clashCore.clashInterface.getConnections();
    if (raw.isEmpty) return _noConns;
    try {
      return await _countOffMain(raw);
    } catch (e) {
      commonPrint.log('Failed to count connections: $e');
      return _noConns;
    }
  }
}

final connSourceProvider = Provider<ConnSource>((ref) => const ConnSource());

class ConnStatsController extends Notifier<ConnStats> {
  /// 可见页面取到的完整快照在这么久之内算新鲜，壳不再自己问核心。
  /// 比动态页的轮询间隔（1.5s）略长：它在取的时候，壳每秒的那一拍总是落在这个窗口里。
  static const _fedFresh = Duration(milliseconds: 1600);

  bool _polling = false;

  /// 正在经 [fetchConnections] 取快照的页面数
  int _feeding = 0;

  /// 上一次经 [fetchConnections] 取到快照的时间
  DateTime? _fedAt;

  /// 现在几点；只有测试会换掉。
  @visibleForTesting
  DateTime Function() now = DateTime.now;

  @override
  ConnStats build() {
    void t1() => unawaited(_pollConnections());
    void t2() => unawaited(_pollMemory());
    dashboardRefreshManager.tick1s.addListener(t1);
    dashboardRefreshManager.tick2s.addListener(t2);
    ref.onDispose(() {
      dashboardRefreshManager.tick1s.removeListener(t1);
      dashboardRefreshManager.tick2s.removeListener(t2);
    });
    // 手机上离开首页期间不拉（见 _shown）：切回首页立即补一次，不等下一拍。宽屏一直在拉，不用补
    ref.listen(meowTabProvider, (prev, next) {
      if (next == MeowTab.home && !ref.read(isWideLayoutProvider)) t1();
    });
    return const ConnStats();
  }

  /// NotifierProvider 默认按 identical 判断要不要通知，copyWith 每次都是新对象；改成按值比，数字没变就不重建首页指标格 / 侧栏角标。
  @override
  bool updateShouldNotify(ConnStats previous, ConnStats next) => previous != next;

  /// 这三个数此刻有没有界面在显示：宽屏的侧栏角标每一页都在；手机布局只有首页的指标格用。
  bool get _shown => ref.read(isWideLayoutProvider) || ref.read(meowTabProvider) == MeowTab.home;

  void _setCounts(ConnCounts c) => state = state.copyWith(total: c.total, proxied: c.proxied, direct: c.direct);

  /// 可见页面（动态页、宽屏首页的「活跃连接」卡）取完整快照的入口：列表交给页面，三个计数顺手记到这里，
  /// 壳在这之后的 [_fedFresh] 内不再自己问核心——同一份连接表不各拉各的。
  Future<List<TrackerInfo>> fetchConnections() async {
    _feeding++;
    try {
      final list = await ref.read(connSourceProvider).list();
      _fedAt = now();
      _setCounts(countConnections(list));
      return list;
    } finally {
      _feeding--;
    }
  }

  Future<void> _pollConnections() async {
    if (_polling) return;
    if (!ref.read(isRunningProvider)) {
      if (state.total != 0 || state.proxied != 0 || state.direct != 0) state = ConnStats(memory: state.memory);
      return;
    }
    // 没有界面在显示就不拉：一次要核心序列化整张连接表、这边再解一遍，只为三个数字——手机上停在节点 / 我的页时纯属空转
    if (!_shown) return;
    // 可见页面正在取、或刚取过完整快照：计数已经顺手更新了（时钟往回拨时差值为负，按过期算）
    if (_feeding > 0) return;
    final fedAt = _fedAt;
    if (fedAt != null) {
      final age = now().difference(fedAt);
      if (!age.isNegative && age < _fedFresh) return;
    }
    _polling = true;
    try {
      _setCounts(await ref.read(connSourceProvider).counts());
    } catch (_) {
    } finally {
      _polling = false;
    }
  }

  Future<void> _pollMemory() async {
    if (!ref.read(isRunningProvider)) return;
    try {
      final m = await clashCore.getMemory();
      state = state.copyWith(memory: m);
    } catch (_) {}
  }
}

/// 壳里常驻 listen（MeowRoot）。内存每 2s 问一次；连接计数只在有界面显示它时才问核心，值不变时不通知。
final connStatsProvider = NotifierProvider<ConnStatsController, ConnStats>(ConnStatsController.new);

// ---------------------------------------------------------------------------
// Windows 接管方式：TUN（要 MeowX 服务）/ 系统代理

class TakeoverState {
  const TakeoverState({this.service, this.installing = false});

  /// Windows 的 TUN 要靠 MeowX 服务（helper）以 SYSTEM 拉起核心。
  /// （Bettbox 的 checkIsAdmin 在 Windows 上也只是「服务在跑且 ping 通」，不看进程是否提权，所以这里只认服务状态。）
  /// null = 还没查 / 非 Windows（不检测）。
  final WindowsHelperServiceStatus? service;
  final bool installing;

  bool get tunReady => windows == null || service == WindowsHelperServiceStatus.running;
}

class TakeoverController extends Notifier<TakeoverState> {
  @override
  TakeoverState build() {
    unawaited(Future.microtask(check));
    return const TakeoverState();
  }

  Future<void> check() async {
    final w = windows;
    if (w == null) return;
    try {
      final status = await w.checkService();
      state = TakeoverState(service: status, installing: state.installing);
    } catch (e) {
      commonPrint.log('check helper service failed: $e');
    }
  }

  /// 安装并启动服务（弹一次 UAC）。成功返回 true。
  Future<bool> _installService() async {
    final w = windows;
    if (w == null) return true;
    state = TakeoverState(service: state.service, installing: true);
    try {
      final ok = await w.registerService();
      await check();
      if (!ok) globalState.showNotifier('MeowX 服务安装失败或已取消授权，TUN 未开启');
      return ok;
    } finally {
      state = TakeoverState(service: state.service);
    }
  }

  Future<void> setTun(BuildContext context, bool on) async {
    if (state.installing) return;
    if (on && !state.tunReady) {
      await check();   // 可能刚被安装包 / 别的窗口装好
      if (!context.mounted) return;
      if (!state.tunReady) {
        final go = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('安装 MeowX 服务'),
            content: const Text('虚拟网卡（TUN）需要 MeowX 服务以系统权限运行核心。\n安装只需管理员授权一次，之后开关 TUN 不再弹窗。'),
            actions: [
              TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('取消')),
              FilledButton(onPressed: () => Navigator.of(ctx).pop(true), child: const Text('安装并开启')),
            ],
          ),
        );
        if (go != true) return;
        if (!await _installService()) return;
        // 服务刚装好，说明现在跑着的核心是启动时服务不可用、以当前用户身份回落拉起的——它建不了网卡。
        // 必须重启核心，让 helper 以 SYSTEM 重新拉起；否则后面的 authorizeCore 看到服务已就绪返回 none、不重启，TUN 会下发给这个无权限的核心。
        ref.read(patchClashConfigProvider.notifier).updateState((s) => s.copyWith.tun(enable: true));
        try {
          await globalState.appController.restartCore();
        } catch (_) {}   // 失败已由 restartCore 自己上报
        return;
      }
    }
    ref.read(patchClashConfigProvider.notifier).updateState((s) => s.copyWith.tun(enable: on));
  }

  void setSystemProxy(bool on) {
    ref.read(networkSettingProvider.notifier).updateState((s) => s.copyWith(systemProxy: on));
  }
}

final takeoverProvider = NotifierProvider<TakeoverController, TakeoverState>(TakeoverController.new);

final tunEnabledProvider = Provider<bool>((ref) => ref.watch(patchClashConfigProvider.select((s) => s.tun.enable)));
final systemProxyEnabledProvider = Provider<bool>((ref) => ref.watch(networkSettingProvider.select((s) => s.systemProxy)));

/// TUN 开关下面那行说明；第二项 = 是否警示色。
final tunHintProvider = Provider<(String, bool)>((ref) {
  final t = ref.watch(takeoverProvider);
  final tun = ref.watch(tunEnabledProvider);
  final running = ref.watch(isRunningProvider);
  final realTun = ref.watch(realTunEnableProvider);
  if (t.installing) return ('正在安装 MeowX 服务…', false);
  if (!t.tunReady && t.service != null) {
    return (t.service == WindowsHelperServiceStatus.presence ? 'MeowX 服务未运行 · 开启时修复' : '未安装 MeowX 服务 · 开启时安装', true);
  }
  if (tun && running && !realTun) return ('未生效：没有拿到管理员权限', true);
  return ('接管全部应用的流量${t.service == WindowsHelperServiceStatus.running ? ' · 服务已就绪' : ''}', false);
});
