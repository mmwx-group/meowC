import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';

import 'haptics.dart';

import 'm3.dart';
import 'motion.dart';
import 'tokens.dart';

/// 带回弹的对话框（2026-11-17 用户要求：首页卡片设置、节点页的视图选项这类「点按钮弹出来的设置」不用底部抽屉 / 锚点菜单）。
/// 弹出时从 85% 带一点回弹放大到原大并淡入（[MeowSprings.shapeCurve]），关时直接缩回淡出；系统「移除动画」时只淡入淡出。
/// 版式：M3 对话框（圆角 28、surfaceContainerHigh），标题行右边一个关闭钮，正文可滚，[actions] 在底部右对齐。
Future<T?> showMeowDialog<T>(
  BuildContext context, {
  required String title,
  required WidgetBuilder builder,
  List<Widget> Function(BuildContext context)? actions,
  double maxWidth = 420,
}) {
  final reduce = MeowMotion.reduced(context);
  return showGeneralDialog<T>(
    context: context,
    barrierDismissible: true,
    barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
    barrierColor: Colors.black.withValues(alpha: 0.4),
    transitionDuration: reduce ? const Duration(milliseconds: 150) : MeowSprings.shapeDuration + const Duration(milliseconds: 50),
    pageBuilder: (ctx, _, _) => _MeowDialog(title: title, builder: builder, actions: actions, maxWidth: maxWidth),
    transitionBuilder: (ctx, animation, _, child) {
      final fade = CurvedAnimation(parent: animation, curve: const Interval(0, 0.6, curve: Curves.easeOut));
      if (reduce) return FadeTransition(opacity: fade, child: child);
      final scale = CurvedAnimation(parent: animation, curve: const _PopoverSpring(), reverseCurve: Curves.easeInCubic);
      return FadeTransition(
        opacity: fade,
        child: ScaleTransition(scale: Tween(begin: 0.85, end: 1.0).animate(scale), child: child),
      );
    },
  );
}

class _MeowDialog extends StatelessWidget {
  const _MeowDialog({required this.title, required this.builder, required this.actions, required this.maxWidth});

  final String title;
  final WidgetBuilder builder;
  final List<Widget> Function(BuildContext context)? actions;
  final double maxWidth;

  @override
  Widget build(BuildContext context) {
    final cs = context.cs;
    final acts = actions?.call(context) ?? const [];
    return SafeArea(
      child: Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: maxWidth),
            child: Material(
              color: cs.surfaceContainerHigh,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(MeowShape.xl)),
              clipBehavior: Clip.antiAlias,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(24, 16, 12, 4),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            title,
                            style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800, color: cs.onSurface),
                          ),
                        ),
                        IconButton(
                          tooltip: '关闭',
                          onPressed: () => Navigator.of(context).pop(),
                          icon: Icon(Icons.close_rounded, color: cs.onSurfaceVariant),
                        ),
                      ],
                    ),
                  ),
                  Flexible(
                    child: SingleChildScrollView(
                      padding: EdgeInsets.fromLTRB(16, 4, 16, acts.isEmpty ? 20 : 8),
                      child: DefaultTextStyle.merge(
                        style: TextStyle(fontSize: MeowFont.body, color: cs.onSurface),
                        child: builder(context),
                      ),
                    ),
                  ),
                  if (acts.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          for (final (i, a) in acts.indexed) ...[if (i > 0) const SizedBox(width: 8), a],
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 对话框里一组选项的小标题（主色、粗字重）
class MeowDialogLabel extends StatelessWidget {
  const MeowDialogLabel(this.text, {super.key});
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(8, 12, 8, 8),
    child: Text(text, style: TextStyle(fontSize: MeowFont.footnote, fontWeight: FontWeight.w700, color: context.cs.primary)),
  );
}

/// 对话框里清单行的底色：对话框是 surfaceContainerHigh，行要比它浅一档才分得出（浅色 lowest、深色 low）
Color meowDialogRowColor(ColorScheme cs) =>
    cs.brightness == Brightness.dark ? cs.surfaceContainerLow : cs.surfaceContainerLowest;

/// 锚定在按钮上的气泡（iOS 27 那种：从按钮的位置长出来、带回弹，2026-11-17 用户要求右上角按钮用它、不用对话框）。
/// 放在按钮下方（下面放不下放上方），水平方向贴着按钮那一侧的边；从按钮中心所在的那一点按欠阻尼弹簧放大
/// （0.15 → 1，冲过头约 12% 再弹回，[_PopoverSpring]）并淡入，弹出时轻震一下；关时缩回那一点。
/// 点气泡外面关闭。系统「移除动画」时只淡入淡出、不震。
Future<T?> showMeowPopover<T>(
  BuildContext anchorContext, {
  required String title,
  required WidgetBuilder builder,
  double width = 320,
}) {
  final box = anchorContext.findRenderObject() as RenderBox?;
  final overlay = Overlay.of(anchorContext, rootOverlay: true).context.findRenderObject() as RenderBox?;
  if (box == null || overlay == null) return Future.value(null);
  final anchor = box.localToGlobal(Offset.zero, ancestor: overlay) & box.size;
  if (!MeowMotion.reduced(anchorContext)) MeowHaptics.tap();
  return Navigator.of(anchorContext, rootNavigator: true).push(
    _MeowPopoverRoute<T>(
      anchor: anchor,
      width: width,
      title: title,
      builder: builder,
      reduce: MeowMotion.reduced(anchorContext),
    ),
  );
}

class _MeowPopoverRoute<T> extends PopupRoute<T> {
  _MeowPopoverRoute({
    required this.anchor,
    required this.width,
    required this.title,
    required this.builder,
    required this.reduce,
  });

  final Rect anchor;
  final double width;
  final String title;
  final WidgetBuilder builder;
  final bool reduce;

  @override
  Color? get barrierColor => Colors.black.withValues(alpha: 0.12);
  @override
  bool get barrierDismissible => true;
  @override
  String? get barrierLabel => '关闭';
  @override
  Duration get transitionDuration => reduce ? const Duration(milliseconds: 150) : _PopoverSpring.duration;
  @override
  Duration get reverseTransitionDuration => Duration(milliseconds: reduce ? 120 : 200);

  @override
  Widget buildPage(BuildContext context, Animation<double> animation, Animation<double> secondaryAnimation) {
    final cs = context.cs;
    final screen = MediaQuery.sizeOf(context);
    final pad = MediaQuery.paddingOf(context);
    const margin = 12.0, gap = 8.0;
    final w = width.clamp(220.0, screen.width - margin * 2);
    // 水平：按钮在右半边就右边对齐按钮右沿，否则左边对齐左沿
    final rightSide = anchor.center.dx > screen.width / 2;
    final left = (rightSide ? anchor.right - w : anchor.left).clamp(margin, screen.width - w - margin);
    final spaceBelow = screen.height - pad.bottom - anchor.bottom - gap - margin;
    final spaceAbove = anchor.top - pad.top - gap - margin;
    final below = spaceBelow >= 240 || spaceBelow >= spaceAbove;
    final maxH = (below ? spaceBelow : spaceAbove).clamp(160.0, screen.height * 0.75);
    // 放大的原点：按钮中心在气泡里的相对位置（气泡顶 / 底贴着按钮）
    final originX = ((anchor.center.dx - left) / w).clamp(0.0, 1.0) * 2 - 1;
    final origin = Alignment(originX, below ? -1 : 1);

    final fade = CurvedAnimation(parent: animation, curve: const Interval(0, 0.5, curve: Curves.easeOut));
    final scale = CurvedAnimation(parent: animation, curve: const _PopoverSpring(), reverseCurve: Curves.easeInCubic);
    final bubble = Material(
      color: cs.surfaceContainerHigh,
      elevation: 8,
      shadowColor: Colors.black.withValues(alpha: 0.3),
      borderRadius: BorderRadius.circular(MeowShape.xl),
      clipBehavior: Clip.antiAlias,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: maxH),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 4),
              child: Text(title, style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800, color: cs.onSurface)),
            ),
            Flexible(
              child: SingleChildScrollView(padding: const EdgeInsets.fromLTRB(12, 4, 12, 14), child: builder(context)),
            ),
          ],
        ),
      ),
    );
    return Stack(
      children: [
        Positioned(
          left: left,
          width: w,
          top: below ? anchor.bottom + gap : null,
          bottom: below ? null : screen.height - anchor.top + gap,
          child: FadeTransition(
            opacity: fade,
            child: reduce
                ? bubble
                : ScaleTransition(scale: Tween(begin: 0.15, end: 1.0).animate(scale), alignment: origin, child: bubble),
          ),
        ),
      ],
    );
  }
}

/// 气泡弹出用的欠阻尼弹簧（质量 1、刚度 400、阻尼比 0.55）：约 0.17 秒到位、冲过头约 12%、再小幅回摆一下停住，
/// 是 iOS 弹出菜单那种明显的「啵」一下。按 [duration] 归一成曲线交给路由动画，末尾钉在 1（那时余振已不到 0.5%）。
class _PopoverSpring extends Curve {
  const _PopoverSpring();

  static const duration = Duration(milliseconds: 600);
  static final _spring = SpringDescription.withDampingRatio(mass: 1, stiffness: 400, ratio: 0.55);
  static final _sim = SpringSimulation(_spring, 0, 1, 0);

  @override
  double transformInternal(double t) => _sim.x(t * duration.inMicroseconds / 1e6);
}
