import 'package:flutter/material.dart';

import '../app/window_controls.dart';
import 'm3.dart';
import 'tokens.dart';
import 'widgets.dart';

/// 页内标题：26pt bold，作为内容首行随滚动走；右侧可放圆形按钮。
/// Windows：窗口按钮并在这一行的最右边（见 window_controls.dart），这里让出位置、整行可拖动窗口。
class PageTitle extends StatelessWidget {
  const PageTitle(this.title, {super.key, this.trailing, this.subtitle});

  final String title;
  final Widget? trailing;
  final Widget? subtitle;

  @override
  Widget build(BuildContext context) {
    final mm = context.mm;
    return WindowDragArea(
      child: Padding(
        padding: EdgeInsets.only(
          top: 6,
          right: windowControlsShown ? windowControlsReserve : 0,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    title,
                    style: TextStyle(
                      fontSize: 30,
                      fontWeight: FontWeight.w900,
                      letterSpacing: -0.2,
                      color: mm.t1,
                      height: 1.15,
                    ),
                  ),
                ),
                ?trailing,
              ],
            ),
            if (subtitle != null) ...[const SizedBox(height: 2), subtitle!],
          ],
        ),
      ),
    );
  }
}

/// 标题右侧的圆形按钮（48，M3 的 surfaceContainerHighest 底；[filled] = 主色实底，用于该页的主操作）。
class RoundGlassButton extends StatelessWidget {
  const RoundGlassButton({
    super.key,
    this.icon,
    this.glyph,
    required this.onTap,
    this.color,
    this.busy = false,
    this.tooltip,
    this.filled = false,
  });

  /// [icon]（Material 图标）与 [glyph]（设计稿的线性图标）二选一
  final IconData? icon;
  final MeowGlyph? glyph;
  final VoidCallback? onTap;
  final Color? color;
  final bool busy;
  final String? tooltip;
  final bool filled;

  @override
  Widget build(BuildContext context) {
    final cs = context.cs;
    final fg = color ?? (filled ? cs.onPrimary : cs.onSurface);
    final btn = Material(
      color: filled ? cs.primary : cs.surfaceContainerHighest,
      shape: const CircleBorder(),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: busy ? null : onTap,
        child: SizedBox.square(
          dimension: 48,
          child: Center(
            child: busy
                ? SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2.2, color: fg))
                : glyph != null
                ? MeowIcon(glyph!, size: 22, color: fg)
                : Icon(icon, size: 24, color: fg),
          ),
        ),
      ),
    );
    return tooltip == null ? btn : Tooltip(message: tooltip!, child: btn);
  }
}
