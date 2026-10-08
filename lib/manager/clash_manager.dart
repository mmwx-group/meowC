import 'dart:async';

import 'package:bett_box/clash/clash.dart';
import 'package:bett_box/common/common.dart';
import 'package:bett_box/enum/enum.dart';
import 'package:bett_box/models/models.dart';
import 'package:bett_box/providers/app.dart';
import 'package:bett_box/providers/config.dart';
import 'package:bett_box/providers/state.dart';
import 'package:bett_box/state.dart';
import 'package:bett_box/views/proxies/common.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class ClashManager extends ConsumerStatefulWidget {
  final Widget child;

  const ClashManager({super.key, required this.child});

  @override
  ConsumerState<ClashManager> createState() => _ClashContainerState();
}

class _ClashContainerState extends ConsumerState<ClashManager>
    with AppMessageListener {
  @override
  Widget build(BuildContext context) {
    return widget.child;
  }

  @override
  void initState() {
    super.initState();
    clashMessage.addListener(this);
    ref.listenManual(needSetupProvider, (prev, next) {
      if (prev != next) {
        final profileChanged = prev?.a != next.a;
        unawaited(
          globalState.appController
              .handleChangeProfile(
                hardRestart: system.isDesktop && profileChanged,
              )
              .catchError((Object error, StackTrace stackTrace) {
                commonPrint.log('Profile change failed: $error');
              }),
        );
      }
    });
    ref.listenManual(coreStateProvider, (prev, next) async {
      if (prev != next) {
        await clashCore.setState(next);
      }
    });
    ref.listenManual(updateParamsProvider, (prev, next) {
      if (prev != next) {
        globalState.appController.updateClashConfigDebounce();
      }
    });

    ref.listenManual(appSettingProvider.select((state) => state.openLogs), (
      prev,
      next,
    ) {
      if (next) {
        clashCore.startLog();
      } else {
        clashCore.stopLog();
      }
    });
  }

  @override
  Future<void> dispose() async {
    _lateGroupsUpdateTimer?.cancel();
    clashMessage.removeListener(this);
    super.dispose();
  }

  // MeowX：手动测速收尾后补拉代理组的那一趟，见 onDelay。
  Timer? _lateGroupsUpdateTimer;
  // 核心里 url-test 组的「当前节点」算一次缓存 10 秒（URLTest.fastSingle）
  static const _urlTestNowCacheFor = Duration(seconds: 10);

  /// MeowX：Android 上界面真的不可见了。不能看 backgroundMode——它把 inactive 也算后台，
  /// 而分屏 / 小窗里焦点在别的 App 时就是 inactive，界面还在屏幕上。
  bool get _isAndroidUiHidden {
    if (!system.isAndroid) return false;
    final state = WidgetsBinding.instance.lifecycleState;
    return state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.detached;
  }

  /// MeowX：Android 界面不可见时没有人在看代理组，这一趟先欠着，回前台补
  /// （桌面不省：窗口收在托盘时托盘菜单里的当前节点还要跟着变）。
  void _updateGroupsUnlessHidden() {
    final appController = globalState.appController;
    if (_isAndroidUiHidden) {
      appController.deferGroupsUpdate();
      return;
    }
    appController.updateGroupsDebounce();
  }

  @override
  Future<void> onDelay(Delay delay) async {
    super.onDelay(delay);
    final appController = globalState.appController;
    appController.setDelay(delay);
    // MeowX：界面发起的测速（测全部 / 测本组 / 点延迟胶囊）还在跑时不为每条结果排 5 秒那一趟——测速收尾自己会拉代理组
    // （views/proxies/common.dart）。核心先推这条消息再回测速结果，所以此时请求还挂着。
    // 但收尾那趟拿到的 url-test 组当前节点可能是测速前算好缓存着的（界面发起的测速不会让缓存失效），
    // 所以有 url-test 组时，在最后一条结果过了缓存期之后再补一趟；内容没变的话这一趟不会通知任何界面。
    if (hasPendingDelayTest) {
      if (ref.read(groupsProvider).any((g) => g.type == GroupType.URLTest)) {
        _lateGroupsUpdateTimer?.cancel();
        _lateGroupsUpdateTimer = Timer(
          _urlTestNowCacheFor,
          _updateGroupsUnlessHidden,
        );
      }
      return;
    }
    // MeowX：界面不可见时健康检查的结果只记延迟，不排刷新
    if (_isAndroidUiHidden) {
      appController.deferGroupsUpdate();
      return;
    }
    debouncer.call(FunctionTag.updateDelay, () async {
      _updateGroupsUnlessHidden();
    }, duration: const Duration(milliseconds: 5000));
  }

  @override
  void onLog(Log log) {
    ref.read(logsProvider.notifier).addLog(log);
    if (log.logLevel == LogLevel.error) {
      globalState.showNotifier(log.payload);
    }
    super.onLog(log);
  }

  @override
  void onRequest(TrackerInfo trackerInfo) async {
    ref.read(requestsProvider.notifier).addRequest(trackerInfo);
    super.onRequest(trackerInfo);
  }

  @override
  Future<void> onLoaded(String providerName) async {
    ref
        .read(providersProvider.notifier)
        .setProvider(await clashCore.getExternalProvider(providerName));
    globalState.appController.updateGroupsDebounce();
    super.onLoaded(providerName);
  }
}
