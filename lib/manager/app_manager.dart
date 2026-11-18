import 'dart:async';

import 'package:bett_box/clash/core.dart';
import 'package:bett_box/common/common.dart';
import 'package:bett_box/plugins/app.dart';
import 'package:bett_box/providers/providers.dart';
import 'package:bett_box/state.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class AppStateManager extends ConsumerStatefulWidget {
  final Widget child;

  const AppStateManager({super.key, required this.child});

  @override
  ConsumerState<AppStateManager> createState() => _AppStateManagerState();
}

class _AppStateManagerState extends ConsumerState<AppStateManager>
    with WidgetsBindingObserver {
  bool _isRefreshActive = false;
  Timer? _dashboardRefreshDebounceTimer;
  Timer? _missedUpdateCheckTimer;
  DateTime? _lastMissedUpdateCheck;
  late final VoidCallback _dashboardTickListener;

  static const _missedUpdateCheckDelay = Duration(seconds: 5);
  static const _missedUpdateCheckThrottle = Duration(seconds: 60);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _dashboardTickListener = () {
      if (!globalState.isStart) {
        return;
      }
      unawaited(globalState.appController.updateRunTime());
    };
    dashboardRefreshManager.tick1s.addListener(_dashboardTickListener);
    ref.listenManual(layoutChangeProvider, (prev, next) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (prev != next) {
          globalState.computeHeightMapCache = {};
        }
      });
    });
    // MeowX：Bettbox 首页的「网络检测」「流媒体解锁」格子（2026-11-17 随 Bettbox 界面删掉）没有了，不再在启动 / 回前台 /
    // 换节点时在后台查出口 IP 与解锁（首页的出口 IP 是 MeowX 自己的 exitIpProvider）。
    ref.listenManual(configStateProvider, (prev, next) {
      if (prev != next) {
        globalState.appController.savePreferencesDebounce();
      }
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _updateDashboardRefreshState();
      // MeowX：这里原来还排了一趟 updateGroupsDebounce()。AppController.init() 自己必定会拉代理组，
      // 首帧后 600ms 这趟要么是白拉第二遍，要么在核心还没装载配置时拿到空表、
      // 占着 _coreLifecycleLock 做四连重试，反过来挡住 init 里的 applyProfile。
    });
    if (window == null) {
      return;
    }
    ref.listenManual(autoSetSystemDnsStateProvider, (prev, next) async {
      if (prev == next) {
        return;
      }
      final shouldSet = next.a == true && next.b == true;
      await macOS?.updateDns(!shouldSet);
    });
    ref.listenManual(currentBrightnessProvider, (prev, next) {
      if (prev == next) {
        return;
      }
      window?.updateMacOSBrightness(next);
    }, fireImmediately: true);
  }

  @override
  void dispose() {
    _dashboardRefreshDebounceTimer?.cancel();
    _missedUpdateCheckTimer?.cancel();
    dashboardRefreshManager.tick1s.removeListener(_dashboardTickListener);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  Future<void> _updateDashboardRefreshState() async {
    final lifecycleState = WidgetsBinding.instance.lifecycleState;
    final isForeground =
        lifecycleState == null || lifecycleState == AppLifecycleState.resumed;
    var isVisible = true;
    var isMinimized = false;
    if (system.isDesktop) {
      final visible = await window?.isVisible;
      if (visible == false) {
        isVisible = false;
      }
      isMinimized = await window?.isMinimized ?? false;
    }
    final isPinned = system.isDesktop &&
        ref.read(windowSettingProvider.select((s) => s.isPinned));
    final shouldRun = system.isDesktop
        ? (isPinned || (isVisible && !isMinimized))
        : isForeground;

    if (!shouldRun) {
      _dashboardRefreshDebounceTimer?.cancel();
      _dashboardRefreshDebounceTimer = null;
      if (_isRefreshActive) {
        dashboardRefreshManager.stop();
        _isRefreshActive = false;
      }
      return;
    }

    if (_isRefreshActive) {
      return;
    }

    _dashboardRefreshDebounceTimer?.cancel();
    _dashboardRefreshDebounceTimer = Timer(
      const Duration(milliseconds: 1000),
      () {
        if (!mounted) return;
        if (_isRefreshActive) return;
        dashboardRefreshManager.start();
        _isRefreshActive = true;
      },
    );
  }

  bool get _shouldCheckMissedUpdates {
    if (_lastMissedUpdateCheck == null) return true;
    return DateTime.now().difference(_lastMissedUpdateCheck!) >
        _missedUpdateCheckThrottle;
  }

  void _scheduleMissedUpdateCheck() {
    if (!_shouldCheckMissedUpdates) return;
    _missedUpdateCheckTimer?.cancel();
    _missedUpdateCheckTimer = Timer(_missedUpdateCheckDelay, () {
      _lastMissedUpdateCheck = DateTime.now();
      globalState.appController.checkAndUpdateMissedProfiles();
    });
  }

  // MeowX：回前台要补做多少，看离开时走到了哪一步——
  // _wasBackground：进过下面的后台分支（Android 含 inactive；桌面 = 窗口隐藏 / 最小化）。
  // _leftApp：界面真的不可见过（paused / hidden），而不只是 Android 上被通知栏 / 权限框 / VPN 授权框盖了一下。
  bool _wasBackground = false;
  bool _leftApp = false;
  static const _groupsFreshFor = Duration(seconds: 30);

  @override
  Future<void> didChangeAppLifecycleState(AppLifecycleState state) async {
    final isBackgroundState =
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden ||
        (state == AppLifecycleState.inactive && !system.isDesktop);

    if (isBackgroundState) {
      _wasBackground = true;
      if (state != AppLifecycleState.inactive) {
        _leftApp = true;
      }
      _missedUpdateCheckTimer?.cancel();
      globalState.appController.savePreferences();
      await globalState.handleBackground();
    } else if (state == AppLifecycleState.resumed) {
      final wasBackground = _wasBackground;
      final leftApp = _leftApp;
      _wasBackground = false;
      _leftApp = false;
      globalState.handleForeground();
      render?.resume();
      // MeowX：桌面窗口只是失焦再聚焦（Alt-Tab 回来）时什么都没停过，不必重起每秒轮询、多打两次 getTraffic
      if (wasBackground || !system.isDesktop) {
        await globalState.resumeForegroundUpdates();
      }
      await globalState.appController.syncWakelockIfNeeded();
      _scheduleMissedUpdateCheck();
      final isInit = await clashCore.isInit;
      if (isInit) {
        // MeowX：Android 上没离开过 App 的短暂失焦（下拉通知栏之类）回来，刚刷新过就不再全量拉一趟代理组。
        // 真离开过（外部面板可能改了选择）照常拉；桌面聚焦也照常拉——窗口失焦期间 60 秒定时刷新是停的
        // （Application._syncAutoUpdateTasks 只在 resumed 时跑），全靠这一趟追上。
        if (system.isDesktop || leftApp) {
          globalState.appController.updateGroupsDebounce();
        } else {
          globalState.appController.updateGroupsIfStale(_groupsFreshFor);
        }
      }

    }
    if (state == AppLifecycleState.resumed && system.isAndroid) {
      final hidden = ref.read(appSettingProvider.select((s) => s.hidden));
      app.updateExcludeFromRecents(hidden);
      SystemChrome.setSystemUIOverlayStyle(
        globalState.appState.systemUiOverlayStyle,
      );
    }
    _updateDashboardRefreshState();
  }

  @override
  void didChangePlatformBrightness() {
    globalState.appController.updateBrightness();
    globalState.appController.updateTray();
  }

  @override
  Widget build(BuildContext context) {
    return widget.child;
  }
}

class AppEnvManager extends StatelessWidget {
  final Widget child;

  const AppEnvManager({super.key, required this.child});

  // MeowX：不再在右上角画 DEBUG / PRE 斜角标（会压住标题行右侧的按钮和窗口按钮）。
  // 调试包 / 预发布包从「我的 → 关于」的版本号辨认。
  @override
  Widget build(BuildContext context) => child;
}
