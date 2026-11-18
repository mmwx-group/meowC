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

/// 锚定在按钮上的气泡（iOS 27 的 popover，2026-11-18 对着 iOS 模拟器录屏逐帧照抄，见 [DropletMorph]）：
/// 从按钮中心冒出一颗水滴、弹簧长成气泡（冲过头一点再回），内容跟着面板拉伸、先糊后清；关时糊掉缩回水滴。弹出时轻震一下。
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
      fromColor: Theme.of(anchorContext).colorScheme.surfaceContainerHighest,
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
    required this.fromColor,
  });

  final Rect anchor;
  final double width;
  final String title;
  final WidgetBuilder builder;
  final bool reduce;

  /// 按钮的底色：实色面板从它过渡到气泡的颜色
  final Color fromColor;

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
  Duration get transitionDuration => reduce ? const Duration(milliseconds: 150) : DropletSpringCurve.duration;
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
  late final _morph = AnimationController.unbounded(vsync: this, value: widget.route.reduce ? 1 : 0);
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
          _morph.animateWith(SpringSimulation(DropletMorph.spring, _morph.value, 1, 0));
        }
      });
    }
  }

  /// 开始关：按此刻的内容尺寸缩回（打开期间内容可能变高 / 变矮）
  void _onStatus(AnimationStatus status) {
    if (status != AnimationStatus.reverse) return;
    _measure();
    if (!widget.route.reduce) _morph.animateTo(0, duration: DropletMorph.closeDuration, curve: DropletMorph.closeCurve);
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

    final content = KeyedSubtree(
      key: _contentKey,
      child: SizedBox(
        width: w,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: maxH),
          child: Material(
            type: MaterialType.transparency,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 16, 20, 4),
                  child: Text(route.title, style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800, color: cs.onSurface)),
                ),
                Flexible(
                  child: SingleChildScrollView(padding: const EdgeInsets.fromLTRB(12, 4, 12, 14), child: route.builder(context)),
                ),
              ],
            ),
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

    return Stack(
      children: [
        AnimatedBuilder(
          animation: _morph,
          builder: (context, child) {
            final p = route.reduce ? 1.0 : _morph.value;
            final pc = p.clamp(0.0, 1.0);
            final r = DropletMorph.rect(anchor, target, p);
            final radius = BorderRadius.circular(DropletMorph.radius(r, MeowShape.xl, p));
            final clipped = ClipRRect(
              borderRadius: radius,
              child: route.reduce
                  ? Opacity(opacity: widget.animation.value, child: child)
                  : DropletMorph.content(child: child!, r: r, target: target, p: p, blur: !MeowGlassDevice.lowEnd),
            );
            final Widget panel = glass
                ? MeowGlassBox(
                    style: MeowGlassStyles.menu(context).scale(DropletMorph.glassAmount(p)),
                    radius: radius,
                    rim: MeowGlassStyles.menuRim(context).scale(DropletMorph.glassAmount(p)),
                    shadows: MeowGlassStyles.menuShadows(context, pc),
                    child: clipped,
                  )
                : DecoratedBox(
                    decoration: BoxDecoration(
                      color: Color.lerp(route.fromColor, cs.surfaceContainerHigh, pc),
                      borderRadius: radius,
                      boxShadow: [
                        BoxShadow(color: Colors.black.withValues(alpha: 0.22 * pc), blurRadius: 24, offset: const Offset(0, 8)),
                      ],
                    ),
                    child: clipped,
                  );
            return Positioned.fromRect(
              rect: r,
              child: Opacity(opacity: route.reduce ? widget.animation.value : DropletMorph.panelOpacity(p), child: panel),
            );
          },
          // 内容自成一层：变形每帧只改面板的矩形 / 圆角和内容的位移，内容不跟着重画
          child: RepaintBoundary(child: content),
        ),
      ],
    );
  }
}

/// 对话框弹出用的欠阻尼弹簧（质量 1、刚度 400、阻尼比 0.55）：约 0.17 秒到位、冲过头约 12%、再小幅回摆一下停住，
/// 是 iOS 弹出菜单那种明显的「啵」一下。按 [duration] 归一成曲线交给路由动画，末尾钉在 1（那时余振已不到 0.5%）。
class _PopoverSpring extends Curve {
  const _PopoverSpring();

  static const duration = Duration(milliseconds: 600);
  static final _spring = SpringDescription.withDampingRatio(mass: 1, stiffness: 400, ratio: 0.55);
  static final _sim = SpringSimulation(_spring, 0, 1, 0);

  @override
  double transformInternal(double t) => _sim.x(t * duration.inMicroseconds / 1e6);
}
