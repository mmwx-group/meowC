import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../glass/liquid_glass.dart';
import '../../theme/glass.dart';
import '../../theme/motion.dart';
import '../../theme/tokens.dart';
import 'me_kit.dart';

/// 手机「我的」页的设置卡片（设计稿方案 B「底部卡片」）：点入口从底部升起一张卡片装这一组的行，
/// 背后加遮罩、「我的」页缩小退后；点遮罩 / 右上角 × / 下拉 / 系统返回键关闭。
/// 卡片高度贴合内容（最高约屏幕 88%，超出在卡片里滚动），开关带出的行、进出下一层时卡片随内容平滑长高 / 变矮。
/// 分组里的下一层（DNS 劫持、绕过、po0 服务器等，经 [mePush]）在卡片里进：卡片拉到最高、内容左右平推、页头换成下一层的标题。
/// 液态玻璃主题下卡片浮起来（同 iOS 26 的半高 sheet）：左右和底边各留 8、圆角与屏幕圆角同心、玻璃底（菜单那一档的厚度），
/// 里面的白卡分组改成半透明；经典主题保持贴边的实色卡片。

/// 从底部升起设置卡片，[page] 是第一层（一般是 [MeSubPage.list]）。关掉时返回。
Future<void> showMeSheet(BuildContext context, Widget page) {
  final reduce = MeowMotion.reduced(context);
  final route = _MeSheetRoute(page: page, reduce: reduce);
  final closed = Navigator.of(context, rootNavigator: true).push(route);
  // 「移除动画」时背后页面不缩放，只有卡片淡入淡出
  if (!reduce) context.findAncestorStateOfType<_MeSheetBackdropState>()?._track(route.curved);
  return closed;
}

/// 设置卡片背后的整页（「我的」页 + 底栏）：卡片升起时缩小一点、下移、加圆角，四周露出黑底（同 iOS sheet）。
/// 挂在壳上（meow_root.dart）；没有它时卡片照常弹出，只是背后不缩放。
class MeSheetBackdrop extends StatefulWidget {
  const MeSheetBackdrop({super.key, required this.child});

  final Widget child;

  @override
  State<MeSheetBackdrop> createState() => _MeSheetBackdropState();
}

class _MeSheetBackdropState extends State<MeSheetBackdrop> {
  Animation<double> _animation = kAlwaysDismissedAnimation;

  void _track(Animation<double> animation) {
    setState(() => _animation = animation);
    // 卡片完全收起后放开它的动画（路由销毁时连同动画一起释放）
    animation.addStatusListener((status) {
      if (status == AnimationStatus.dismissed && identical(_animation, animation) && mounted) {
        setState(() => _animation = kAlwaysDismissedAnimation);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    // 静止时变换是单位矩阵、不裁剪、底色透明：不多出任何合成层；各层的类型始终不变，整页的状态不会因开关卡片重建
    return AnimatedBuilder(
      animation: _animation,
      child: widget.child,
      builder: (context, child) {
        final t = _animation.value;
        final scale = 1 - (1 - MeowMotion.sheetBackdropScale) * t;
        return ColoredBox(
          color: t > 0 ? const Color(0xFF000000) : const Color(0x00000000),
          child: Transform(
            alignment: Alignment.center,
            transform: Matrix4.translationValues(0, MeowMotion.sheetBackdropShift * t, 0)
              ..multiply(Matrix4.diagonal3Values(scale, scale, 1)),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(MeowMotion.sheetBackdropRadius * t),
              clipBehavior: t > 0 ? Clip.antiAlias : Clip.none,
              child: child,
            ),
          ),
        );
      },
    );
  }
}

class _MeSheetRoute extends PopupRoute<void> {
  _MeSheetRoute({required this.page, required this.reduce});

  final Widget page;
  final bool reduce;

  /// 升起 / 收起的进度：升起减速，收起反过来先快后慢（都是 iOS sheet 的曲线）
  late final CurvedAnimation curved = CurvedAnimation(
    parent: animation!,
    curve: MeowMotion.sheetCurve,
    reverseCurve: MeowMotion.sheetCurve.flipped,
  );

  // 遮罩自己画（点遮罩要关掉整张卡片；系统的遮罩走 maybePop，在第二层时只会退一层）
  @override
  Color? get barrierColor => null;

  @override
  bool get barrierDismissible => false;

  @override
  String? get barrierLabel => null;

  @override
  Duration get transitionDuration => reduce ? MeowMotion.sheetFade : MeowMotion.sheetRise;

  @override
  Duration get reverseTransitionDuration => reduce ? MeowMotion.sheetFade : MeowMotion.sheetFall;

  @override
  Widget buildPage(BuildContext context, Animation<double> animation, Animation<double> secondaryAnimation) =>
      _MeSheet(route: this);

  @override
  void dispose() {
    curved.dispose();
    super.dispose();
  }
}

/// 卡片里的一层。
class _Pane {
  _Pane(this.page);

  final Widget page;
  final Key key = UniqueKey();
}

class _MeSheet extends StatefulWidget {
  const _MeSheet({required this.route});

  final _MeSheetRoute route;

  @override
  State<_MeSheet> createState() => _MeSheetState();
}

class _MeSheetState extends State<_MeSheet> with TickerProviderStateMixin implements MeSheetNavigator {
  late final List<_Pane> _stack = [_Pane(widget.route.page)];

  /// 正在退场的那一层（进出下一层的平推过程中才有）；[_backward] = 这次是返回
  _Pane? _leaving;
  bool _backward = false;
  bool _closing = false;

  late final AnimationController _pane =
      AnimationController(vsync: this, duration: widget.route.reduce ? MeowMotion.sheetFade : MeowMotion.sheetPane)
        ..addStatusListener((status) {
          if (status == AnimationStatus.completed && mounted) setState(() => _leaving = null);
        });

  /// 下拉的距离（逻辑像素）；松手没到关闭的阈值就弹回 0
  late final AnimationController _drag = AnimationController.unbounded(vsync: this);

  @override
  void dispose() {
    _pane.dispose();
    _drag.dispose();
    super.dispose();
  }

  /// 上一次平推还没走完就又进 / 退：直接结束它
  void _settlePane() {
    _pane.stop();
    _leaving = null;
  }

  @override
  void push(Widget page) {
    if (_closing) return;
    setState(() {
      _settlePane();
      _leaving = _stack.last;
      _backward = false;
      _stack.add(_Pane(page));
    });
    _pane.forward(from: 0);
  }

  @override
  void back() {
    if (_stack.length == 1) return close();
    setState(() {
      _settlePane();
      _leaving = _stack.removeLast();
      _backward = true;
    });
    _pane.forward(from: 0);
  }

  @override
  void close() {
    if (_closing || !widget.route.isCurrent) return;
    _closing = true;
    widget.route.navigator!.pop();
  }

  void _onDragUpdate(DragUpdateDetails d) {
    if (_closing) return;
    _drag.value = math.max(0, _drag.value + d.primaryDelta!);
  }

  void _onDragEnd(DragEndDetails d) {
    if (_closing) return;
    if (_drag.value > MeowMotion.sheetDismissDistance || (d.primaryVelocity ?? 0) > MeowMotion.sheetDismissVelocity) {
      close();
    } else {
      _drag.animateTo(
        0,
        duration: MeowMotion.of(context, const Duration(milliseconds: 250)),
        curve: Curves.easeOutCubic,
      );
    }
  }

  /// 各层叠在一起：当前层决定高度；退场的那层不占高度（溢出画出来，由外面的 AnimatedSize 裁掉），
  /// 这样返回时卡片从最高缩回上一层的高度与平推同时进行。第二层起固定为最高。
  Widget _panes(double maxBody) {
    final reduce = widget.route.reduce;
    final top = _stack.last;
    final leaving = _leaving;
    // 叠放顺序按层级：进下一层时新页盖在旧页上，返回时退场的那层仍在上面
    final panes = [
      if (leaving != null && !_backward) (leaving, _stack.length - 1),
      (top, _stack.length),
      if (leaving != null && _backward) (leaving, _stack.length + 1),
    ];
    return AnimatedBuilder(
      animation: _pane,
      builder: (context, _) {
        final t = MeowMotion.sheetPaneCurve.transform(_pane.value);
        final fade = const Interval(0, 0.6).transform(_pane.value);
        final shift = reduce ? 0.0 : MeowMotion.sheetPaneShift;
        return Stack(
          clipBehavior: Clip.none,
          children: [
            for (final (p, depth) in panes)
              KeyedSubtree(
                key: p.key,
                child: _paneSlot(
                  page: p.page,
                  depth: depth,
                  maxBody: maxBody,
                  collapsed: p != top,
                  dx: leaving == null
                      ? 0
                      : p == top
                      ? (_backward ? -shift : shift) * (1 - t)
                      : (_backward ? shift : -shift) * t,
                  opacity: leaving == null ? 1 : (p == top ? fade : 1 - fade),
                ),
              ),
          ],
        );
      },
    );
  }

  /// 一层的外壳：组件类型始终不变（换角色只改参数），平推前后这一层的状态（滚动位置等）不丢。
  Widget _paneSlot({
    required Widget page,
    required int depth,
    required double maxBody,
    required bool collapsed,
    required double dx,
    required double opacity,
  }) {
    final scoped = MeSheetScope(depth: depth, navigator: this, glass: meowGlassOn(context), child: page);
    return IgnorePointer(
      ignoring: collapsed,
      child: Opacity(
        opacity: opacity,
        child: FractionalTranslation(
          translation: Offset(dx, 0),
          // 退场的那层高度记 0、内容照常排开并溢出画出来
          child: Align(
            alignment: Alignment.topCenter,
            heightFactor: collapsed ? 0 : 1,
            child: depth > 1 ? SizedBox(height: maxBody, child: scoped) : scoped,
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final mm = context.mm;
    final route = widget.route;
    final reduce = route.reduce;
    final rise = reduce ? route.animation! : route.curved;
    final glass = meowGlassOn(context);
    final inset = glass ? MeowGlassMetrics.sheetInset : 0.0;
    final mq = MediaQuery.of(context);
    final maxHeight = (mq.size.height - mq.padding.top) * MeowMotion.sheetMaxHeight - inset;
    final scrim = Theme.of(context).brightness == Brightness.dark ? const Color(0x8C000000) : const Color(0x52140E16);
    const grabZone = 8.0 + 5 + 2;

    final body = Stack(
      children: [
        Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: Container(
                width: 36,
                height: 5,
                margin: const EdgeInsets.only(top: 8, bottom: 2),
                decoration: BoxDecoration(color: mm.t2.withValues(alpha: 0.3), borderRadius: BorderRadius.circular(3)),
              ),
            ),
            Flexible(
              child: LayoutBuilder(
                builder: (context, constraints) => AnimatedSize(
                  // 「移除动画」时直接到新高度（给 1ms：零时长会让 AnimatedSize 在自己的布局里同步通知、触发框架断言）
                  duration: reduce ? const Duration(milliseconds: 1) : MeowMotion.sheetResize,
                  curve: MeowMotion.sheetCurve,
                  alignment: Alignment.topCenter,
                  child: _panes(constraints.maxHeight),
                ),
              ),
            ),
          ],
        ),
        // 关闭钮固定在右上角，与各层的页头对齐（页头右侧给它留了位置）
        Positioned(
          top: grabZone + (MeSheetScope.headerHeight - 30) / 2,
          right: 16,
          child: Tooltip(
            message: '关闭',
            child: Material(
              color: glass ? mm.glassPanel : mm.card2,
              shape: const CircleBorder(),
              child: InkWell(
                customBorder: const CircleBorder(),
                onTap: close,
                child: SizedBox.square(dimension: 30, child: Icon(Icons.close_rounded, size: 16, color: mm.t2)),
              ),
            ),
          ),
        ),
      ],
    );
    final Widget surface;
    if (glass) {
      const radius = BorderRadius.all(Radius.circular(MeowGlassMetrics.sheetRadius));
      surface = MeowGlassBox(
        style: MeowGlassStyles.menu(context),
        radius: radius,
        rim: MeowGlassStyles.menuRim(context),
        shadows: MeowGlassStyles.menuShadows(context),
        // 只裁不离屏（不用 saveLayer）：离屏的话里面再有玻璃（页头的操作钮）就读不到背后的画面
        child: ClipRRect(
          borderRadius: radius,
          child: Material(type: MaterialType.transparency, child: body),
        ),
      );
    } else {
      surface = Material(
        color: mm.bg,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        clipBehavior: Clip.antiAlias,
        child: body,
      );
    }
    final sheet = Padding(
      padding: EdgeInsets.fromLTRB(inset, 0, inset, inset),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: maxHeight, maxWidth: MeSubPage.maxWidth),
        child: GestureDetector(
          // 下拉关闭：从抓手 / 页头拉，或正文不需要滚动时从任何地方拉（正文能滚时由它自己接手）
          onVerticalDragUpdate: _onDragUpdate,
          onVerticalDragEnd: _onDragEnd,
          child: surface,
        ),
      ),
    );

    return PopScope(
      // 系统返回键：在下一层时先退回上一层，第一层时关掉卡片
      canPop: _stack.length == 1,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) back();
      },
      child: Stack(
        children: [
          Positioned.fill(
            child: Semantics(
              label: '关闭',
              button: true,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: close,
                child: AnimatedBuilder(
                  animation: rise,
                  builder: (_, _) => ColoredBox(color: scrim.withValues(alpha: scrim.a * rise.value)),
                ),
              ),
            ),
          ),
          Align(
            alignment: Alignment.bottomCenter,
            child: AnimatedBuilder(
              animation: Listenable.merge([rise, _drag]),
              child: sheet,
              builder: (_, child) {
                final dragged = Transform.translate(offset: Offset(0, _drag.value), child: child);
                // 「移除动画」：只淡入淡出，不从底部升起（玻璃卡片用 LiquidGlassFade：普通的半透明会让玻璃读不到背后）
                if (reduce) {
                  return glass
                      ? LiquidGlassFade(opacity: rise, child: dragged)
                      : Opacity(opacity: rise.value, child: dragged);
                }
                return FractionalTranslation(translation: Offset(0, 1.05 * (1 - rise.value)), child: dragged);
              },
            ),
          ),
        ],
      ),
    );
  }
}
