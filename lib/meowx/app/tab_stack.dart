import 'package:flutter/material.dart';

import 'meow_tab.dart';

/// 四个 Tab 页的常驻栈：都留在树上（切回来滚动位置、展开状态、已加载的数据都在），只画当前页。
///
/// IndexedStack 自己只是不画隐藏页，页里的 Ticker 照跑（它给子页套的 Visibility 走的是不带 TickerMode 的那条分支）。
/// 隐藏页里只要有一个转圈（动态页的「加载中」、测速 / 查出口 IP 的忙碌态），整个 App 就每个 vsync 出一帧、整屏重新合成，
/// 停在首页什么都不动也闲不下来。所以隐藏页的 Ticker 一律静音，切回来再走；
/// 数据监听、定时器、轮询不归 TickerMode 管，不受影响。
class MeowTabStack extends StatelessWidget {
  const MeowTabStack({super.key, required this.current, required this.pageBuilder});

  final MeowTab current;

  /// 每次都要返回同一个（const）实例：壳重建时页面才不会跟着重建。
  final Widget Function(MeowTab tab) pageBuilder;

  @override
  Widget build(BuildContext context) {
    return IndexedStack(
      index: current.index,
      children: [for (final t in MeowTab.values) TickerMode(enabled: t == current, child: pageBuilder(t))],
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
