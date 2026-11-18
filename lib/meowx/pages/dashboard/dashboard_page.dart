import 'dart:async';
import 'dart:math' as math;

import 'package:bett_box/common/common.dart';
import 'package:bett_box/models/models.dart';
import 'package:bett_box/providers/providers.dart' show themeSettingProvider;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/strings.dart';
import '../../state/app_icon.dart';
import '../../state/connection.dart';
import '../../state/exit_ip.dart';
import '../../state/mesh.dart';
import '../../state/meow_settings.dart';
import '../../state/status.dart';
import '../../theme/haptics.dart';
import '../../theme/m3.dart';
import '../../theme/m3_kit.dart';
import '../../theme/meow_dialog.dart';
import '../../theme/page_title.dart';
import '../../theme/tokens.dart';
import '../../theme/two_pane.dart';
import 'active_connections_card.dart';
import 'hero_card.dart';
import 'info_cards.dart';
import 'mesh_card.dart';
import 'speed_card.dart';
import 'speed_test_card.dart';
import 'takeover_card.dart';

const _gap = 12.0;
const _pad = 16.0;

/// 首页（设计稿 design/ui-redesign/boards/Main.dc.html、WHome.dc.html）。
/// 手机：一列——品牌顶栏 → 连接主卡 → 网速 → 订阅 → 喵窝（管理员）→ 代理应用（Android）→ 指标 → 出口 IP。
/// 宽屏（有侧栏）：5 : 7 两列——左：连接主卡 → 接管方式（Windows）/ 代理应用（Android 平板）→ 网速（撑满）；
/// 右：订阅 → 指标 → 出口 IP → 活跃连接（撑满）。700–899 宽放不下两列，退成一列。
///
/// 「首页卡片」开关（[HomeCard]）与新布局的对应：上传 / 下载 = 网速卡里的两列，网速图 = 网速卡里的折线（三个都关，网速卡不出现）；
/// 代理连接 / 直连连接 / 内存 / DNS 模式 = 指标行里的四格（剩下的等分一行）；出口 IP = 那两格 + 标题行的重查钮。
/// 代理应用 = 那一行（只在 Android 上有，设置里也只在 Android 上列出）。Windows 上折线恒在（它撑满左列），不给关。
/// 「代理应用」行只在 Android 上有；MEOWX_PREVIEW_DESKTOP 在 Android 模拟器上预览的是 Windows 的样子，也不带。
bool get _hasAppsCard => system.isAndroid && !isDesktopUi;

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
        Builder(
          builder: (anchor) =>
              M3IconButton(icon: Icons.tune_rounded, tooltip: S.homeCards, onPressed: () => _showCardSettings(anchor)),
        ),
      ],
    );
    final hero = HomeHeroCard(dense: wide);
    final up = shows(HomeCard.upload), down = shows(HomeCard.download), chart = shows(HomeCard.chart);
    final speed = up || down || chart
        ? HomeSpeedCard(up: up, down: down, chart: chart, dense: wide, expand: twoPane)
        : null;
    final subscription = HomeSubscriptionCard(dense: wide);
    final showApps = _hasAppsCard && shows(HomeCard.apps);
    final takeover = isDesktopUi ? const HomeTakeoverCard() : null;
    final tiles = [
      for (final c in const [HomeCard.proxied, HomeCard.direct, HomeCard.memory, HomeCard.dns])
        if (shows(c)) c,
    ];
    final metrics = tiles.isEmpty ? null : HomeMetricsRow(cards: tiles, dense: wide);
    // 喵窝（主控内置的组网）：管理员账号或已经开着时才有，「首页卡片」里可以关掉
    final showMesh = ref.watch(meshVisibleProvider) && shows(HomeCard.mesh);
    // 喵窝与代理应用两格并排（画布稿：左块左下角、右块右下角收小）；只有一个时整行
    const pairL = BorderRadius.only(
      topLeft: Radius.circular(MeowShape.xl),
      topRight: Radius.circular(MeowShape.xl),
      bottomRight: Radius.circular(MeowShape.xl),
      bottomLeft: Radius.circular(MeowShape.m),
    );
    const pairR = BorderRadius.only(
      topLeft: Radius.circular(MeowShape.xl),
      topRight: Radius.circular(MeowShape.xl),
      bottomLeft: Radius.circular(MeowShape.xl),
      bottomRight: Radius.circular(MeowShape.m),
    );
    final Widget? features = showMesh && showApps
        ? const IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(child: HomeMeshCard(borderRadius: pairL)),
                SizedBox(width: _gap),
                Expanded(child: HomeProxyAppsRow(borderRadius: pairR)),
              ],
            ),
          )
        : showMesh
        ? const HomeMeshCard(single: true)
        : showApps
        ? const HomeProxyAppsRow(single: true)
        : null;
    final exitIp = shows(HomeCard.ip) ? HomeExitIp(dense: wide) : null;

    if (!wide) {
      return ListView(
        // 悬浮底栏盖在内容上（壳 extendBody）：底部留白要把它的高度（MediaQuery.padding.bottom）加进去
        padding: EdgeInsets.fromLTRB(_pad, 0, _pad, _pad + MediaQuery.paddingOf(context).bottom),
        children: _spaced([_BrandBar(actions: actions), hero, speed, subscription, features, metrics, exitIp]),
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
            speed,
            subscription,
            features,
            metrics,
            exitIp,
            const HomeSpeedTestCard(),   // 宽屏才有（同 iOS iPad / Duo）
            HomeActiveConnections(minRows: 5, fetch: fetchConnections),
          ]),
        ),
      );
    }

    // 够高：整页正好一屏，「网速」「活跃连接」撑满两列剩下的高度；不够高（最小窗口、手机横屏、大字号）：按内容高度排、整页滚动。
    // 用 IntrinsicHeight 量内容自己要多高（两个撑满的卡各报一个最小高度），和视口高度取大者——所以这棵子树里不能出现 LayoutBuilder。
    // 左栏底部「网络测速」卡（同 iOS iPad 横屏首页左栏）
    final left = _spaced([hero, takeover, if (speed != null) chart ? Expanded(child: speed) : speed, const HomeSpeedTestCard()]);
    final right = _spaced([subscription, features, metrics, exitIp, Expanded(child: HomeActiveConnections(expand: true, fetch: fetchConnections))]);
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

  /// 「首页卡片」：从按钮长出来的回弹气泡（2026-11-17 起，以前是底部抽屉），每张可关的卡一行开关。
  /// [anchor] = 按钮自己的 context（气泡按它定位）。
  void _showCardSettings(BuildContext anchor) {
    showMeowPopover<void>(
      anchor,
      title: S.homeCards,
      builder: (ctx) => Consumer(
        builder: (ctx, ref, _) {
          final cs = ctx.cs;
          final hidden = ref.watch(meowSettingProvider.select((s) => s.homeHiddenCards));
          final meshAvailable = ref.watch(meshVisibleProvider);
          final cards = [
            for (final c in HomeCard.values)
              if (!(isDesktopUi && c == HomeCard.chart) &&
                  (c != HomeCard.apps || _hasAppsCard) &&
                  (c != HomeCard.mesh || meshAvailable))
                c,
          ];
          void toggle(HomeCard c, bool on) => ref.read(meowSettingProvider.notifier).updateState(
            (s) => s.copyWith(
              homeHiddenCards: on ? s.homeHiddenCards.where((n) => n != c.name).toList() : [...s.homeHiddenCards, c.name],
            ),
          );
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              M3SegmentedList(
                children: [
                  for (final c in cards)
                    M3ListRow(
                      title: c.label,
                      titleSize: 15,
                      color: meowDialogRowColor(cs),
                      padding: const EdgeInsets.fromLTRB(16, 4, 8, 4),
                      onTap: () => toggle(c, hidden.contains(c.name)),
                      trailing: Switch(
                        value: !hidden.contains(c.name),
                        onChanged: MeowHaptics.onSwitch((on) => toggle(c, on)),
                      ),
                    ),
                ],
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 12, 8, 0),
                child: Text(S.homeCardsHint, style: TextStyle(fontSize: MeowFont.caption, color: cs.onSurfaceVariant)),
              ),
            ],
          );
        },
      ),
    );
  }
}

/// 手机端顶栏：App logo（当前桌面图标）+ 「MeowX」+ 本页的操作钮（宽屏的品牌在侧栏里，标题行用 [PageTitle]）。
class _BrandBar extends StatelessWidget {
  const _BrandBar({required this.actions});
  final Widget actions;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 64,
      child: Row(
        children: [
          const _AppLogo(),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              'MeowX',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 26,
                fontWeight: FontWeight.w800,
                letterSpacing: -0.2,
                color: context.cs.onSurface,
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

/// 首页左上角的 App logo：就是当前的桌面图标（「外观 › App 图标」选的那张，图里自带圆角）；
/// 默认的猫娘按 Bettbox「深色图标」开关取深 / 浅两张，非 Android 按主题深浅取。
class _AppLogo extends ConsumerWidget {
  const _AppLogo();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final darkIcon = ref.watch(themeSettingProvider.select((s) => s.useDarkIcon));
    final icon = ref.watch(appIconSupportedProvider) ? ref.watch(appIconProvider).value : null;
    final catgirl = (ref.watch(appIconSupportedProvider) ? darkIcon : context.isDarkMode)
        ? 'assets/images/icon_256.png'
        : 'assets/images/icon_light_256.png';
    final asset = switch (icon) {
      MeowAppIcon.catgirl || null => catgirl,
      _ => icon.preview,
    };
    return Image.asset(asset, width: 44, height: 44);
  }
}

/// 「重新查询出口 IP」：立即重查两格（未连接时只查国内那格）。
class _RefreshIpButton extends ConsumerWidget {
  const _RefreshIpButton();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final busy = ref.watch(exitIpProvider.select((s) => s.loadingDomestic || s.loadingGlobal));
    if (busy) {
      return Tooltip(
        message: '正在查询出口 IP',
        child: Container(
          width: 48,
          height: 48,
          alignment: Alignment.center,
          decoration: BoxDecoration(color: context.cs.surfaceContainerHighest, shape: BoxShape.circle),
          child: SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2.2, color: context.cs.onSurface)),
        ),
      );
    }
    return M3IconButton(
      icon: Icons.refresh_rounded,
      tooltip: '重新查询出口 IP',
      onPressed: () {
        MeowHaptics.tap();
        unawaited(ref.read(exitIpProvider.notifier).refresh(running: ref.read(isRunningProvider)));
      },
    );
  }
}
