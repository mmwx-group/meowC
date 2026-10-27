import 'dart:async';

import 'package:bett_box/clash/clash.dart';
import 'package:bett_box/common/common.dart';
import 'package:bett_box/models/models.dart';
import 'package:bett_box/plugins/service.dart';
import 'package:bett_box/providers/providers.dart';
import 'package:bett_box/state.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:synchronized/synchronized.dart';
import 'package:wifi_ssid/wifi_ssid.dart';

import 'meow_settings.dart';

/// Wi-Fi 智能开关（只 Android）：连上指定 Wi-Fi 时断开代理，离开这些 Wi-Fi（别的 Wi-Fi / 蜂窝 / 有线）时连上。
///
/// 行为对齐 iOS / macOS 的「Wi-Fi 规则」：SSID 规则从上往下第一条命中，没命中的走「其它网络」；
/// 只在网络变化时触发（同一网络不重复决策）；用户手动开关后到下一次换网前不再干预。
///
/// 「断开」借 Bettbox 原有的智能启停（`smartStop`）：VPN 服务留着、通知栏显示已挂起，核心暂停；
/// 「连接」= `smartResume` 恢复被规则暂停的代理。规则不会打开用户自己关掉的代理——安卓在后台起
/// 前台服务受限，暂停 / 恢复走的是一直在前台的那个服务，稳定得多（FlClash 的 exclude SSID 也是这个思路）。
///
/// 读 SSID 要精确定位权限 + 系统定位服务（Android 10+ 在后台读还要「始终允许」），只在规则里有 SSID 时才读。
/// 读不到名称时这次不切换，并在设置页 / 日志里说明原因，不当成「其它网络」处理（否则在家里读不到名称就会被当成离开）。

/// 当前所在的物理网络类型（不算 VPN）。
enum NetKind { wifi, cellular, ethernet, none }

/// 在 Wi-Fi 上却读不到名称的原因。
enum SsidIssue {
  /// 没给精确定位权限
  noPermission,

  /// 系统定位服务关着
  locationOff,

  /// 没有「始终允许」，App 在后台时系统不给名称
  background,

  /// 权限都在也读不到（系统暂时没给）
  unreadable;

  String get text => switch (this) {
    SsidIssue.noPermission => '没有定位权限，读不到 Wi-Fi 名称',
    SsidIssue.locationOff => '系统定位服务关着，读不到 Wi-Fi 名称',
    SsidIssue.background => '定位权限不是「始终允许」，App 在后台时读不到 Wi-Fi 名称',
    SsidIssue.unreadable => '系统没有给出 Wi-Fi 名称',
  };
}

/// 某一刻的网络状况。[key] 相同 = 同一个网络（不重复决策）。
@immutable
class NetSnapshot {
  const NetSnapshot(
    this.kind, {
    this.ssid,
    this.issue,
    this.fineLocation = false,
    this.backgroundLocation = false,
    this.locationEnabled = false,
  });

  final NetKind kind;

  /// 只在 Wi-Fi 上、规则里有 SSID 且读到时有值
  final String? ssid;
  final SsidIssue? issue;

  /// 读这一刻时的权限 / 定位服务状态（界面据此给引导）
  final bool fineLocation;
  final bool backgroundLocation;
  final bool locationEnabled;

  String get key => '${kind.name}|${ssid ?? ''}';

  /// Wi-Fi 上需要名称却没读到：不知道是哪个网络
  bool get ssidUnknown => issue != null;

  String get label => switch (kind) {
    NetKind.wifi => ssid != null ? 'Wi-Fi「$ssid」' : (issue != null ? 'Wi-Fi（读不到名称）' : 'Wi-Fi'),
    NetKind.cellular => '蜂窝网络',
    NetKind.ethernet => '有线网络',
    NetKind.none => '无网络',
  };

  @override
  bool operator ==(Object other) =>
      other is NetSnapshot &&
      other.kind == kind &&
      other.ssid == ssid &&
      other.issue == issue &&
      other.fineLocation == fineLocation &&
      other.backgroundLocation == backgroundLocation &&
      other.locationEnabled == locationEnabled;

  @override
  int get hashCode => Object.hash(kind, ssid, issue, fineLocation, backgroundLocation, locationEnabled);
}

/// 规则里有 SSID 条目才需要读名称（也才需要定位权限）。
bool wifiRulesNeedSsid(List<MeowWifiRule> rules) => rules.any((r) => r.ssid.trim().isNotEmpty);

/// 规范化输入的 SSID：去掉首尾空白与系统有时带的引号。空串 = 不合法。
String normalizeSsid(String input) {
  var s = input.trim();
  if (s.length >= 2 && s.startsWith('"') && s.endsWith('"')) s = s.substring(1, s.length - 1);
  return s;
}

/// 新增一条（同名的原地改动作，不重复加）。
List<MeowWifiRule> upsertWifiRule(List<MeowWifiRule> rules, MeowWifiRule rule) {
  final i = rules.indexWhere((r) => r.ssid == rule.ssid);
  if (i < 0) return [...rules, rule];
  return [...rules]..[i] = rule;
}

/// 由原生给的网络状态拼出快照。[ssid] 是读到的名称（只在要读时才去读）。
NetSnapshot composeNetSnapshot(WifiNetworkState st, {required bool needSsid, String? ssid}) {
  NetSnapshot snap(NetKind kind, {String? ssid, SsidIssue? issue}) => NetSnapshot(
    kind,
    ssid: ssid,
    issue: issue,
    fineLocation: st.fineLocation,
    backgroundLocation: st.backgroundLocation,
    locationEnabled: st.locationEnabled,
  );
  if (st.wifi) {
    if (!needSsid) return snap(NetKind.wifi);
    final name = ssid == null ? null : normalizeSsid(ssid);
    if (name != null && name.isNotEmpty) return snap(NetKind.wifi, ssid: name);
    final SsidIssue issue;
    if (!st.fineLocation) {
      issue = SsidIssue.noPermission;
    } else if (!st.locationEnabled) {
      issue = SsidIssue.locationOff;
    } else if (!st.backgroundLocation) {
      issue = SsidIssue.background;
    } else {
      issue = SsidIssue.unreadable;
    }
    return snap(NetKind.wifi, issue: issue);
  }
  if (st.ethernet) return snap(NetKind.ethernet);
  if (st.cellular) return snap(NetKind.cellular);
  return snap(NetKind.none);
}

/// 这个网络该怎么做。[rule] = 命中的那条（null = 走「其它网络」或没有动作）。
typedef WifiVerdict = ({MeowWifiAction action, MeowWifiRule? rule});

/// 规则判定。读不到 SSID 时返回 ignore（调用方据 [NetSnapshot.ssidUnknown] 提示原因）。
WifiVerdict decideWifiAction(List<MeowWifiRule> rules, MeowWifiAction other, NetSnapshot snap) {
  const none = (action: MeowWifiAction.ignore, rule: null);
  switch (snap.kind) {
    case NetKind.none:
      return none;
    case NetKind.wifi:
      if (snap.ssidUnknown) return none;
      final ssid = snap.ssid;
      if (ssid != null) {
        for (final r in rules) {
          if (normalizeSsid(r.ssid) == ssid) return (action: r.action, rule: r);
        }
      }
      return (action: other, rule: null);
    case NetKind.cellular:
    case NetKind.ethernet:
      return (action: other, rule: null);
  }
}

/// 设置页 / 首页显示用的状态。
@immutable
class WifiSwitchStatus {
  const WifiSwitchStatus({this.snapshot, this.note, this.manualOverride = false});

  /// 最近一次读到的网络（还没读过 = null）
  final NetSnapshot? snapshot;

  /// 最近一次做了什么 / 为什么没做（读不到名称）
  final String? note;

  /// 用户在当前网络手动开关过：换网前不自动干预
  final bool manualOverride;

  WifiSwitchStatus copyWith({NetSnapshot? snapshot, String? note, bool clearNote = false, bool? manualOverride}) =>
      WifiSwitchStatus(
        snapshot: snapshot ?? this.snapshot,
        note: clearNote ? null : (note ?? this.note),
        manualOverride: manualOverride ?? this.manualOverride,
      );
}

typedef WifiSwitchConfig = ({bool enabled, List<MeowWifiRule> rules, MeowWifiAction other});

/// 规则执行器。依赖全部经构造函数注入，方便单测；App 里由 [wifiSwitchProvider] 组装。
class WifiSwitchController {
  WifiSwitchController({
    required this.config,
    required this.readNetwork,
    required this.isRunning,
    required this.isSuspended,
    required this.suspend,
    required this.resume,
    required this.networkEvents,
    required this.log,
    this.onStatus,
    this.debounce = const Duration(seconds: 1),
  });

  final WifiSwitchConfig Function() config;

  /// 读当前网络；[needSsid] = 规则里有 SSID，要读名称
  final Future<NetSnapshot> Function(bool needSsid) readNetwork;

  /// 代理正在运行（不含被规则暂停的）
  final bool Function() isRunning;

  /// 处于暂停（smartStop）状态
  final Future<bool> Function() isSuspended;
  final Future<void> Function() suspend;
  final Future<void> Function() resume;

  /// 网络变化事件（connectivity_plus + 原生 networkChanged）
  final Stream<void> Function() networkEvents;
  final void Function(String) log;
  final void Function(WifiSwitchStatus)? onStatus;
  final Duration debounce;

  final _lock = Lock();
  StreamSubscription<void>? _sub;
  Timer? _debounce;

  /// 上一次决策过的网络；null = 还没决策过（启动后第一次读到就按规则走）
  String? _lastKey;
  bool _manual = false;

  /// 自己在暂停 / 恢复（以及之后的 [actingGrace]）：这期间运行状态的变化不算用户手动
  int _acting = 0;
  DateTime? _actingUntil;
  WifiSwitchStatus _status = const WifiSwitchStatus();

  /// 暂停 / 恢复之后多久内的运行状态变化仍算自己引起的（原生那边的状态是异步回来的）
  static const actingGrace = Duration(seconds: 3);

  WifiSwitchStatus get status => _status;
  bool get acting => _acting > 0 || (_actingUntil != null && DateTime.now().isBefore(_actingUntil!));

  @visibleForTesting
  String? get lastKey => _lastKey;

  void start() {
    _sub ??= networkEvents().listen((_) => networkChanged(), onError: (_) {});
    networkChanged();
  }

  void stop() {
    _sub?.cancel();
    _sub = null;
    _debounce?.cancel();
    _debounce = null;
  }

  /// 网络变化：去抖后读网络、按规则决策（同一网络不重复）。
  void networkChanged() {
    _debounce?.cancel();
    _debounce = Timer(debounce, () => unawaited(evaluate(fromNetwork: true)));
  }

  /// 设置页回到前台 / 权限刚给：重读一次，网络（或名称）变了照常决策。
  Future<void> refresh() => evaluate(fromNetwork: true);

  /// 规则改了：对当前网络重新决策（手动覆盖期间不动）。
  Future<void> reevaluate() => evaluate(fromNetwork: false);

  /// 总开关刚打开：当前网络当作新网络决策一次（手动覆盖也作废）。
  Future<void> enabled() {
    _lastKey = null;
    _manual = false;
    return evaluate(fromNetwork: true);
  }

  /// 总开关关掉：规则暂停着的代理恢复。
  Future<void> disabled() => _lock.synchronized(() async {
    _manual = false;
    _lastKey = null;
    if (await isSuspended()) {
      await _act(resume);
      log('Wi-Fi 智能开关已关闭，恢复代理');
    }
    _publish(_status.copyWith(clearNote: true, manualOverride: false));
  });

  /// 用户手动开关（电源键、磁贴、通知）：到下一次换网前不再自动干预。
  void noteManualToggle() {
    if (!config().enabled || _manual) return;
    _manual = true;
    log('Wi-Fi 智能开关：手动开关过，换网前不再自动干预');
    _publish(_status.copyWith(manualOverride: true, clearNote: true));
  }

  /// 暂停中用户点电源键：恢复，并记为手动。
  Future<void> resumeManually() => _lock.synchronized(() async {
    noteManualToggle();
    if (await isSuspended()) await _act(resume);
  });

  /// 运行状态变了（电源键、磁贴、通知……）：不是自己暂停 / 恢复引起的就算用户手动。
  void observedRunChange() {
    if (acting) return;
    noteManualToggle();
  }

  Future<void> _act(Future<void> Function() op) async {
    _acting++;
    try {
      await op();
    } finally {
      _acting--;
      _actingUntil = DateTime.now().add(actingGrace);
    }
  }

  @visibleForTesting
  Future<void> evaluate({required bool fromNetwork}) => _lock.synchronized(() async {
    final cfg = config();
    if (!cfg.enabled) return;
    final NetSnapshot snap;
    try {
      snap = await readNetwork(wifiRulesNeedSsid(cfg.rules));
    } catch (e) {
      log('Wi-Fi 智能开关：读网络状态失败 $e');
      return;
    }
    var status = _status.copyWith(snapshot: snap);
    if (fromNetwork) {
      // 没网（换网途中的空档）与读不到名称都不算「换到了新网络」：不记成已决策、不打断手动覆盖
      if (snap.kind == NetKind.none) {
        _publish(status);
        return;
      }
      if (snap.ssidUnknown) {
        final note = '${snap.issue!.text}，这次不切换';
        if (status.note != note) log('Wi-Fi 智能开关：$note');
        _publish(status.copyWith(note: note));
        return;
      }
      if (snap.key == _lastKey) {
        _publish(status);
        return;
      }
      _lastKey = snap.key;
      if (_manual) {
        _manual = false;
        status = status.copyWith(manualOverride: false);
      }
      log('Wi-Fi 智能开关：网络变化 → ${snap.label}');
    } else if (_manual) {
      _publish(status);
      return;
    } else if (snap.ssidUnknown) {
      _publish(status.copyWith(note: '${snap.issue!.text}，这次不切换'));
      return;
    }
    final verdict = decideWifiAction(cfg.rules, cfg.other, snap);
    final why = verdict.rule != null ? '命中「${verdict.rule!.ssid}」' : '其它网络';
    switch (verdict.action) {
      case MeowWifiAction.ignore:
        status = status.copyWith(clearNote: true);
      case MeowWifiAction.disconnect:
        if (!await isSuspended() && isRunning()) {
          await _act(suspend);
          final note = '在${snap.label}上断开了代理（$why）';
          log('Wi-Fi 智能开关：$note');
          status = status.copyWith(note: note);
        } else {
          status = status.copyWith(clearNote: true);
        }
      case MeowWifiAction.connect:
        if (await isSuspended()) {
          await _act(resume);
          final note = '在${snap.label}上恢复了代理（$why）';
          log('Wi-Fi 智能开关：$note');
          status = status.copyWith(note: note);
        } else {
          status = status.copyWith(clearNote: true);
        }
    }
    _publish(status);
  });

  void _publish(WifiSwitchStatus s) {
    _status = s;
    onStatus?.call(s);
  }
}

/// 设置页 / 首页看的状态。
final wifiSwitchStatusProvider = StateProvider<WifiSwitchStatus>((ref) => const WifiSwitchStatus());

/// 代理正被 Wi-Fi 规则暂停（总开关开着且处于 smartStop）。首页主卡据此显示「已暂停」。
final wifiPausedProvider = Provider<bool>((ref) {
  return system.isAndroid &&
      ref.watch(meowSettingProvider.select((s) => s.wifiSwitchEnabled)) &&
      ref.watch(isSmartStoppedProvider);
});

/// 读当前网络（原生插件）：要名称时先读一次，权限在却没读到就让插件重挂网络回调再读一次
/// （在系统设置里刚给的权限，插件的回调还没挂上）。
Future<NetSnapshot> readNetworkSnapshot(bool needSsid) async {
  final st = await wifiSsidManager.getNetworkState();
  String? ssid;
  if (st.wifi && needSsid && st.fineLocation && st.locationEnabled) {
    ssid = await wifiSsidManager.getSsid().timeout(const Duration(seconds: 5), onTimeout: () => null);
    if (ssid == null) {
      await wifiSsidManager.checkPermission();
      ssid = await wifiSsidManager.getSsid().timeout(const Duration(seconds: 5), onTimeout: () => null);
    }
  }
  return composeNetSnapshot(st, needSsid: needSsid, ssid: ssid);
}

final wifiSwitchProvider = Provider<WifiSwitchController>((ref) {
  final controller = WifiSwitchController(
    config: () {
      final s = ref.read(meowSettingProvider);
      return (enabled: s.wifiSwitchEnabled, rules: s.wifiRules, other: s.wifiOtherAction);
    },
    readNetwork: readNetworkSnapshot,
    isRunning: () => ref.read(runTimeProvider) != null || globalState.isStart,
    isSuspended: () async {
      final v = await service?.isSmartStopped() ?? false;
      ref.read(isSmartStoppedProvider.notifier).set(v);
      return v;
    },
    // 与 Bettbox 的智能启停（lib/manager/smart_auto_stop_manager.dart）同一套暂停 / 恢复
    suspend: () async {
      await service?.setSmartStopped(true);
      await service?.smartStop();
      ref.read(isSmartStoppedProvider.notifier).set(true);
      globalState.startTime = null;
      clashCore.resetTraffic();
      ref.read(trafficsProvider.notifier).clear();
      ref.read(totalTrafficProvider.notifier).value = Traffic();
      ref.read(runTimeProvider.notifier).value = null;
    },
    resume: () async {
      await service?.setSmartStopped(false);
      await service?.smartResume();
      ref.read(isSmartStoppedProvider.notifier).set(false);
      globalState.startTime = DateTime.now();
      ref.read(runTimeProvider.notifier).value = 0;
      globalState.appController.addCheckIpNumDebounce();
    },
    networkEvents: () {
      late final StreamController<void> out;
      StreamSubscription<List<ConnectivityResult>>? sub;
      Future<void> onNative(String method, dynamic _) async {
        if (method == 'networkChanged') out.add(null);
      }

      out = StreamController<void>(
        onListen: () {
          sub = Connectivity().onConnectivityChanged.listen((_) => out.add(null), onError: (_) {});
          service?.addNativeEventCallback(onNative);
        },
        onCancel: () async {
          service?.removeNativeEventCallback(onNative);
          await sub?.cancel();
        },
      );
      return out.stream;
    },
    log: commonPrint.log,
    onStatus: (s) => ref.read(wifiSwitchStatusProvider.notifier).state = s,
  );
  ref.onDispose(controller.stop);
  return controller;
});

/// 总开关。打开时顺手关掉「高级」里 Bettbox 按 IP / 网关的「智能启停」：两者共用同一个暂停状态，
/// 同时开着会互相把对方暂停的代理恢复。开关变化后的执行在 MeowRoot 里（[wifiSwitchProvider] 的 enabled / disabled）。
void setWifiSwitchEnabled(WidgetRef ref, bool value) {
  ref.read(meowSettingProvider.notifier).updateState((s) => s.copyWith(wifiSwitchEnabled: value));
  if (value && ref.read(vpnSettingProvider).smartAutoStop) {
    ref.read(vpnSettingProvider.notifier).updateState((s) => s.copyWith(smartAutoStop: false));
    commonPrint.log('Wi-Fi 智能开关：已关闭高级设置里的「智能启停」');
  }
}

/// 改规则（MeowRoot 监听到变化后对当前网络重新决策）。
void updateWifiRules(WidgetRef ref, List<MeowWifiRule> Function(List<MeowWifiRule> rules) change) {
  ref.read(meowSettingProvider.notifier).updateState((s) => s.copyWith(wifiRules: change(s.wifiRules)));
}
