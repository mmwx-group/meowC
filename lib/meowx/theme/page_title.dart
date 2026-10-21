import 'package:flutter/material.dart';

import '../app/window_controls.dart';
import 'glass.dart';
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
                      fontSize: MeowFont.pageTitle,
                      fontWeight: FontWeight.bold,
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

/// 标题右侧的圆形按钮（44，卡片底；[filled] = 墨色实底，用于该页的主操作）。
/// 液态玻璃主题下非实底的那种换成玻璃圆钮（[MeowGlassButton]）；实底的主操作仍是墨色实心块。
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
    final mm = context.mm;
    if (!filled && meowGlassOn(context)) {
      return MeowGlassButton(
        onTap: busy ? null : onTap,
        tooltip: tooltip,
        child: SizedBox(
          width: 44,
          height: 44,
          child: Center(child: _content(mm)),
        ),
      );
    }
    final btn = Material(
      color: filled ? mm.t1 : mm.elev,
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: busy ? null : onTap,
        child: SizedBox(
          width: 44,
          height: 44,
          child: Center(child: _content(mm)),
        ),
      ),
    );
    return tooltip == null ? btn : Tooltip(message: tooltip!, child: btn);
  }

  Widget _content(MeowTokens mm) => busy
      ? SizedBox(
          width: 14,
          height: 14,
          child: CircularProgressIndicator(
            strokeWidth: 2,
            color: filled ? mm.bg : mm.t2,
          ),
        )
      : glyph != null
      ? MeowIcon(glyph!, size: 20, color: color ?? (filled ? mm.bg : mm.t1))
      : Icon(icon, size: 20, color: color ?? (filled ? mm.bg : mm.t1));
}
