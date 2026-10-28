import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme/motion.dart';
import '../theme/page_background.dart';
import 'meow_tab.dart';

/// 四个 Tab 页的常驻栈：都留在树上（切回来滚动位置、展开状态、已加载的数据都在），平时只画当前页。
///
/// IndexedStack 自己只是不画隐藏页，页里的 Ticker 照跑（它给子页套的 Visibility 走的是不带 TickerMode 的那条分支）。
/// 隐藏页里只要有一个转圈（动态页的「加载中」、测速 / 查出口 IP 的忙碌态），整个 App 就每个 vsync 出一帧、整屏重新合成，
/// 停在首页什么都不动也闲不下来。所以隐藏页的 Ticker 一律静音，切回来再走；
/// 数据监听、定时器、轮询不归 TickerMode 管，不受影响。
///
/// 静音不能卡着切页那一下做，否则看得出来（以前隐藏页的动画都是在后台自己播完的）：
/// - 离开的那一页再走 [leaveGrace]：按下高亮、水波纹、提示气泡的淡出、滚动回弹这些收尾动画在后台播完再静音。
///   不留的话，切回来的第一帧是它们被掐住那一刻的样子；提示气泡画在根 Overlay 上、不跟着页面隐藏，淡出走不动就一直留在别的页上。
/// - 要进来的那一页先开 Ticker、下一帧才露面：隐藏期间攒下的动画（连接状态、主题变了之后的颜色过渡，甩到一半的列表）
///   先追到终态。Ticker 要到解除静音的下一帧才走，当帧就露面的话会先画一帧旧样子再跳。
///
/// 切页是「内容平推、背景不动」（同 iOS 端，2026-10-27 用户在预览页选的方案 A，[MeowMotion.tabSlide]）：
/// 往后切（序号变大）新页从右侧整宽推入、旧页同时往左退 [MeowMotion.tabParallax] 页宽并淡出，往前切反过来。
/// 页面底只在最外层画一份、不跟页面动，各页本身透明（所以每页只露出上面各页还没盖到的那一段，否则淡出中的旧页从新页空隙里透出来）：以前每页各垫一层底色一起推，渐层 / 玻璃底按屏幕位置逐帧重画，
/// iOS 那边同样的做法在玻璃主题下前沿有接缝暗影（用户实报），两端一起改成背景不动。
/// 只有这 380ms 里新旧两页同时画，结束后回到只画当前页。平推中又点了别的 Tab：画面上的各页从当时的位置与透明度接着走，
/// 新目标压在最上面推入（目标本来就在画面上 = 往回点：它从当时的位置回正、淡回不透明，其余各页淡出，压在它上面的朝来的那一侧退出）。
/// 系统「移除动画」时直接换页。
///
/// 首次平推不卡（2026-10，安卓用户反馈「第一次点底栏切页卡、第二次不卡」）。第一次切到某页时光栅线程多出来的活几乎都在字形图集上：
/// Impeller 按「字 × 字号 × 字在屏幕上横向小数像素的四档位置」各栅格化一份（引擎 impeller/typographer/text_frame.cc），
/// 页里大多是中文、字多字形大，没上过台的页一个字都没有；平推时页面横坐标逐帧带小数，连旧页的字也要把另外三档补齐；
/// 底栏玻璃截背后画面时缩小重画的那一份字也一样。两处对应：
/// - 平推的位移取整：页的位移取整到物理像素，字的横向小数位置一直和静止时相同，平推不再生出新的字形（每次都是，不只第一次）。
/// - 预热（[prewarm]）：启动后空闲时，把还没上过台的页逐个垫在当前页底下画几帧（每页都垫着不透明的底色，看不见），
///   页面的图层录好、字形进图集，第一次平推就和第二次一样。垫画时不开 Ticker、不接手势、不进无障碍树。
///   各页是透明的，垫画的页压在一层不透明的页面底下面（画面上的页在这层上面），看不见。
class MeowTabStack extends StatefulWidget {
  const MeowTabStack({super.key, required this.current, required this.pageBuilder, this.prewarm = false});

  final MeowTab current;

  /// 启动后空闲时把还没上过台的页预先画一遍（见类注释）。
  final bool prewarm;

  /// 首次构建后等这么久才开始预热：让开启动时的加载与首页的入场动画。
  static const prewarmDelay = Duration(seconds: 2);

  /// 预热的两页之间隔这么久，到点时正在切页也过这么久再试。
  static const prewarmGap = Duration(milliseconds: 250);

  /// 每次都要返回同一个（const）实例：壳重建时页面才不会跟着重建。
  final Widget Function(MeowTab tab) pageBuilder;

  /// 离开的页多走这么久再静音：够水波纹（约 600ms）、提示气泡淡出（75ms）、过度滚动回弹收完；常驻的转圈也只多转这一会儿。
  static const leaveGrace = Duration(seconds: 1);

  @override
  State<MeowTabStack> createState() => _MeowTabStackState();
}

/// 平推中画面上的一页：水平位置（页宽的比例，正 = 偏右）从 [from] 走到 [to]，透明度从 [fromAlpha] 走到 [toAlpha]。
class _Layer {
  _Layer(this.tab, this.from, this.to, [this.fromAlpha = 1, this.toAlpha = 1]);
  final MeowTab tab;
  final double from, to;
  final double fromAlpha, toAlpha;
}

class _MeowTabStackState extends State<MeowTabStack> with SingleTickerProviderStateMixin {
  /// 正画着的（平推中 = 正推入的）那一页：比 widget.current 晚一帧跟上。
  late MeowTab _shown = widget.current;

  /// 画面上的页，自下而上；不在平推时只有 [_shown] 一页、位置 0。
  late List<_Layer> _layers = [_Layer(_shown, 0, 0)];

  late final AnimationController _slide = AnimationController(vsync: this, duration: MeowMotion.tabSlide)
    ..addStatusListener((status) {
      if (status == AnimationStatus.completed && mounted) {
        setState(() => _layers = [_Layer(_shown, 0, 0)]);
      }
    });

  /// 刚离开、Ticker 还没静音的页。
  final Set<MeowTab> _leaving = {};
  Timer? _muteTimer;

  /// 上过台（画过）的页，预热垫画过的也算。
  late final Set<MeowTab> _painted = {_shown};

  /// 这一帧垫在底下预热的页，以及垫到它的第几帧（见 [_warmShifts]）。
  MeowTab? _warming;
  int _warmStep = 0;
  Timer? _warmTimer;

  /// 每页垫画几帧、各往右挪几个物理像素。底栏玻璃的磨砂层按 8 个物理像素一格截背后的画面（liquid_glass_capture.dart 的
  /// _maxDivisor；底栏 hazeBlur 15.6 在手机的像素密度上都落到这一档），截图里的字是缩小后另栅格化的一份，
  /// 页面平推时它在截图里的横坐标带小数，同样分四档：挪 0 / 2 / 4 / 6 像素正好是截图里的 0 / ¼ / ½ / ¾ 格。
  /// 都是整像素，页面本身的字不多生字形。
  static const _warmShifts = [0, 2, 4, 6];

  @override
  void initState() {
    super.initState();
    if (widget.prewarm) _warmTimer = Timer(MeowTabStack.prewarmDelay, _warmNext);
  }

  double _pos(_Layer l) => l.from + (l.to - l.from) * MeowMotion.tabSlideCurve.transform(_slide.value);
  double _alpha(_Layer l) => l.fromAlpha + (l.toAlpha - l.fromAlpha) * MeowMotion.tabSlideCurve.transform(_slide.value);

  /// 预热下一页：连垫 [_warmShifts] 那么多帧后撤掉，隔 [MeowTabStack.prewarmGap] 再来下一页；正在切页就往后推（垫到一半时切页就此打住）。
  /// 逐页而不是几页一起垫：每帧的光栅活少一些；OpenGLES 上实测也比一起垫好（那里字形图集装不下新字时整份重建、
  /// 只留当帧用到的字，见引擎 typographer_context_skia.cc，一起垫的那一帧之后图集更容易被挤掉）。
  void _warmNext() {
    if (!mounted) return;
    final next = MeowTab.values.where((t) => !_painted.contains(t)).firstOrNull;
    if (next == null) return;
    if (_slide.isAnimating || _shown != widget.current) {
      _warmTimer = Timer(MeowTabStack.prewarmGap, _warmNext);
      return;
    }
    setState(() {
      _warming = next;
      _warmStep = 0;
    });
    WidgetsBinding.instance.addPostFrameCallback(_warmStepDone);
  }

  void _warmStepDone(Duration _) {
    if (!mounted || _warming == null) return;
    if (_warmStep < _warmShifts.length - 1 && !_slide.isAnimating && _shown == widget.current) {
      setState(() => _warmStep++);
      WidgetsBinding.instance.addPostFrameCallback(_warmStepDone);
      return;
    }
    setState(() => _warming = null);
    _warmTimer = Timer(MeowTabStack.prewarmGap, _warmNext);
  }

  @override
  void didUpdateWidget(MeowTabStack oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.current == oldWidget.current) return;
    // 这一帧只把要进来那一页的 Ticker 打开（见 build），帧末再换页
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _shown == widget.current) return;
      // 还亮着的提示气泡现在就收：不经触摸切页时（系统返回键回首页）它要等自己的 1.5 秒定时器才开始淡出，那时本页已经静音了。
      // 放在帧末而不是 didUpdateWidget 里：刚弹出、还没走过一帧的气泡会被当场摘掉，build 期间不许那样改 Overlay。
      Tooltip.dismissAllToolTips();
      final target = widget.current;
      setState(() {
        _leaving
          ..addAll(_layers.map((l) => l.tab))
          ..remove(target);
        _layers = MeowMotion.reduced(context) ? [_Layer(target, 0, 0)] : _retarget(target);
        _shown = target;
      });
      if (_layers.length > 1) {
        _slide.forward(from: 0);
      } else {
        _slide.stop();
      }
      _muteTimer?.cancel();
      _muteTimer = Timer(MeowTabStack.leaveGrace, () {
        if (mounted) setState(_leaving.clear);
      });
    });
  }

  /// 从画面上各页当前的位置出发、推向 [target] 的新一组层。
  List<_Layer> _retarget(MeowTab target) {
    final dir = target.index > _shown.index ? 1.0 : -1.0;
    final now = [
      for (final l in _layers) (l.tab, _slide.isAnimating ? _pos(l) : l.to, _slide.isAnimating ? _alpha(l) : l.toAlpha),
    ];
    final at = now.indexWhere((e) => e.$1 == target);
    if (at < 0) {
      // 新页压在最上面从一侧整宽推入，画面上的页一起往另一侧退开并淡出
      return [
        for (final (tab, x, a) in now) _Layer(tab, x, x - MeowMotion.tabParallax * dir, a, 0),
        _Layer(target, dir, 0),
      ];
    }
    // 往回点了还在画面上的页：它回正并淡回不透明；其余各页淡出（各页透明，盖不住下面的），下面的不动，
    // 上面的朝各自偏着的那一侧整宽退出
    return [
      for (final (i, (tab, x, a)) in now.indexed)
        if (i < at)
          _Layer(tab, x, x, a, 0)
        else if (i == at)
          _Layer(tab, x, 0, a, 1)
        else
          _Layer(tab, x, x == 0 ? -dir : x.sign, a, 0),
    ];
  }

  @override
  void dispose() {
    _muteTimer?.cancel();
    _warmTimer?.cancel();
    _slide.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bg = MeowBgFill.of(context);
    final dpr = MediaQuery.devicePixelRatioOf(context);
    return LayoutBuilder(
      builder: (context, box) => AnimatedBuilder(
        animation: _slide,
        builder: (context, _) {
          // 页的位置（页宽的比例）换成取整到物理像素的位移，见类注释「平推的位移取整」
          double snap(double x) => (x * box.maxWidth * dpr).roundToDouble() / dpr;
          // 走到终点的那一帧就只画新页（控制器要再过一帧才报完成）
          final layers = _slide.value >= 1 ? [_Layer(_shown, 0, 0)] : _layers;
          final sliding = layers.length > 1;
          final onStage = {for (final l in layers) l.tab: _pos(l)};
          final alphas = {for (final l in layers) l.tab: _alpha(l)};
          // 每页只露出上面各页还没盖到的那一段（页自己坐标里的横向区间）：各页透明，不裁的话淡出中的旧页
          // 从新页的空隙里透出来（iOS 上用户实报「残影」）
          final w = box.maxWidth;
          final spans = <MeowTab, (double, double)>{};
          if (sliding) {
            for (final (i, l) in layers.indexed) {
              var lo = double.negativeInfinity, hi = double.infinity;
              for (final above in layers.skip(i + 1)) {
                final o = snap(onStage[above.tab]!);
                if (o.abs() >= w) continue;
                if (o >= 0) hi = math.min(hi, o);
                if (o <= 0) lo = math.max(lo, o + w);
              }
              final own = snap(onStage[l.tab]!);
              spans[l.tab] = (lo - own, hi - own);
            }
          }
          _painted.addAll(onStage.keys);
          final warming = onStage.containsKey(_warming) ? null : _warming;
          if (warming != null) _painted.add(warming);
          // 画面上的页按层次排在最后（后画的在上），预热的页垫在页面底下面；靠 key 认页，换顺序不丢状态
          Widget page(MeowTab t) => KeyedSubtree(
            key: ValueKey(t),
            child: Offstage(
              offstage: !onStage.containsKey(t) && t != warming,
              child: IgnorePointer(
                // 平推中只有正推入的那一页接手势
                ignoring: t != _shown,
                child: Opacity(
                  // 退开的页淡出（1 时不加合成层，0 时不画）
                  opacity: (alphas[t] ?? 1).clamp(0.0, 1.0),
                  child: Transform.translate(
                    offset: Offset(snap(onStage[t] ?? 0) + (t == warming ? _warmShifts[_warmStep] / dpr : 0), 0),
                    // 页面本身透明，底在最外层（不动）；页面内容那一层平推中只画一次
                    child: ClipRect(
                      clipBehavior: spans.containsKey(t) ? Clip.hardEdge : Clip.none,
                      clipper: switch (spans[t]) {
                        (final lo, final hi) => _SpanClipper(lo, hi),
                        null => null,
                      },
                      child: RepaintBoundary(
                        child: ExcludeSemantics(
                          excluding: t == warming,
                          child: TickerMode(
                            enabled: onStage.containsKey(t) || t == widget.current || _leaving.contains(t),
                            child: widget.pageBuilder(t),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          );
          return ClipRect(
            // 平推时旧页会退到内容区外（宽屏是侧栏那边），只在这时裁
            clipBehavior: sliding ? Clip.hardEdge : Clip.none,
            child: Stack(
              fit: StackFit.expand,
              children: [
                for (final t in MeowTab.values)
                  if (!onStage.containsKey(t) && t != warming) page(t),
                if (warming != null) page(warming),
                // 静止的页面底：盖住垫画预热的页，画面上的页在它上面平推
                MeowBgBox(key: const ValueKey('bg'), fill: bg, child: const SizedBox.expand()),
                for (final l in layers) page(l.tab),
              ],
            ),
          );
        },
      ),
    );
  }
}

/// 只留页面里横向 [lo, hi) 这一段（页自己的坐标，可超出页面两边）。
class _SpanClipper extends CustomClipper<Rect> {
  const _SpanClipper(this.lo, this.hi);
  final double lo, hi;

  @override
  Rect getClip(Size size) {
    final l = lo.clamp(0.0, size.width), r = hi.clamp(0.0, size.width);
    return r > l ? Rect.fromLTRB(l, 0, r, size.height) : Rect.zero;
  }

  @override
  bool shouldReclip(_SpanClipper oldClipper) => oldClipper.lo != lo || oldClipper.hi != hi;
}

/// 让开软键盘：把 [child] 的底边收到键盘顶上。和 Scaffold 默认的 resizeToAvoidBottomInset 对 body 做的事逐项一致
/// （尺寸，以及 MediaQuery 的 padding / viewInsets / viewPadding），所以包在里面的部分排出来和以前一样。
///
/// 壳的 Scaffold 关掉了 resizeToAvoidBottomInset：开着的话键盘升降动画的每一帧 body 都换一次高度，
/// 常驻的四个 Tab 页（包括三个看不见的）跟着逐帧重排。关掉后 body 的尺寸不随键盘变，只有包了这一层的部分跟着键盘走。
class KeyboardInset extends StatelessWidget {
  const KeyboardInset({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    final inset = mq.viewInsets.bottom;
    // 手机上这里的 padding.bottom 是悬浮底栏的高度（壳 extendBody）：键盘没高过底栏时，那一段本来就让给底栏了，不用再让；
    // 高过之后底栏整个压在键盘下面，底栏那份留白也不要了。宽屏没有底栏，padding.bottom 已被 SafeArea 吃掉，键盘多高就让多高。
    final covered = inset > mq.padding.bottom;
    var data = mq.removeViewInsets(removeBottom: true);
    if (covered) data = data.copyWith(padding: data.padding.copyWith(bottom: 0));
    return Padding(
      padding: EdgeInsets.only(bottom: covered ? inset : 0),
      child: MediaQuery(data: data, child: child),
    );
  }
}
