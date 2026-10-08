import 'package:bett_box/enum/enum.dart';
import 'package:bett_box/providers/providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../theme/widgets.dart';

/// 四个 Tab（与 iOS / iPad 改版一致）：配置 + 设置并成「我的」，连接 + 日志叫「动态」。
enum MeowTab {
  home('首页', MeowGlyph.home, PageLabel.dashboard),
  proxies('节点', MeowGlyph.nodes, PageLabel.proxies),
  connections('动态', MeowGlyph.activity, PageLabel.connections),
  me('我的', MeowGlyph.me, PageLabel.profiles);

  const MeowTab(this.label, this.glyph, this.pageLabel);

  final String label;
  final MeowGlyph glyph;

  /// 对应的 Bettbox 页面标签（Bettbox 内部 toPage 时据此映射到 Tab；连接页轮询、代理页测速等内部逻辑也据此判断可见性）
  final PageLabel pageLabel;

  /// Bettbox 的「配置」「工具」两个标签都落到「我的」。
  static MeowTab? fromPageLabel(PageLabel label) {
    if (label == PageLabel.tools) return MeowTab.me;
    for (final t in values) {
      if (t.pageLabel == label) return t;
    }
    return null;
  }
}

/// 当前 Tab。
final meowTabProvider = StateProvider<MeowTab>((ref) => MeowTab.home);

extension MeowTabWatch on WidgetRef {
  /// [tab] 是当前页时订阅 [provider]；不是时只取它的当前值，不跟着它重建。只能在 build 里调。
  ///
  /// 四个 Tab 常驻在树上，隐藏页不画但照样重建，而每重建一次就要多出一帧、整屏重新合成。
  /// 每秒都在变的数据（网速、运行时长、连接计数）用它来订阅：切回 [tab] 时「是不是当前页」变了会重建一次，拿到最新值。
  /// 只给这类高频数据用——连接状态之类低频的照常 watch，隐藏时也要跟上。
  T watchOnTab<T>(MeowTab tab, ProviderListenable<T> provider) {
    if (watch(meowTabProvider.select((t) => t == tab))) return watch(provider);
    // 留一个什么都不做的监听把 provider 留住：Bettbox 的状态 provider 都是 autoDispose 的，没人听的时候控制器每写一次
    // （每秒 read(notifier) 一回）Riverpod 就排一次回收，而它排回收靠的是让 ProviderScope 重建——照样多出一帧。
    listen<T>(provider, (_, _) {});
    return read(provider);
  }
}

/// 切 Tab（同步 Bettbox 的当前页标签）。页面里跳转别的 Tab 都走这里。
void goTab(WidgetRef ref, MeowTab tab) {
  if (ref.read(meowTabProvider) == tab) return;
  ref.read(meowTabProvider.notifier).state = tab;
  ref.read(currentPageLabelProvider.notifier).value = tab.pageLabel;
}
