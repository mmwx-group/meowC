import 'dart:async';

import 'package:flutter/material.dart';

import '../theme/motion.dart';
import '../theme/tokens.dart';
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
/// 切页是整页左右平推（同 iOS 端，[MeowMotion.tabSlide]）：往后切（序号变大）新页从右侧整页推入、旧页同时往左退
/// [MeowMotion.tabParallax] 页宽，往前切反过来；只动位置、不改透明度，每页垫一层页面底色，任何一帧都不露出底下的白 / 黑。
/// 只有这 380ms 里新旧两页同时画，结束后回到只画当前页。平推中又点了别的 Tab：画面上的各页从当时的位置接着走，
/// 新目标压在最上面推入（目标本来就在画面上 = 往回点：它从当时的位置回正，压在它上面的页朝来的那一侧退出）。
/// 系统「移除动画」时直接换页。
class MeowTabStack extends StatefulWidget {
  const MeowTabStack({super.key, required this.current, required this.pageBuilder});

  final MeowTab current;

  /// 每次都要返回同一个（const）实例：壳重建时页面才不会跟着重建。
  final Widget Function(MeowTab tab) pageBuilder;

  /// 离开的页多走这么久再静音：够水波纹（约 600ms）、提示气泡淡出（75ms）、过度滚动回弹收完；常驻的转圈也只多转这一会儿。
  static const leaveGrace = Duration(seconds: 1);

  @override
  State<MeowTabStack> createState() => _MeowTabStackState();
}

/// 平推中画面上的一页：水平位置（页宽的比例，正 = 偏右）从 [from] 走到 [to]。
class _Layer {
  _Layer(this.tab, this.from, this.to);
  final MeowTab tab;
  final double from, to;
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

  double _pos(_Layer l) => l.from + (l.to - l.from) * MeowMotion.tabSlideCurve.transform(_slide.value);

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
    final now = [for (final l in _layers) (l.tab, _slide.isAnimating ? _pos(l) : l.to)];
    final at = now.indexWhere((e) => e.$1 == target);
    if (at < 0) {
      // 新页压在最上面从一侧整页推入，画面上的页一起往另一侧退开
      return [
        for (final (tab, x) in now) _Layer(tab, x, x - MeowMotion.tabParallax * dir),
        _Layer(target, dir, 0),
      ];
    }
    // 往回点了还在画面上的页：它回正，下面的不动（最后会被它盖住），上面的朝各自偏着的那一侧整页退出
    return [
      for (final (i, (tab, x)) in now.indexed)
        if (i < at)
          _Layer(tab, x, x)
        else if (i == at)
          _Layer(tab, x, 0)
        else
          _Layer(tab, x, x == 0 ? -dir : x.sign),
    ];
  }

  @override
  void dispose() {
    _muteTimer?.cancel();
    _slide.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bg = context.mm.bg;
    return AnimatedBuilder(
      animation: _slide,
      builder: (context, _) {
        // 走到终点的那一帧就只画新页（控制器要再过一帧才报完成）
        final layers = _slide.value >= 1 ? [_Layer(_shown, 0, 0)] : _layers;
        final sliding = layers.length > 1;
        final onStage = {for (final l in layers) l.tab: _pos(l)};
        // 画面上的页按层次排在最后（后画的在上）；靠 key 认页，换顺序不丢状态
        final order = [
          for (final t in MeowTab.values)
            if (!onStage.containsKey(t)) t,
          for (final l in layers) l.tab,
        ];
        return ColoredBox(
          color: bg,
          child: ClipRect(
            // 平推时旧页会退到内容区外（宽屏是侧栏那边），只在这时裁
            clipBehavior: sliding ? Clip.hardEdge : Clip.none,
            child: Stack(
              fit: StackFit.expand,
              children: [
                for (final t in order)
                  KeyedSubtree(
                    key: ValueKey(t),
                    child: Offstage(
                      offstage: !onStage.containsKey(t),
                      child: IgnorePointer(
                        // 平推中只有正推入的那一页接手势
                        ignoring: t != _shown,
                        child: FractionalTranslation(
                          translation: Offset(onStage[t] ?? 0, 0),
                          child: RepaintBoundary(
                            child: ColoredBox(
                              color: bg,
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
              ],
            ),
          ),
        );
      },
    );
  }
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
