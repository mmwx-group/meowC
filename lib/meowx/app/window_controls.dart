import 'package:bett_box/common/common.dart';
import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import '../theme/tokens.dart';

/// Windows：窗口按钮（钉住 / 最小化 / 最大化 / 关闭）并进页面标题那一行（参考 Clash Party），不再单占顶上一条 40 高的标题栏。
///
/// - 按钮仍由 Bettbox 的 `WindowHeader` 画（`WindowHeaderContainer(merged: true)`），固定在窗口右上角，
///   竖直方向与页面标题行（[PageTitle] 的第一行：上边距 6 + 行高 44）居中对齐；
/// - 主页四个 Tab 的标题行右侧让出按钮的位置（[windowControlsReserve]），标题行本身可以拖动窗口（[WindowDragArea]）；
/// - 从主页推出去的二级页（测速、设置子页、高级设置…）顶上照旧有一条可拖动的窗口栏（[WindowPageFrame]，
///   `BaseNavigator.push` 统一包），按钮落在那条栏里。
bool get windowControlsMerged => system.isWindows || system.isLinux;

/// 只在 Android 模拟器上预览桌面布局时用（`--dart-define=MEOWX_PREVIEW_DESKTOP=true`）：画一排假的窗口按钮看对齐，正式包不带
const _previewDesktop = bool.fromEnvironment('MEOWX_PREVIEW_DESKTOP');

/// 标题行要给窗口按钮让位置（真的 Windows，或模拟器上的桌面预览）
bool get windowControlsShown => windowControlsMerged || _previewDesktop;

/// 窗口按钮：四个 40×40 的图标按钮
const windowControlsWidth = 4 * 40.0;

/// 窗口按钮离窗口顶边：40 高的按钮中线落在标题行中线上（6 + 44 / 2 = 28）
const windowControlsTop = 8.0;

/// 标题行右侧让出的宽度（按钮 + 间距）
const windowControlsReserve = windowControlsWidth + 8;

/// 按住拖动窗口（Windows）；别的平台原样返回。只接拖动、不接双击：祖先上挂双击会让里面按钮的单击要等双击超时才触发。
class WindowDragArea extends StatelessWidget {
  const WindowDragArea({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (!windowControlsMerged) return child;
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onPanStart: (_) => windowManager.startDragging(),
      child: child,
    );
  }
}

/// 二级页的窗口栏：顶上一条 [kHeaderHeight] 高、可拖动的空栏（窗口按钮叠在它右侧），下面是页面。别的平台原样返回。
class WindowPageFrame extends StatelessWidget {
  const WindowPageFrame({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (!windowControlsMerged) return child;
    return ColoredBox(
      color: context.mm.bg,
      child: Column(
        children: [
          WindowDragArea(
            child: SizedBox(height: kHeaderHeight, width: double.infinity),
          ),
          Expanded(child: child),
        ],
      ),
    );
  }
}

/// 桌面预览用的假窗口按钮（只在 Android 模拟器 + MEOWX_PREVIEW_DESKTOP 时画，见 [_previewDesktop]）
class PreviewWindowControls extends StatelessWidget {
  const PreviewWindowControls({super.key});

  @override
  Widget build(BuildContext context) {
    if (!_previewDesktop || system.isDesktop) return const SizedBox.shrink();
    final color = context.mm.t1;
    return Positioned(
      // 预览在 Android 上跑：页面上边距按非桌面算（widePagePadding 多 12），按钮跟着下移才看得出对不对齐
      top: windowControlsTop + 12,
      right: 4,
      child: IgnorePointer(
        child: Row(
          children: [
            for (final icon in [
              Icons.push_pin_outlined,
              Icons.remove,
              Icons.crop_square,
              Icons.close,
            ])
              SizedBox(
                width: 40,
                height: 40,
                child: Icon(icon, size: 20, color: color),
              ),
          ],
        ),
      ),
    );
  }
}
