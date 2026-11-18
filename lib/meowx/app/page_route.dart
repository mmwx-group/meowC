// 页面转场：照搬 FlClash 0.9.1（GPL-3.0，chen08209/FlClash 的 lib/ui/page_transition.dart 与 lib/ui/deferred_push.dart），
// 去掉了它的边缘拖动返回（drag_back.dart，安卓有系统返回手势）与 surface 分层，底色换成 MeowX 的页面底色。
//
// 为什么换：以前进二级页用 CupertinoPageRoute（500ms、旧页视差 + 边缘阴影渐变），旧页要带着阴影层一起合成；
// 这里的淡入淡出不用 Opacity——在页面上盖一层底色模拟（Impeller 下 opacity 层每帧都要把整页离屏画一遍），
// 并且把转场推迟一帧开始：新页首帧 build 再慢，也不会把转场开头吞掉（以前首帧一卡，动画直接从一半开始）。
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';

import '../theme/page_background.dart';

/// 手机上进二级页的路由（`BaseNavigator.push` 用）：共享轴横向转场 + 推迟一帧开始。
class MeowPageRoute<T> extends PageRoute<T> with DeferredPushRouteMixin<T> {
  MeowPageRoute({required this.builder, this.maintainState = true, super.settings});

  final WidgetBuilder builder;

  @override
  final bool maintainState;

  /// 下面那一页是不是同一种转场、而且这次进来时它是静止的：是的话它自己淡出，这页不用再垫底色替它淡
  bool _overSettledPage = false;

  @override
  Color? get barrierColor => null;

  @override
  String? get barrierLabel => null;

  @override
  Duration get transitionDuration => SharedXPageTransition.duration;

  @override
  void didChangePrevious(Route<dynamic>? previousRoute) {
    super.didChangePrevious(previousRoute);
    _overSettledPage = previousRoute is PageRoute &&
        previousRoute.animation!.isCompleted &&
        previousRoute.secondaryAnimation!.isDismissed;
  }

  @override
  Widget buildPage(BuildContext context, Animation<double> animation, Animation<double> secondaryAnimation) {
    return Semantics(scopesRoute: true, explicitChildNodes: true, child: builder(context));
  }

  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    final bg = MeowBgFill.of(context);
    return SharedXPageTransition(
      animation: animation,
      secondaryAnimation: secondaryAnimation,
      fill: bg,
      slide: SharedXPageTransition.pageSlide,
      overSettledPage: _overSettledPage,
      uncoveredByGesture: navigator!.userGestureInProgress,
      child: MeowBgBox(fill: bg, child: child),
    );
  }
}

/// 主题里的转场（MaterialPageRoute 等走主题的路由用，Bettbox 原页面也是这些）：同一套共享轴横向转场。
class MeowPageTransitionsBuilder extends PageTransitionsBuilder {
  const MeowPageTransitionsBuilder();

  @override
  Duration get transitionDuration => SharedXPageTransition.duration;

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    final bg = MeowBgFill.of(context);
    return SharedXPageTransition(
      animation: animation,
      secondaryAnimation: secondaryAnimation,
      fill: bg,
      slide: SharedXPageTransition.pageSlide,
      // 主题转场的上下两页都是这套转场、各自淡入淡出，不用替下面那页垫底色
      overSettledPage: true,
      uncoveredByGesture: route.navigator?.userGestureInProgress ?? false,
      child: MeowBgBox(fill: bg, child: child),
    );
  }
}

/// 页面一边平移 [slide] 一边淡入淡出。淡入淡出 = 在页面上盖一层页面底 [fill]（只盖在底下也是这个底的地方），
/// 不用 opacity 层：那在 Impeller 下每帧都要把整页离屏画一遍。
class SharedXPageTransition extends StatelessWidget {
  const SharedXPageTransition({
    super.key,
    required this.animation,
    required this.secondaryAnimation,
    required this.fill,
    required this.slide,
    required this.overSettledPage,
    this.uncoveredByGesture = false,
    required this.child,
  });

  static const duration = Duration(milliseconds: 450);

  /// Android 14 的页面平移距离（FadeForwardsPageTransitionsBuilder 同值）
  static const pageSlide = Offset(0.25, 0);

  final Animation<double> animation;
  final Animation<double> secondaryAnimation;
  final MeowBgFill fill;

  /// 页面移动的距离，按自身尺寸的比例
  final Offset slide;

  /// 下面那页在这页进来时是静止的：它按这条路由的动画淡出，底下只剩 [fill]
  final bool overSettledPage;

  /// 上面那页由手势拖着走（系统返回手势）：这页跟手、按露出的比例淡入，而不是拖到最后才出现
  final bool uncoveredByGesture;
  final Widget child;

  static final _slideCurve = CurveTween(curve: Curves.easeInOutCubicEmphasized);

  static const _fadeInCurve = Interval(0.15, 0.55, curve: Curves.easeOutCubic);
  static const _fadeOutCurve = Interval(0, 0.3);
  static final _fadeIn = CurveTween(curve: _fadeInCurve);
  static final _fadeOut = Tween(begin: 1.0, end: 0.0).chain(CurveTween(curve: _fadeOutCurve));

  // 两页的淡入淡出在五分之一处交接（此时都是三分之一不透明），上面那页只在交接点自己那一侧显示，不会两页叠着
  static const _handOver = 0.2;
  static final _takeOver = CurveTween(curve: const _HandOver(_fadeInCurve, at: _handOver, leaving: false));
  static final _handBack = Tween(begin: 1.0, end: 0.0).chain(
    CurveTween(curve: const _HandOver(_fadeOutCurve, at: _handOver, leaving: true)),
  );

  Animatable<Offset> _slide(Offset begin, Offset end) => Tween(begin: begin, end: end).chain(_slideCurve);

  Widget _overPageBelow(Animation<double> animation, Animatable<double> pageBelowOpacity, Widget child) {
    final fades = !overSettledPage && animation.isAnimating;
    final opacity = fades ? pageBelowOpacity.evaluate(animation) : 1.0;
    return MeowBgBox(fill: fill, opacity: 1 - opacity, child: child);
  }

  @override
  Widget build(BuildContext context) {
    final enterSlide = _slide(slide, Offset.zero);
    final exitSlide = _slide(Offset.zero, slide);
    final gesture = uncoveredByGesture;
    final uncoverSlide = gesture ? Tween(begin: -slide, end: Offset.zero) : _slide(-slide, Offset.zero);
    final coverSlide = gesture ? Tween(begin: Offset.zero, end: -slide) : _slide(Offset.zero, -slide);
    final covered = DualTransitionBuilder(
      animation: ReverseAnimation(secondaryAnimation),
      forwardBuilder: (_, animation, child) => SlideTransition(
        position: uncoverSlide.animate(animation),
        child: _PageFade(opacity: gesture ? animation : _fadeIn.animate(animation), fill: fill, child: child),
      ),
      reverseBuilder: (_, animation, child) => SlideTransition(
        position: coverSlide.animate(animation),
        child: _PageFade(
          opacity: gesture ? ReverseAnimation(animation) : _fadeOut.animate(animation),
          fill: fill,
          child: child,
        ),
      ),
      child: child,
    );
    return DualTransitionBuilder(
      animation: animation,
      forwardBuilder: (_, animation, child) => _overPageBelow(
        animation,
        _fadeOut,
        SlideTransition(
          position: enterSlide.animate(animation),
          child: _PageFade(opacity: _takeOver.animate(animation), fill: fill, opaque: true, child: child),
        ),
      ),
      reverseBuilder: (_, animation, child) => IgnorePointer(
        ignoring: animation.status == AnimationStatus.forward,
        child: _overPageBelow(
          animation,
          _fadeIn,
          SlideTransition(
            position: exitSlide.animate(animation),
            child: _PageFade(opacity: _handBack.animate(animation), fill: fill, opaque: true, child: child),
          ),
        ),
      ),
      child: MeowBgBox(fill: fill, opacity: secondaryAnimation.isAnimating ? 1 : 0, child: covered),
    );
  }
}

class _HandOver extends Curve {
  const _HandOver(this.curve, {required this.at, required this.leaving});

  final Curve curve;
  final double at;
  final bool leaving;

  @override
  double transformInternal(double t) {
    if (leaving) return t < at ? curve.transform(t) : 1;
    return t < at ? 0 : curve.transform(t);
  }
}

/// 把 [child] 往页面底 [fill] 淡：在它上面盖一层页面底；[opaque] 时下面也垫一层，底下什么都透不出来。
class _PageFade extends SingleChildRenderObjectWidget {
  const _PageFade({required this.opacity, required this.fill, this.opaque = false, super.child});

  final Animation<double> opacity;
  final MeowBgFill fill;
  final bool opaque;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderPageFade(opacity: opacity, fill: fill, opaque: opaque);

  @override
  void updateRenderObject(BuildContext context, _RenderPageFade renderObject) {
    renderObject
      ..opacity = opacity
      ..fill = fill
      ..opaque = opaque;
  }
}

class _RenderPageFade extends RenderProxyBox {
  _RenderPageFade({required Animation<double> opacity, required MeowBgFill fill, required bool opaque})
    : _opacity = opacity,
      _fill = fill,
      _opaque = opaque;

  Animation<double> _opacity;
  MeowBgFill _fill;
  bool _opaque;
  bool _visible = true;

  set opacity(Animation<double> value) {
    if (identical(value, _opacity)) return;
    if (attached) {
      _opacity.removeListener(_update);
      value.addListener(_update);
    }
    _opacity = value;
    _update();
  }

  set fill(MeowBgFill value) {
    if (value == _fill) return;
    _fill = value;
    markNeedsPaint();
  }

  set opaque(bool value) {
    if (value == _opaque) return;
    _opaque = value;
    markNeedsPaint();
  }

  void _update() {
    final visible = _opacity.value > 0;
    if (visible != _visible) {
      _visible = visible;
      markNeedsSemanticsUpdate();
    }
    markNeedsPaint();
  }

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _opacity.addListener(_update);
    _update();
  }

  @override
  void detach() {
    _opacity.removeListener(_update);
    super.detach();
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    final opacity = _opacity.value;
    if (child == null || opacity == 0) return;
    if (opacity == 1) {
      super.paint(context, offset);
      return;
    }
    if (_fill.flat) {
      final color = _fill.color;
      if (_opaque) context.canvas.drawRect(offset & size, Paint()..color = color);
      super.paint(context, offset);
      context.canvas.drawRect(offset & size, Paint()..color = color.withValues(alpha: color.a * (1 - opacity)));
      return;
    }
    // 渐层的页面底：按这一页在屏幕上的位置取色（与下面那页、页面本身的底拼成同一条渐层）
    final origin = localToGlobal(Offset.zero);
    if (_opaque) _fill.paint(context.canvas, offset & size, origin: origin);
    super.paint(context, offset);
    _fill.paint(context.canvas, offset & size, origin: origin, opacity: 1 - opacity);
  }

  @override
  void visitChildrenForSemantics(RenderObjectVisitor visitor) {
    if (_visible) super.visitChildrenForSemantics(visitor);
  }
}

/// 转场推迟一帧开始（照搬 FlClash 的 DeferredPushRouteMixin）：新页首帧 build 很慢时，不会把转场的开头吞掉。
mixin DeferredPushRouteMixin<T> on TransitionRoute<T> {
  _TickerCapture? _vsync;

  @override
  AnimationController createAnimationController() {
    final vsync = _vsync = _TickerCapture(navigator!);
    return AnimationController(
      duration: transitionDuration,
      reverseDuration: reverseTransitionDuration,
      debugLabel: debugLabel,
      vsync: vsync,
    );
  }

  @override
  TickerFuture didPush() {
    final ticker = _vsync?.ticker;
    if (ticker == null || ticker.muted) return super.didPush();
    ticker.muted = true;
    final pushed = super.didPush();
    final context = navigator!.context;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      ticker.muted = !TickerMode.getValuesNotifier(context).value.enabled;
    });
    return pushed;
  }
}

class _TickerCapture implements TickerProvider {
  _TickerCapture(this._parent);

  final TickerProvider _parent;
  Ticker? ticker;

  @override
  Ticker createTicker(TickerCallback onTick) => ticker = _parent.createTicker(onTick);
}
