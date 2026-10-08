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

/// 切 Tab（同步 Bettbox 的当前页标签）。页面里跳转别的 Tab 都走这里。
void goTab(WidgetRef ref, MeowTab tab) {
  if (ref.read(meowTabProvider) == tab) return;
  ref.read(meowTabProvider.notifier).state = tab;
  ref.read(currentPageLabelProvider.notifier).value = tab.pageLabel;
}
