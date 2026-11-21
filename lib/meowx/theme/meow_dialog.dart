import 'dart:ui' show ImageFilter, lerpDouble;

import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';

import '../app/glass_host.dart' show MeowGlassDevice;
import 'droplet_morph.dart';
import 'glass.dart';
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
  final springCurve = _AlertSpring.tuned();
  return showGeneralDialog<T>(
    context: context,
    barrierDismissible: true,
    barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
    barrierColor: Colors.black.withValues(alpha: 0.34),
    transitionDuration: reduce ? const Duration(milliseconds: 150) : MeowMotion.of(context, _AlertSpring.duration),
    pageBuilder: (ctx, _, _) => _MeowDialog(title: title, builder: builder, actions: actions, maxWidth: maxWidth),
    transitionBuilder: (ctx, animation, _, child) {
      if (reduce) {
        final fade = CurvedAnimation(parent: animation, curve: Curves.easeOut);
        return FadeTransition(opacity: fade, child: child);
      }
      final t = animation.value;
      final reversing = animation.status == AnimationStatus.reverse;
      // 对齐 iOS 27 原生 UIAlertController / prism_ui：打开从 1.2× 临界阻尼缩小落位到 1.0×，关闭时原地纯淡出不缩放
      final springT = reversing ? springCurve.flipped.transform(t) : springCurve.transform(t);
      final scale = reversing ? 1.0 : lerpDouble(1.2, 1.0, springT)!;
      final opacity = springT.clamp(0.0, 1.0);
      final bgSigma = MeowGlassDevice.lowEnd ? 0.0 : 4.0 * opacity;

      final modal = Opacity(
        opacity: opacity,
        child: Transform.scale(scale: scale, child: child),
      );
      if (bgSigma <= 0.2) return modal;
      return Stack(
        fit: StackFit.expand,
        children: [
          IgnorePointer(
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: bgSigma, sigmaY: bgSigma),
              child: const SizedBox.expand(),
            ),
          ),
          modal,
        ],
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
    final glass = meowPopupGlassOn(context);
    final radius = BorderRadius.circular(MeowShape.xl);
    final body = Column(
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
    );
    final surface = glass
        ? MeowGlassBox(
            style: MeowGlassStyles.menu(context),
            radius: radius,
            rim: MeowGlassStyles.menuRim(context),
            shadows: MeowGlassStyles.menuShadows(context),
            child: Material(
              type: MaterialType.transparency,
              borderRadius: radius,
              clipBehavior: Clip.antiAlias,
              child: Theme(data: meowOnGlassTheme(Theme.of(context)), child: body),
            ),
          )
        : Material(
            color: cs.surfaceContainerHigh,
            shape: RoundedRectangleBorder(
              borderRadius: radius,
              side: BorderSide(color: cs.cardBorder, width: 0.8),
            ),
            clipBehavior: Clip.antiAlias,
            child: body,
          );
    return SafeArea(
      child: Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
          child: ConstrainedBox(constraints: BoxConstraints(maxWidth: maxWidth), child: surface),
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

/// 玻璃气泡里的内容：把清单行、分段槽与边框换成干净通透的浅层半透明材质，在柔雾玻璃上层次分明不发灰。
ThemeData meowOnGlassTheme(ThemeData t) {
  final dark = t.brightness == Brightness.dark;
  final cs = t.colorScheme.copyWith(
    surfaceContainerLowest: dark ? Colors.white.withValues(alpha: 0.08) : Colors.white.withValues(alpha: 0.72),
    surfaceContainerLow: dark ? Colors.white.withValues(alpha: 0.07) : Colors.white.withValues(alpha: 0.65),
    surfaceContainer: dark ? Colors.white.withValues(alpha: 0.08) : Colors.black.withValues(alpha: 0.04),
    surfaceContainerHigh: dark ? Colors.white.withValues(alpha: 0.10) : Colors.black.withValues(alpha: 0.055),
    surfaceContainerHighest: dark ? Colors.white.withValues(alpha: 0.11) : Colors.black.withValues(alpha: 0.065),
    outlineVariant: dark ? Colors.white.withValues(alpha: 0.12) : Colors.black.withValues(alpha: 0.08),
  );
  return t.copyWith(colorScheme: cs);
}

/// 对话框里清单行的底色：对话框是 surfaceContainerHigh，行要比它浅一档才分得出（浅色 lowest、深色 low）
Color meowDialogRowColor(ColorScheme cs) =>
    cs.brightness == Brightness.dark ? cs.surfaceContainerLow : cs.surfaceContainerLowest;

/// 锚定在按钮上的气泡（iOS 27 的 popover，水滴变形见 [DropletMorph]）：
/// 按钮缩成一颗圆、长成气泡（先冲过头再弹回），内容按最终尺寸钉着、先糊后清；关时糊掉缩回按钮成一颗倒水滴。弹出时轻震一下。
/// 气泡盖住按钮（顶边对齐按钮顶边，同 iOS），背后不压暗。
/// 有玻璃宿主（手机，底栏的那一套）时面板是液态玻璃（菜单那一档），否则是实色 surfaceContainerHigh。
/// 放在按钮下方（下面放不下放上方），水平方向贴着按钮那一侧的边。点气泡外面关闭；里面的开关点了不收。
/// 系统「移除动画」时只淡入淡出、不震。
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
  Color? get barrierColor => null;
  @override
  bool get barrierDismissible => true;

  // 背后不挡手势（同 iOS 27）：点外面只关气泡，拖动外面关气泡并照常滚动页面
  /// 在外面拖动时先把气泡藏起来（见 [DropletPassThroughBarrier]）
  final _hidden = ValueNotifier(false);

  @override
  void dispose() {
    _hidden.dispose();
    super.dispose();
  }

  @override
  Widget buildModalBarrier() => DropletPassThroughBarrier(
    onHide: () => _hidden.value = true,
    onDismiss: () {
      if (isCurrent) navigator?.pop();
    },
  );
  @override
  String? get barrierLabel => '关闭';
  @override
  Duration get transitionDuration => const Duration(milliseconds: 150); // 只给「移除动画」时的淡入用；变形由面板自己的时钟驱动
  @override
  Duration get reverseTransitionDuration => reduce ? const Duration(milliseconds: 120) : DropletMorph.closeDuration;

  @override
  Widget buildPage(BuildContext context, Animation<double> animation, Animation<double> secondaryAnimation) =>
      DropletHideOnDrag(hidden: _hidden, child: _MeowPopoverPanel(route: this, animation: animation));
}

class _MeowPopoverPanel extends StatefulWidget {
  const _MeowPopoverPanel({required this.route, required this.animation});
  final _MeowPopoverRoute<dynamic> route;
  final Animation<double> animation;

  @override
  State<_MeowPopoverPanel> createState() => _MeowPopoverPanelState();
}

class _MeowPopoverPanelState extends State<_MeowPopoverPanel> with SingleTickerProviderStateMixin {
  /// 内容（标题 + 正文）带全局 key：先在台下量出尺寸，量好挪进面板里，状态不丢
  final _contentKey = GlobalKey();

  /// 量出来的气泡尺寸；null = 还没量（这一帧只在台下排版、不画）
  Size? _size;

  /// 变形进度（自己的弹簧，不用路由动画）：量好尺寸、第一帧画出来之后才开始弹——
  /// 以前跟着路由动画走，台下量尺寸那一帧和第一帧的卡顿都算进了时间，画面出来时已经快展开完了（用户：一瞬间就展开）
  late final _morph = DropletMotion(this, settled: widget.route.reduce);
  bool _started = false;

  @override
  void initState() {
    super.initState();
    widget.animation.addStatusListener(_onStatus);
    WidgetsBinding.instance.addPostFrameCallback((_) => _measure());
  }

  @override
  void dispose() {
    widget.animation.removeStatusListener(_onStatus);
    _morph.dispose();
    super.dispose();
  }

  void _measure() {
    if (!mounted) return;
    final size = _contentKey.currentContext?.size;
    if (size != null && size != _size) setState(() => _size = size);
    if (size != null && !_started && !widget.route.reduce) {
      _started = true;
      // 气泡的第一帧（p = 0 的水滴）画出来之后再开始计时
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && widget.animation.status != AnimationStatus.reverse) {
          _morph.open();
        }
      });
    }
  }

  /// 开始关：按此刻的内容尺寸缩回（打开期间内容可能变高 / 变矮）
  void _onStatus(AnimationStatus status) {
    if (status != AnimationStatus.reverse) return;
    _measure();
    if (!widget.route.reduce) _morph.close();
  }

  @override
  Widget build(BuildContext context) {
    final route = widget.route;
    final anchor = route.anchor;
    final cs = context.cs;
    final screen = MediaQuery.sizeOf(context);
    final pad = MediaQuery.paddingOf(context);
    const margin = 12.0, gap = 0.0;   // gap 0：盖住按钮（同 iOS）
    final w = route.width.clamp(220.0, screen.width - margin * 2);
    // 水平：按钮在右半边就右边对齐按钮右沿，否则左边对齐左沿
    final rightSide = anchor.center.dx > screen.width / 2;
    final left = (rightSide ? anchor.right - w : anchor.left).clamp(margin, screen.width - w - margin);
    final spaceBelow = screen.height - pad.bottom - anchor.top - margin;
    final spaceAbove = anchor.bottom - pad.top - margin;
    final below = spaceBelow >= 240 || spaceBelow >= spaceAbove;
    final maxH = (below ? spaceBelow : spaceAbove).clamp(160.0, screen.height * 0.75);
    final glass = meowPopupGlassOn(context);

    final body = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 4),
          child: Text(route.title, style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800, color: cs.onSurface)),
        ),
        Flexible(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 14),
            child: Builder(builder: route.builder),
          ),
        ),
      ],
    );
    final content = KeyedSubtree(
      key: _contentKey,
      child: SizedBox(
        width: w,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: maxH),
          child: Material(
            type: MaterialType.transparency,
            // 玻璃气泡里的行 / 分段 / 开关轨道换成半透明（同 iOS：透得出玻璃），实色气泡照旧
            child: glass ? Theme(data: meowOnGlassTheme(Theme.of(context)), child: body) : body,
          ),
        ),
      ),
    );

    final size = _size;
    if (size == null) {
      // 第一帧：台下排版量尺寸，不画
      return Stack(children: [Positioned(left: left, top: 0, child: Offstage(child: content))]);
    }
    // 内容尺寸变了（打开后有行出现 / 消失）：下一帧按新尺寸
    WidgetsBinding.instance.addPostFrameCallback((_) => _measure());
    final target = Rect.fromLTWH(left, below ? anchor.top + gap : anchor.bottom - gap - size.height, w, size.height);

    final allowed = Rect.fromLTRB(margin, pad.top + margin, screen.width - margin, screen.height - pad.bottom - margin);
    final glassStyle = glass ? MeowGlassStyles.popover(context) : null;
    final glassRim = glass ? MeowGlassStyles.menuRim(context) : null;
    final shadows = glass ? MeowGlassStyles.menuShadows(context) : const <BoxShadow>[];

    return Stack(
      children: [
        AnimatedBuilder(
          animation: Listenable.merge([_morph, widget.animation]),
          builder: (context, child) {
            final m = _morph;
            final frame = route.reduce
                ? DropletFrame.settled(target, MeowShape.xl)
                : m.closing
                ? DropletMorph.close(
                    anchor: anchor,
                    target: target,
                    finalRadius: MeowShape.xl,
                    raw: m.raw,
                    elapsed: m.elapsed,
                    closeStart: m.closeStart,
                    menu: false,
                  )
                : DropletMorph.open(
                    anchor: anchor,
                    target: target,
                    finalRadius: MeowShape.xl,
                    raw: m.raw,
                    elapsed: m.elapsed,
                    allowed: allowed,
                  );
            final surface = DropletSurface(
              frame: frame,
              target: target,
              glassStyle: glassStyle,
              glassRim: glassRim,
              shadows: shadows,
              color: cs.surfaceContainerHigh,
              shadowColor: const Color(0x38000000),
              blur: !MeowGlassDevice.lowEnd,
              child: child!,
            );
            // 「移除动画」：直接在终态，跟着路由淡入淡出
            if (!route.reduce) return surface;
            return Positioned.fill(
              child: Opacity(opacity: widget.animation.value, child: Stack(children: [surface])),
            );
          },
          // 内容自成一层：变形每帧只改面板的形状和内容的位移，内容不跟着重画
          child: RepaintBoundary(child: content),
        ),
      ],
    );
  }
}

/// iOS 27 原生弹窗临界阻尼弹簧（对齐 prism_ui：275ms 周期临界阻尼，404ms 收稳，补齐残余量确保精确落到 1）。
class _AlertSpring extends Curve {
  _AlertSpring(SpringDescription spring) : _sim = SpringSimulation(spring, 0, 1, 0);

  factory _AlertSpring.tuned() => _AlertSpring(
    MeowMotion.tuned(SpringDescription.withDampingRatio(mass: 1, stiffness: 522, ratio: 1.0)),
  );

  static const duration = Duration(milliseconds: 404);
  static const _seconds = 0.404;
  final SpringSimulation _sim;
  late final double _residual = 1 - _sim.x(_seconds);

  @override
  double transformInternal(double t) => _sim.x(t * _seconds) + _residual * t;
}
