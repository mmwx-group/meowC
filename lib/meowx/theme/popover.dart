import 'package:flutter/material.dart';

import 'tokens.dart';

/// 锚定在某个控件下方（放不下则上方）的小气泡；点气泡外任何地方关闭。
/// 对齐 iOS 端奖牌 / 解锁详情用的 popover（Flutter 没有系统 popover，自己用 PopupRoute 拼）。
Future<T?> showAnchoredPopover<T>(
  BuildContext anchorContext, {
  required WidgetBuilder builder,
  double width = 300,
}) {
  final box = anchorContext.findRenderObject() as RenderBox?;
  final overlay = Overlay.of(anchorContext, rootOverlay: true).context.findRenderObject() as RenderBox?;
  if (box == null || overlay == null) return Future.value(null);
  final anchor = box.localToGlobal(Offset.zero, ancestor: overlay) & box.size;
  return Navigator.of(anchorContext, rootNavigator: true).push(_PopoverRoute<T>(anchor: anchor, width: width, builder: builder));
}

class _PopoverRoute<T> extends PopupRoute<T> {
  _PopoverRoute({required this.anchor, required this.width, required this.builder});

  final Rect anchor;
  final double width;
  final WidgetBuilder builder;

  @override
  Color? get barrierColor => Colors.transparent;
  @override
  bool get barrierDismissible => true;
  @override
  String? get barrierLabel => '关闭';
  @override
  Duration get transitionDuration => const Duration(milliseconds: 160);

  @override
  Widget buildPage(BuildContext context, Animation<double> animation, Animation<double> secondaryAnimation) {
    final mm = context.mm;
    final screen = MediaQuery.sizeOf(context);
    final padding = MediaQuery.paddingOf(context);
    final maxH = screen.height * 0.6;
    final w = width.clamp(200.0, screen.width - 16);
    final left = (anchor.center.dx - w / 2).clamp(8.0, screen.width - w - 8);
    final spaceBelow = screen.height - padding.bottom - anchor.bottom - 8;
    final below = spaceBelow >= 180 || spaceBelow >= anchor.top - padding.top;
    final top = below ? anchor.bottom + 6 : null;
    final bottom = below ? null : screen.height - anchor.top + 6;
    final available = below ? spaceBelow - 6 : anchor.top - padding.top - 14;
    return Stack(
      children: [
        Positioned(
          left: left,
          top: top,
          bottom: bottom,
          width: w,
          child: FadeTransition(
            opacity: CurvedAnimation(parent: animation, curve: Curves.easeOut),
            child: ScaleTransition(
              scale: Tween(begin: 0.96, end: 1.0).animate(CurvedAnimation(parent: animation, curve: Curves.easeOut)),
              alignment: below ? Alignment.topCenter : Alignment.bottomCenter,
              child: Material(
                color: mm.elevSolid,
                elevation: 12,
                shadowColor: Colors.black.withValues(alpha: 0.35),
                borderRadius: BorderRadius.circular(14),
                clipBehavior: Clip.antiAlias,
                child: ConstrainedBox(
                  constraints: BoxConstraints(maxHeight: available.clamp(120.0, maxH)),
                  child: builder(context),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
