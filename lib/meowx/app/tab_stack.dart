import 'dart:async';

import 'package:flutter/material.dart';

import 'meow_tab.dart';

/// 四个 Tab 页的常驻栈：都留在树上（切回来滚动位置、展开状态、已加载的数据都在），只画当前页。
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

class _MeowTabStackState extends State<MeowTabStack> {
  /// 正画着的那一页：比 widget.current 晚一帧跟上。
  late MeowTab _shown = widget.current;

  /// 刚离开、Ticker 还没静音的那一页。
  MeowTab? _leaving;
  Timer? _muteTimer;

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
      setState(() {
        _leaving = _shown;
        _shown = widget.current;
      });
      _muteTimer?.cancel();
      _muteTimer = Timer(MeowTabStack.leaveGrace, () {
        if (mounted) setState(() => _leaving = null);
      });
    });
  }

  @override
  void dispose() {
    _muteTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return IndexedStack(
      index: _shown.index,
      children: [
        for (final t in MeowTab.values)
          TickerMode(enabled: t == _shown || t == widget.current || t == _leaving, child: widget.pageBuilder(t)),
      ],
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
