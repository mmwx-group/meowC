import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';

import 'package:bett_box/common/common.dart';
import 'package:bett_box/enum/enum.dart';
import 'package:bett_box/providers/providers.dart';
import 'package:bett_box/state.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:window_ext/window_ext.dart';
import 'package:window_manager/window_manager.dart';

import 'package:bett_box/meowx/app/window_controls.dart';

class WindowManager extends ConsumerStatefulWidget {
  final Widget child;

  const WindowManager({super.key, required this.child});

  @override
  ConsumerState<WindowManager> createState() => _WindowContainerState();
}

class _WindowContainerState extends ConsumerState<WindowManager>
    with WindowListener, WindowExtListener {
  Timer? _renderToggleTimer;
  bool? _pendingRenderResume;
  Timer? _windowGeometryTimer;
  int _windowGeometryRevision = 0;

  void _scheduleRenderToggle(bool resume) {
    _pendingRenderResume = resume;
    _renderToggleTimer?.cancel();
    _renderToggleTimer = Timer(const Duration(milliseconds: 500), () {
      if (_pendingRenderResume == true) {
        render?.resume();
      } else {
        render?.pause();
      }
    });
  }

  void _scheduleWindowGeometryCapture() {
    final revision = ++_windowGeometryRevision;
    _windowGeometryTimer?.cancel();
    _windowGeometryTimer = Timer(const Duration(milliseconds: 125), () async {
      if (!mounted || revision != _windowGeometryRevision) return;
      final isAbnormal = (await windowManager.isMaximized()) ||
          (await windowManager.isFullScreen()) ||
          (await windowManager.isMinimized());
      if (isAbnormal) return;

      final bounds = await windowManager.getBounds();
      if (!bounds.width.isFinite ||
          !bounds.height.isFinite ||
          bounds.width <= 0 ||
          bounds.height <= 0) {
        return;
      }
      if (!bounds.left.isFinite || !bounds.top.isFinite) return;

      ref.read(windowSettingProvider.notifier).updateState(
            (state) => state.copyWith(
              width: bounds.width,
              height: bounds.height,
              left: bounds.left,
              top: bounds.top,
            ),
          );
    });
  }

  void _invalidateWindowGeometryCapture() {
    _windowGeometryRevision++;
    _windowGeometryTimer?.cancel();
    _windowGeometryTimer = null;
  }

  @override
  Widget build(BuildContext context) {
    return widget.child;
  }

  ProviderSubscription? _autoLaunchSub;

  @override
  void initState() {
    super.initState();
    _autoLaunchSub = ref.listenManual(
      appSettingProvider.select((state) => state.autoLaunch),
      (prev, next) {
        if (prev != next) {
          debouncer.call(FunctionTag.autoLaunch, () {
            autoLaunch?.updateStatus(next);
          });
        }
      },
    );
    windowExtManager.addListener(this);
    windowManager.addListener(this);
  }

  @override
  void onWindowClose() async {
    globalState.appController.unBackBlock();
    await globalState.appController.handleBackOrExit();
  }

  @override
  Future<void> onShouldTerminate() async {
    await globalState.appController.handleExit();
    super.onShouldTerminate();
  }

  @override
  void onWindowMove() {
    super.onWindowMove();
    _scheduleWindowGeometryCapture();
  }

  @override
  void onWindowMoved() {
    super.onWindowMoved();
    _scheduleWindowGeometryCapture();
  }

  @override
  void onWindowResize() {
    super.onWindowResize();
    _scheduleWindowGeometryCapture();
  }

  @override
  void onWindowResized() {
    super.onWindowResized();
    _scheduleWindowGeometryCapture();
  }

  @override
  void onWindowMaximize() {
    _invalidateWindowGeometryCapture();
    super.onWindowMaximize();
  }

  @override
  void onWindowUnmaximize() {
    super.onWindowUnmaximize();
    _scheduleWindowGeometryCapture();
  }

  @override
  void onWindowEnterFullScreen() {
    _invalidateWindowGeometryCapture();
    super.onWindowEnterFullScreen();
  }

  @override
  void onWindowLeaveFullScreen() {
    super.onWindowLeaveFullScreen();
    _scheduleWindowGeometryCapture();
  }

  @override
  void onWindowMinimize() async {
    globalState.appController.savePreferencesDebounce();
    _renderToggleTimer?.cancel();
    await globalState.handleBackground();
    super.onWindowMinimize();
  }

  @override
  void onWindowFocus() {
    if (globalState.backgroundMode.value) {
      globalState.handleForeground();
      _scheduleRenderToggle(true);
      unawaited(globalState.resumeForegroundUpdates());
      unawaited(globalState.appController.syncWakelockIfNeeded());
    }
    super.onWindowFocus();
  }

  @override
  void onWindowRestore() {
    globalState.handleForeground();
    _scheduleRenderToggle(true);
    unawaited(globalState.resumeForegroundUpdates());
    unawaited(globalState.appController.syncWakelockIfNeeded());
    super.onWindowRestore();
  }

  @override
  void onTaskbarCreated() {
    globalState.appController.updateTray(true);
    super.onTaskbarCreated();
  }

  @override
  Future<void> dispose() async {
    _autoLaunchSub?.close();
    windowManager.removeListener(this);
    windowExtManager.removeListener(this);
    _renderToggleTimer?.cancel();
    _windowGeometryTimer?.cancel();
    super.dispose();
  }
}

class WindowHeaderContainer extends StatelessWidget {
  final Widget child;

  /// MeowX：窗口按钮并进页面标题那一行，不再单占顶上一条标题栏（见 lib/meowx/app/window_controls.dart）
  final bool merged;

  const WindowHeaderContainer({super.key, required this.child, this.merged = false});

  @override
  Widget build(BuildContext context) {
    if (merged) {
      return Stack(
        children: [
          child,
          const Positioned(top: windowControlsTop, right: 4, child: WindowHeader(merged: true)),
        ],
      );
    }
    return Consumer(
      builder: (_, ref, child) {
        final isMobileView = ref.watch(isMobileViewProvider);
        final version = ref.watch(versionProvider);
        if ((version <= 10 || !isMobileView) && system.isMacOS) {
          return child!;
        }
        return Stack(
          children: [
            Column(
              children: [
                SizedBox(height: kHeaderHeight),
                Expanded(flex: 1, child: child!),
              ],
            ),
            const WindowHeader(),
          ],
        );
      },
      child: child,
    );
  }
}

class WindowHeader extends ConsumerStatefulWidget {
  /// MeowX：只画按钮（并进页面标题行），不画整条可拖动的标题栏、不做悬停才显示
  final bool merged;

  const WindowHeader({super.key, this.merged = false});

  @override
  ConsumerState<WindowHeader> createState() => _WindowHeaderState();
}

class _WindowHeaderState extends ConsumerState<WindowHeader> {
  final isMaximizedNotifier = ValueNotifier<bool>(false);
  final isPinNotifier = ValueNotifier<bool>(false);
  final isHoveringNotifier = ValueNotifier<bool>(false);

  @override
  void initState() {
    super.initState();
    _initNotifier();
  }

  Future<void> _initNotifier() async {
    final isMaximized = await windowManager.isMaximized();
    if (!mounted) return;
    isMaximizedNotifier.value = isMaximized;
    
    final isAlwaysOnTop = await windowManager.isAlwaysOnTop();
    if (!mounted) return;
    isPinNotifier.value = isAlwaysOnTop;
  }

  @override
  void dispose() {
    isMaximizedNotifier.dispose();
    isPinNotifier.dispose();
    isHoveringNotifier.dispose();
    super.dispose();
  }

  Future<void> _updateMaximized() async {
    final isMaximized = await windowManager.isMaximized();
    switch (isMaximized) {
      case true:
        await windowManager.unmaximize();
        break;
      case false:
        await windowManager.maximize();
        break;
    }
    isMaximizedNotifier.value = await windowManager.isMaximized();
  }

  Future<void> _updatePin() async {
    final isAlwaysOnTop = await windowManager.isAlwaysOnTop();
    final newIsPinned = !isAlwaysOnTop;
    await windowManager.setAlwaysOnTop(newIsPinned);
    isPinNotifier.value = newIsPinned;
    ref.read(windowSettingProvider.notifier).updateState(
          (state) => state.copyWith(isPinned: newIsPinned),
        );
  }

  Widget _buildActions() {
    final shouldUseHoverEffect = system.isWindows || system.isLinux;
    final alwaysShowTitleBar = widget.merged ||
        ref.watch(
          vpnSettingProvider.select((state) => state.alwaysShowTitleBar),
        );

    return MouseRegion(
      onEnter: shouldUseHoverEffect
          ? (_) => isHoveringNotifier.value = true
          : null,
      onExit: shouldUseHoverEffect
          ? (_) {
              Future.delayed(const Duration(milliseconds: 100), () {
                if (mounted) {
                  isHoveringNotifier.value = false;
                }
              });
            }
          : null,
      child: ValueListenableBuilder<bool>(
        valueListenable: isHoveringNotifier,
        builder: (_, isHovering, _) {
          final showButtons =
              !shouldUseHoverEffect || alwaysShowTitleBar || isHovering;
          return Opacity(
            opacity: showButtons ? 1.0 : 0.0,
            child: IgnorePointer(
              ignoring: !showButtons,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (widget.merged)
                    Container(
                      width: 1,
                      height: 18,
                      margin: const EdgeInsets.only(right: 8),
                      color: Theme.of(context).colorScheme.outlineVariant.withValues(alpha: 0.7),
                    ),
                  ValueListenableBuilder(
                    valueListenable: isPinNotifier,
                    builder: (_, value, _) {
                      return _DesktopWindowButton(
                        tooltip: value ? '取消置顶' : '置顶窗口',
                        icon: value ? Icons.push_pin_rounded : Icons.push_pin_outlined,
                        active: value,
                        onPressed: _updatePin,
                      );
                    },
                  ),
                  _DesktopWindowButton(
                    tooltip: '最小化',
                    icon: Icons.remove_rounded,
                    onPressed: () {
                      windowManager.minimize();
                    },
                  ),
                  ValueListenableBuilder(
                    valueListenable: isMaximizedNotifier,
                    builder: (_, value, _) {
                      return _DesktopWindowButton(
                        tooltip: value ? '还原' : '最大化',
                        icon: value ? Icons.filter_none_rounded : Icons.crop_square_rounded,
                        iconSize: value ? 15 : 17,
                        onPressed: () async {
                          _updateMaximized();
                        },
                      );
                    },
                  ),
                  _DesktopWindowButton(
                    tooltip: '关闭',
                    icon: Icons.close_rounded,
                    isClose: true,
                    onPressed: () {
                      FocusManager.instance.primaryFocus?.unfocus();
                      globalState.appController.unBackBlock();
                      globalState.appController.handleBackOrExit();
                    },
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (widget.merged) {
      return Material(type: MaterialType.transparency, child: _buildActions());
    }
    return Material(
      child: Stack(
        alignment: AlignmentDirectional.center,
        children: [
          Positioned(
            child: GestureDetector(
              onPanStart: (_) {
                windowManager.startDragging();
              },
              onDoubleTap: () {
                _updateMaximized();
              },
              child: Container(
                color: Colors.transparent,   // MeowX：标题栏并进页面底色，不再是一条色带
                alignment: Alignment.centerLeft,
                height: kHeaderHeight,
              ),
            ),
          ),
          if (system.isMacOS)
            const Text(appName)
          else ...[
            Positioned(right: 0, child: _buildActions()),
          ],
        ],
      ),
    );
  }
}

final sidebarIconPathProvider =
    StateNotifierProvider<SidebarIconPathNotifier, String?>((ref) {
      return SidebarIconPathNotifier();
    });

class SidebarIconPathNotifier extends StateNotifier<String?> {
  SidebarIconPathNotifier() : super(null) {
    _init();
  }

  Future<void> _init() async {
    final prefs = await preferences.sharedPreferencesCompleter.future;
    state = prefs?.getString(customSidebarIconKey);
  }

  Future<void> updatePath(String? path) async {
    state = path;
    final prefs = await preferences.sharedPreferencesCompleter.future;
    if (path == null) {
      prefs?.remove(customSidebarIconKey);
    } else {
      prefs?.setString(customSidebarIconKey, path);
    }
  }
}

class AppIcon extends ConsumerWidget {
  const AppIcon({super.key});

  Future<void> _handlePickImage(BuildContext context, WidgetRef ref) async {
    final result = await FilePicker.platform.pickFiles(type: FileType.image);

    if (result != null && result.files.single.path != null) {
      final path = result.files.single.path!;
      final file = File(path);
      final size = await file.length();
      if (size > 1024 * 1024) {
        if (context.mounted) {
          globalState.showNotifier('Image size exceeds 1MB');
        }
        return;
      }
      ref.read(sidebarIconPathProvider.notifier).updatePath(path);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final customIconPath = ref.watch(sidebarIconPathProvider);

    Widget icon;
    if (customIconPath != null && customIconPath.isNotEmpty) {
      icon = ClipOval(
        child: Image.file(
          File(customIconPath),
          width: 32,
          height: 32,
          fit: BoxFit.cover,
          cacheWidth: 64,
          cacheHeight: 64,
          errorBuilder: (_, _, _) {
            // Fallback if file load fails
            return Image.asset(
              isDark
                  ? 'assets/images/icon.png'
                  : 'assets/images/icon_light.png',
              fit: BoxFit.contain,
            );
          },
        ),
      );
    } else {
      icon = Image.asset(
        isDark ? 'assets/images/icon.png' : 'assets/images/icon_light.png',
        fit: BoxFit.contain,
      );
    }

    return GestureDetector(
      onLongPress: () => _handlePickImage(context, ref),
      child: SizedBox(width: 40, height: 40, child: icon),
    );
  }
}

/// Windows / Linux 现代无边框窗口控制按钮：带柔和悬停底色（关闭键 hover 柔和红）、置顶高亮与轻量图标。
class _DesktopWindowButton extends StatefulWidget {
  const _DesktopWindowButton({
    required this.icon,
    required this.onPressed,
    this.tooltip,
    this.isClose = false,
    this.active = false,
    this.iconSize = 17,
  });

  final IconData icon;
  final VoidCallback onPressed;
  final String? tooltip;
  final bool isClose;
  final bool active;
  final double iconSize;

  @override
  State<_DesktopWindowButton> createState() => _DesktopWindowButtonState();
}

class _DesktopWindowButtonState extends State<_DesktopWindowButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final bg = _hovered
        ? (widget.isClose
            ? const Color(0xFFE81123)
            : cs.onSurface.withValues(alpha: dark ? 0.11 : 0.07))
        : (widget.active ? cs.primary.withValues(alpha: dark ? 0.20 : 0.12) : Colors.transparent);
    final fg = _hovered && widget.isClose
        ? Colors.white
        : widget.active
        ? cs.primary
        : cs.onSurface.withValues(alpha: _hovered ? 1.0 : 0.82);

    Widget btn = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 1),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onPressed,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            width: 36,
            height: 32,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: bg,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(widget.icon, size: widget.iconSize, color: fg),
          ),
        ),
      ),
    );
    if (widget.tooltip != null) {
      btn = Tooltip(message: widget.tooltip!, child: btn);
    }
    return btn;
  }
}
