import 'dart:async';

import 'package:bett_box/common/common.dart';
import 'package:bett_box/enum/enum.dart';
import 'package:bett_box/providers/providers.dart';
import 'package:collection/collection.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../config/direct_profile.dart';
import 'connection.dart';

/// 安卓桌面小组件要显示的数据（原生侧画法见 android/app/src/main/kotlin/com/appshub/bettbox/meowx/MeowXWidget.kt，
/// 设计同 iOS 的小组件）。连没连原生自己看隧道状态，这里给的是订阅名、用量、模式、本次流量。
@immutable
class HomeWidgetData {
  const HomeWidgetData({
    required this.connected,
    required this.subName,
    required this.mode,
    required this.used,
    required this.total,
    required this.sessionUp,
    required this.sessionDown,
  });

  final bool connected;

  /// 当前订阅名；没有订阅（内置直连档）时 null，小组件状态行照旧写「…模式 · 保护中」。
  final String? subName;
  final Mode mode;
  final int? used;
  final int? total;

  /// 本次连接的累计流量（核心的 total traffic）。
  final int sessionUp;
  final int sessionDown;

  /// 变了就要马上重画的部分。
  bool sameIdentity(HomeWidgetData o) =>
      connected == o.connected && subName == o.subName && mode == o.mode && used == o.used && total == o.total;

  bool sameTraffic(HomeWidgetData o) => sessionUp == o.sessionUp && sessionDown == o.sessionDown;

  /// 键与原生的 `MeowXWidgetStore.save` 对应。`since`：运行时长起点（毫秒时间戳），没连时不给。
  Map<String, Object?> toMap({int? since}) => {
    'subName': subName,
    'mode': mode.name,
    'used': used,
    'total': total,
    'sessionUp': connected ? sessionUp : 0,
    'sessionDown': connected ? sessionDown : 0,
    'since': connected ? since : 0,
  };
}

final homeWidgetDataProvider = Provider<HomeWidgetData>((ref) {
  final connected = ref.watch(runTimeProvider.select((t) => t != null));
  final mode = ref.watch(patchClashConfigProvider.select((s) => s.mode));
  final traffic = ref.watch(totalTrafficProvider);
  // 内置直连档不算订阅（同首页：「未使用订阅，流量全部直连」）
  final current = ref.watch(currentProfileProvider);
  final profile = current != null && !isDirectProfile(current.id) ? current : null;
  final label = profile?.label;
  final info = profile?.subscriptionInfo;
  return HomeWidgetData(
    connected: connected,
    subName: profile == null ? null : ((label?.isNotEmpty ?? false) ? label : profile.id),
    mode: mode,
    used: info == null ? null : info.upload + info.download,
    total: (info?.total ?? 0) > 0 ? info!.total : null,
    sessionUp: traffic.up.value,
    sessionDown: traffic.down.value,
  );
});

/// 什么时候把数据推给小组件：连接态 / 订阅 / 模式 / 用量变了马上推；本次流量至多 30 秒推一次（数字每秒在变，
/// 桌面上又看不见 App 开着时的小组件，推勤了只是白白重画）；App 退到后台时强推一次，回到桌面就是这一刻的数。
class HomeWidgetPushPolicy {
  static const trafficInterval = Duration(seconds: 30);

  HomeWidgetData? _last;
  DateTime? _lastAt;

  bool shouldPush(HomeWidgetData next, DateTime now, {bool force = false}) {
    final last = _last;
    final at = _lastAt;
    final push =
        force ||
        last == null ||
        !last.sameIdentity(next) ||
        (!last.sameTraffic(next) && (at == null || now.difference(at) >= trafficInterval));
    if (push) {
      _last = next;
      _lastAt = now;
    }
    return push;
  }
}

/// 安卓桌面小组件的数据同步与模式切换（通道「meowx/widget」，原生侧见 MeowXWidgetPlugin.kt），挂在 MeowRoot 上。
class HomeWidgetSync with WidgetsBindingObserver {
  HomeWidgetSync(this.ref);

  final WidgetRef ref;

  static const _channel = MethodChannel('meowx/widget');
  final _policy = HomeWidgetPushPolicy();
  final _subs = <ProviderSubscription<Object?>>[];
  bool _started = false;

  void start() {
    if (!system.isAndroid || _started) return;
    _started = true;
    _channel.setMethodCallHandler(_onCall);
    WidgetsBinding.instance.addObserver(this);
    _subs.add(ref.listenManual<HomeWidgetData>(homeWidgetDataProvider, (_, next) => _push(next), fireImmediately: true));
    // 小组件上点了模式、当时 App 不在：等核心初始化完再切
    _subs.add(
      ref.listenManual<bool>(initProvider, (_, inited) {
        if (inited) unawaited(_consumePendingMode());
      }, fireImmediately: true),
    );
  }

  void stop() {
    if (!_started) return;
    _started = false;
    for (final sub in _subs) {
      sub.close();
    }
    _subs.clear();
    WidgetsBinding.instance.removeObserver(this);
    _channel.setMethodCallHandler(null);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.paused || AppLifecycleState.hidden:
        _push(ref.read(homeWidgetDataProvider), force: true);
      case AppLifecycleState.resumed:
        unawaited(_consumePendingMode());
      default:
        break;
    }
  }

  void _push(HomeWidgetData data, {bool force = false}) {
    final now = DateTime.now();
    if (!_policy.shouldPush(data, now, force: force)) return;
    final runTime = ref.read(runTimeProvider);
    final since = data.connected && runTime != null ? now.millisecondsSinceEpoch - runTime : null;
    _channel.invokeMethod<void>('update', data.toMap(since: since)).catchError((Object e) {
      commonPrint.log('home widget update failed: $e');
    });
  }

  Future<dynamic> _onCall(MethodCall call) async {
    if (call.method == 'setMode') _applyMode(call.arguments as String?);
    return null;
  }

  Future<void> _consumePendingMode() async {
    if (!ref.read(initProvider)) return;
    try {
      _applyMode(await _channel.invokeMethod<String>('consumePendingMode'));
    } catch (e) {
      commonPrint.log('home widget pending mode failed: $e');
    }
  }

  void _applyMode(String? name) {
    final mode = Mode.values.firstWhereOrNull((m) => m.name == name);
    if (mode == null) return;
    if (ref.read(patchClashConfigProvider).mode == mode) {
      // 没变（小组件那边已先把分段挪过去了）：照实推一次，免得停在别的值上
      _push(ref.read(homeWidgetDataProvider), force: true);
      return;
    }
    setOutboundMode(ref, mode);   // 同 App 里的模式分段
  }
}
