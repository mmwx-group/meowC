import 'dart:async';
import 'dart:math' as math;

import 'package:bett_box/common/common.dart';
import 'package:bett_box/models/models.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/strings.dart';
import '../../state/connection.dart';
import '../../state/exit_ip.dart';
import '../../state/meow_settings.dart';
import '../../state/status.dart';
import '../../theme/page_title.dart';
import '../../theme/tokens.dart';
import '../../theme/two_pane.dart';
import '../../theme/widgets.dart';
import 'active_connections_card.dart';
import 'hero_card.dart';
import 'info_cards.dart';
import 'speed_card.dart';
import 'takeover_card.dart';

const _gap = 12.0;
const _pad = 16.0;

/// 首页（设计稿 design/ui-redesign/boards/Main.dc.html、WHome.dc.html）。
/// 手机：一列——品牌顶栏 → 连接主卡 → 网速 → 订阅 → 代理应用（Android）→ 指标 → 出口 IP。
/// 宽屏（有侧栏）：5 : 7 两列——左：连接主卡 → 接管方式（Windows）/ 代理应用（Android 平板）→ 网速（撑满）；
/// 右：订阅 → 指标 → 出口 IP → 活跃连接（撑满）。700–899 宽放不下两列，退成一列。
///
/// 「首页卡片」开关（[HomeCard]）与新布局的对应：上传 / 下载 = 网速卡里的两列，网速图 = 网速卡里的折线（三个都关，网速卡不出现）；
/// 代理连接 / 直连连接 / 内存 / DNS 模式 = 指标行里的四格（剩下的等分一行）；出口 IP = 那两格 + 标题行的重查钮。
/// Windows 上折线恒在（它撑满左列），不给关。
class DashboardPage extends ConsumerWidget {
  const DashboardPage({super.key, this.fetchConnections});

  /// 「活跃连接」取连接快照；默认问核心，只有测试会换掉。
  @visibleForTesting
  final Future<List<TrackerInfo>> Function()? fetchConnections;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final wide = ref.watch(isWideLayoutProvider);
    final twoPane = wide && ref.watch(isTwoPaneProvider);
    final hidden = ref.watch(meowSettingProvider.select((s) => s.homeHiddenCards));
    bool shows(HomeCard c) => (c == HomeCard.chart && isDesktopUi) || !hidden.contains(c.name);

    final actions = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (shows(HomeCard.ip)) ...[const _RefreshIpButton(), const SizedBox(width: 8)],
        _RoundButton(glyph: MeowGlyph.sliders, tooltip: S.homeCards, onTap: () => _showCardSettings(context)),
      ],
    );
    final hero = HomeHeroCard(dense: wide);
    final up = shows(HomeCard.upload), down = shows(HomeCard.download), chart = shows(HomeCard.chart);
    final speed = up || down || chart
        ? HomeSpeedCard(up: up, down: down, chart: chart, dense: wide, expand: twoPane)
        : null;
    final subscription = HomeSubscriptionCard(dense: wide);
    // MEOWX_PREVIEW_DESKTOP 在 Android 模拟器上预览的是 Windows 的样子，不带这行
    final apps = system.isAndroid && !isDesktopUi ? HomeProxyAppsRow(dense: wide) : null;
    final takeover = isDesktopUi ? const HomeTakeoverCard() : null;
    final tiles = [
      for (final c in const [HomeCard.proxied, HomeCard.direct, HomeCard.memory, HomeCard.dns])
        if (shows(c)) c,
    ];
    final metrics = tiles.isEmpty ? null : HomeMetricsRow(cards: tiles, dense: wide);
    final exitIp = shows(HomeCard.ip) ? HomeExitIp(dense: wide) : null;

    if (!wide) {
      return ListView(
        // 悬浮底栏盖在内容上（壳 extendBody）：底部留白要把它的高度（MediaQuery.padding.bottom）加进去
        padding: EdgeInsets.fromLTRB(_pad, 0, _pad, _pad + MediaQuery.paddingOf(context).bottom),
        children: _spaced([_BrandBar(actions: actions), hero, speed, subscription, apps, metrics, exitIp]),
      );
    }

    final title = PageTitle(S.home, trailing: actions);
    final pad = widePagePadding();
    if (!twoPane) {
      return PageWidth(
        child: ListView(
          padding: pad,
          children: _spaced([
            title,
            hero,
            takeover,
            apps,
            speed,
            subscription,
            metrics,
            exitIp,
            HomeActiveConnections(minRows: 5, fetch: fetchConnections),
          ]),
        ),
      );
    }

    // 够高：整页正好一屏，「网速」「活跃连接」撑满两列剩下的高度；不够高（最小窗口、手机横屏、大字号）：按内容高度排、整页滚动。
    // 用 IntrinsicHeight 量内容自己要多高（两个撑满的卡各报一个最小高度），和视口高度取大者——所以这棵子树里不能出现 LayoutBuilder。
    final left = _spaced([hero, takeover, apps, if (speed != null) chart ? Expanded(child: speed) : speed]);
    final right = _spaced([subscription, metrics, exitIp, Expanded(child: HomeActiveConnections(expand: true, fetch: fetchConnections))]);
    return PageWidth(
      child: LayoutBuilder(
        builder: (context, c) => SingleChildScrollView(
          padding: pad,
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: math.max(0, c.maxHeight - pad.vertical)),
            child: IntrinsicHeight(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  title,
                  const SizedBox(height: _gap),
                  Expanded(
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Expanded(flex: 5, child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: left)),
                        const SizedBox(width: 14),
                        Expanded(flex: 7, child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: right)),
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

  /// 去掉 null，并在相邻两项之间插入间距。
  static List<Widget> _spaced(List<Widget?> items) {
    final out = <Widget>[];
    for (final w in items.nonNulls) {
      if (out.isNotEmpty) out.add(const SizedBox(height: _gap));
      out.add(w);
    }
    return out;
  }

  void _showCardSettings(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,   // 默认上限是屏高的 9/16，八个开关 + 说明放不下
      builder: (ctx) => Consumer(
        builder: (ctx, ref, _) {
          final mm = ctx.mm;
          final hidden = ref.watch(meowSettingProvider.select((s) => s.homeHiddenCards));
          return SafeArea(
            child: ListView(
              shrinkWrap: true,
              padding: const EdgeInsets.only(bottom: 12),
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
                  child: Text(
                    S.homeCards,
                    style: TextStyle(fontSize: MeowFont.headline, fontWeight: FontWeight.w600, color: mm.t1),
                  ),
                ),
                for (final c in HomeCard.values)
                  if (!(isDesktopUi && c == HomeCard.chart))
                    SwitchListTile(
                      dense: true,
                      title: Text(c.label, style: TextStyle(fontSize: MeowFont.body, color: mm.t1)),
                      value: !hidden.contains(c.name),
                      onChanged: (on) => ref.read(meowSettingProvider.notifier).updateState(
                        (s) => s.copyWith(
                          homeHiddenCards: on
                              ? s.homeHiddenCards.where((n) => n != c.name).toList()
                              : [...s.homeHiddenCards, c.name],
                        ),
                      ),
                    ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
                  child: Text(
                    S.homeCardsHint,
                    style: TextStyle(fontSize: MeowFont.caption, color: mm.t3),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

/// 手机端顶栏：品牌头像 + 「MeowX」+ 本页的操作钮（宽屏的品牌在侧栏里，标题行用 [PageTitle]）。
class _BrandBar extends StatelessWidget {
  const _BrandBar({required this.actions});
  final Widget actions;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Row(
        children: [
          const BrandHead(),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'MeowX',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: MeowFont.pageTitle,
                fontWeight: FontWeight.w700,
                letterSpacing: -0.3,
                height: 1.15,
                color: context.mm.t1,
                fontFamilyFallback: meowRounded,
              ),
            ),
          ),
          const SizedBox(width: 8),
          actions,
        ],
      ),
    );
  }
}

/// 标题行的圆钮（44，卡片底）：和 [RoundGlassButton] 同形，图标换成设计稿的线性图标。
class _RoundButton extends StatelessWidget {
  const _RoundButton({required this.glyph, required this.tooltip, required this.onTap, this.busy = false});
  final MeowGlyph glyph;
  final String tooltip;
  final VoidCallback onTap;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final mm = context.mm;
    return Tooltip(
      message: tooltip,
      child: Material(
        color: mm.elev,
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: busy ? null : onTap,
          child: SizedBox(
            width: 44,
            height: 44,
            child: Center(
              child: busy
                  ? SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: mm.t2))
                  : MeowIcon(glyph, size: 20, color: mm.t1),
            ),
          ),
        ),
      ),
    );
  }
}

/// 「重新查询出口 IP」：立即重查两格（未连接时只查国内那格）。
class _RefreshIpButton extends ConsumerWidget {
  const _RefreshIpButton();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final busy = ref.watch(exitIpProvider.select((s) => s.loadingDomestic || s.loadingGlobal));
    return _RoundButton(
      glyph: MeowGlyph.refresh,
      tooltip: '重新查询出口 IP',
      busy: busy,
      onTap: () => unawaited(ref.read(exitIpProvider.notifier).refresh(running: ref.read(isRunningProvider))),
    );
  }
}
