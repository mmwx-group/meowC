import 'dart:async';

import 'package:bett_box/clash/core.dart';
import 'package:bett_box/common/common.dart';
import 'package:bett_box/enum/enum.dart';
import 'package:bett_box/manager/window_manager.dart';
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
    ref.listenManual(checkIpProvider, (prev, next) {
      if (next.b && (prev?.a != next.a)) {
        detectionState.startCheck();
      }
    });
    ref.listenManual(checkMediaUnlockProvider, (prev, next) {
      if (next.b && (prev?.a != next.a)) {
        mediaUnlockState.startCheckOnNodeChange();
      }
    });
    ref.listenManual(configStateProvider, (prev, next) {
      if (prev != next) {
        globalState.appController.savePreferencesDebounce();
      }
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _updateDashboardRefreshState();
      detectionState.tryStartCheck();
      mediaUnlockState.tryStartCheck();
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

      final hasDetection = ref
          .read(dashboardStateProvider)
          .dashboardWidgets
          .contains(DashboardWidget.networkDetection);
      if (hasDetection) {
        detectionState.tryStartCheck();
      }
    }
    if (state == AppLifecycleState.resumed && system.isAndroid) {
      final hidden = ref.read(appSettingProvider.select((s) => s.hidden));
      app.updateExcludeFromRecents(hidden);
      SystemChrome.setSystemUIOverlayStyle(
        globalState.appState.systemUiOverlayStyle,
      );
    }
    if (state == AppLifecycleState.inactive) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        detectionState.tryStartCheck();
      });
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

/// MeowX 壳自己负责导航（手机底栏 / 宽屏 IconRail）。留成函数而不是常量，方便以后按设置切回 Bettbox 原界面。
bool _meowShellOwnsNavigation() => true;

class AppSidebarContainer extends ConsumerWidget {
  final Widget child;

  const AppSidebarContainer({super.key, required this.child});

  Widget _buildLoading() {
    return Consumer(
      builder: (_, ref, _) {
        final loading = ref.watch(loadingProvider);
        final isMobileView = ref.watch(isMobileViewProvider);
        return loading && !isMobileView
            ? RotatedBox(
                quarterTurns: 1,
                child: const LinearProgressIndicator(),
              )
            : Container();
      },
    );
  }

  Widget _buildBackground({
    required BuildContext context,
    required Widget child,
  }) {
    final isLight = context.colorScheme.brightness == Brightness.light;
    return Container(
      decoration: BoxDecoration(
        color: context.colorScheme.surfaceContainerHigh,
        border: Border(
          right: BorderSide(
            color: context.colorScheme.outlineVariant.withValues(
              alpha: isLight ? 0.6 : 0.45,
            ),
          ),
        ),
      ),
      child: Material(color: Colors.transparent, child: child),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final navigationState = ref.watch(navigationStateProvider);
    final navigationItems = navigationState.navigationItems;
    final isMobileView = navigationState.viewMode == ViewMode.mobile;
    // MeowX：壳自带左侧图标栏（IconRail），Bettbox 的桌面侧栏一律不显示，否则出现双重菜单
    if (isMobileView || _meowShellOwnsNavigation()) {
      return child;
    }
    final currentIndex = navigationState.currentIndex;
    final showLabel = ref.watch(appSettingProvider).showLabel;
    return Row(
      children: [
        Stack(
          alignment: Alignment.topRight,
          children: [
            _buildBackground(
              context: context,
              child: SafeArea(
                left: true,
                top: true,
                right: false,
                bottom: false,
                child: Column(
                  children: [
                    if (system.isMacOS) const SizedBox(height: 22),
                    const SizedBox(height: 16),
                    if (!system.isMacOS) ...[
                      const AppIcon(),
                      const SizedBox(height: 12),
                    ],
                    Expanded(
                      child: ScrollConfiguration(
                        behavior: HiddenBarScrollBehavior(),
                        child: LayoutBuilder(
                          builder: (context, constraints) {
                            return SingleChildScrollView(
                              child: ConstrainedBox(
                                constraints: BoxConstraints(
                                  minHeight: constraints.maxHeight,
                                ),
                                child: IntrinsicHeight(
                                  child: CallbackShortcuts(
                                    bindings: <ShortcutActivator, VoidCallback>{
                                      const SingleActivator(
                                        LogicalKeyboardKey.arrowUp,
                                      ): () {
                                        if (currentIndex > 0) {
                                          globalState.appController.toPage(
                                            navigationItems[currentIndex - 1]
                                                .label,
                                          );
                                        }
                                      },
                                      const SingleActivator(
                                        LogicalKeyboardKey.arrowDown,
                                      ): () {
                                        if (currentIndex <
                                            navigationItems.length - 1) {
                                          globalState.appController.toPage(
                                            navigationItems[currentIndex + 1]
                                                .label,
                                          );
                                        }
                                      },
                                      const SingleActivator(
                                        LogicalKeyboardKey.select,
                                      ): () {},
                                      const SingleActivator(
                                        LogicalKeyboardKey.enter,
                                      ): () {},
                                    },
                                    child: Focus(
                                      autofocus: true,
                                      child: NavigationRail(
                                        backgroundColor: Colors.transparent,
                                        indicatorColor:
                                            context.colorScheme.primary
                                                .withValues(
                                                  alpha:
                                                      context
                                                              .colorScheme
                                                              .brightness ==
                                                          Brightness.light
                                                      ? 0.20
                                                      : 0.26,
                                                ),
                                        indicatorShape:
                                            const RoundedRectangleBorder(
                                              borderRadius: BorderRadius.all(
                                                Radius.circular(16),
                                              ),
                                            ),
                                        selectedIconTheme: IconThemeData(
                                          color: context.colorScheme.primary,
                                        ),
                                        unselectedIconTheme: IconThemeData(
                                          color:
                                              context.colorScheme.onSurfaceVariant,
                                        ),
                                        selectedLabelTextStyle: context
                                            .textTheme
                                            .labelLarge!
                                            .copyWith(
                                              color: context.colorScheme.primary,
                                              fontWeight: FontWeight.w600,
                                            ),
                                        unselectedLabelTextStyle: context
                                            .textTheme
                                            .labelLarge!
                                            .copyWith(
                                              color: context
                                                  .colorScheme
                                                  .onSurfaceVariant,
                                            ),
                                        destinations: navigationItems
                                            .map(
                                              (e) => NavigationRailDestination(
                                                icon: e.icon,
                                                label: Text(
                                                  e.label.localizedName,
                                                ),
                                              ),
                                            )
                                            .toList(),
                                        onDestinationSelected: (index) {
                                          final label =
                                              navigationItems[index].label;
                                          if (currentIndex == index) {
                                            final pageContext = GlobalObjectKey(
                                              label,
                                            ).currentContext;
                                            if (pageContext != null) {
                                              Navigator.of(
                                                pageContext,
                                              ).popUntil(
                                                (route) => route.isFirst,
                                              );
                                            }
                                          }
                                          globalState.appController.toPage(
                                            label,
                                          );
                                        },
                                        extended: showLabel,
                                        selectedIndex: currentIndex,
                                        labelType: showLabel
                                            ? NavigationRailLabelType.none
                                            : NavigationRailLabelType.all,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            );
                          },
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            _buildLoading(),
          ],
        ),
        Expanded(
          flex: 1,
          child: ClipRect(
            child: MediaQuery.removePadding(
              context: context,
              removeLeft: true,
              child: child,
            ),
          ),
        ),
      ],
    );
  }
}
