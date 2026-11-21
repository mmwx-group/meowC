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
import '../../state/ui_prefs.dart';
import '../../theme/glass.dart';
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
    final ui = ref.watch(meowUiPrefsProvider);
    bool shows(HomeCard c) => (c == HomeCard.chart && isDesktopUi) || !hidden.contains(c.name);

    final actions = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (shows(HomeCard.ip) && !ui.hiddenBlocks.contains(HomeBlockId.exitIp)) ...[
          const _RefreshIpButton(),
          const SizedBox(width: 8),
        ],
        Builder(
          builder: (anchor) =>
              M3IconButton(icon: Icons.tune_rounded, tooltip: S.homeCards, onPressed: () => _showCardSettings(anchor)),
        ),
      ],
    );
    final up = shows(HomeCard.upload), down = shows(HomeCard.download), chart = shows(HomeCard.chart);
    final showApps = _hasAppsCard && shows(HomeCard.apps);
    final takeover = isDesktopUi ? const HomeTakeoverCard() : null;
    final tiles = [
      for (final c in const [HomeCard.proxied, HomeCard.direct, HomeCard.memory, HomeCard.dns])
        if (shows(c)) c,
    ];
    final showMesh = ref.watch(meshVisibleProvider) && shows(HomeCard.mesh);
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

    Widget? buildFeatures({required bool compact}) {
      if (showMesh && showApps) {
        if (compact) {
          return const HomeProxyAppsRow(single: false);
        }
        return const IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(child: HomeMeshCard(borderRadius: pairL)),
              SizedBox(width: _gap),
              Expanded(child: HomeProxyAppsRow(borderRadius: pairR)),
            ],
          ),
        );
      }
      if (showMesh) return HomeMeshCard(single: !compact);
      if (showApps) return HomeProxyAppsRow(single: !compact);
      return null;
    }

    Widget? buildBlock(HomeBlockId id, {required bool compact}) => switch (id) {
      HomeBlockId.hero => HomeHeroCard(dense: wide || ui.heightMode == HomeCardHeightMode.compact),
      HomeBlockId.speed =>
        up || down || chart
            ? HomeSpeedCard(
                up: up,
                down: down,
                chart: chart,
                dense: wide || ui.heightMode == HomeCardHeightMode.compact,
                expand: twoPane,
                compact: compact,
                chartHeight: compact ? (ui.heightMode.chartHeight * 0.72) : ui.heightMode.chartHeight,
              )
            : null,
      HomeBlockId.subscription => HomeSubscriptionCard(
        dense: wide || ui.heightMode == HomeCardHeightMode.compact,
        compact: compact,
      ),
      HomeBlockId.features => buildFeatures(compact: compact),
      HomeBlockId.metrics => tiles.isEmpty
          ? null
          : HomeMetricsRow(
              cards: tiles,
              dense: wide || ui.heightMode == HomeCardHeightMode.compact,
              compact: compact,
            ),
      HomeBlockId.exitIp => shows(HomeCard.ip)
          ? HomeExitIp(dense: wide || ui.heightMode == HomeCardHeightMode.compact, compact: compact)
          : null,
    };

    if (!wide) {
      // 手机端：默认严格保留经典单列顺序；开启双列或设置半宽卡片时，自动配对并排并等高自适应
      final rows = <Widget>[_BrandBar(actions: actions)];
      final activeIds = [
        for (final id in ui.blockOrder)
          if (id == HomeBlockId.hero || !ui.hiddenBlocks.contains(id)) id,
      ];
      bool wantsHalf(HomeBlockId id) {
        if (!id.canHalfWidth) return false;
        return switch (ui.columnsMode) {
          HomeColumnsMode.single => false,
          HomeColumnsMode.doubleCol => true,
          HomeColumnsMode.auto => ui.halfWidthBlocks.contains(id),
        };
      }

      var i = 0;
      while (i < activeIds.length) {
        final id = activeIds[i];
        if (wantsHalf(id)) {
          // 寻找紧邻的下一个可用半宽卡片进行双列等高配对
          Widget? left = buildBlock(id, compact: true);
          if (left == null) {
            i++;
            continue;
          }
          Widget? right;
          var nextIdx = i + 1;
          while (nextIdx < activeIds.length && right == null) {
            final nextId = activeIds[nextIdx];
            if (!wantsHalf(nextId)) break;
            right = buildBlock(nextId, compact: true);
            if (right == null) nextIdx++;
          }
          if (right != null) {
            rows.add(
              IntrinsicHeight(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(child: left),
                    const SizedBox(width: _gap),
                    Expanded(child: right),
                  ],
                ),
              ),
            );
            i = nextIdx + 1;
            continue;
          }
          // 落单的半宽卡自动展成整行，不留半行空洞
          final full = buildBlock(id, compact: false);
          if (full != null) rows.add(full);
          i++;
          continue;
        }
        final full = buildBlock(id, compact: false);
        if (full != null) rows.add(full);
        i++;
      }

      return ListView(
        padding: EdgeInsets.fromLTRB(_pad, 0, _pad, _pad + MediaQuery.paddingOf(context).bottom),
        children: _spaced(rows),
      );
    }

    final hero = buildBlock(HomeBlockId.hero, compact: false)!;
    final speed = buildBlock(HomeBlockId.speed, compact: false);
    final subscription = buildBlock(HomeBlockId.subscription, compact: false)!;
    final features = buildFeatures(compact: false);
    final metrics = buildBlock(HomeBlockId.metrics, compact: false);
    final exitIp = buildBlock(HomeBlockId.exitIp, compact: false);

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
            const HomeSpeedTestCard(),
            HomeActiveConnections(minRows: 5, fetch: fetchConnections),
          ]),
        ),
      );
    }

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

  /// 「自定义主页卡片」液态玻璃弹出气泡：预设布局 + 自适应列数 + 卡片高度 + 模块排序与整行/半宽 + 细项显隐。
  void _showCardSettings(BuildContext anchor) {
    showMeowPopover<void>(
      anchor,
      title: '自定义主页卡片',
      width: 312,
      builder: (ctx) => const _HomeCustomizePanel(),
    );
  }
}

class _HomeCustomizePanel extends ConsumerWidget {
  const _HomeCustomizePanel();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cs = context.cs;
    final ui = ref.watch(meowUiPrefsProvider);
    final hidden = ref.watch(meowSettingProvider.select((s) => s.homeHiddenCards));
    final meshAvailable = ref.watch(meshVisibleProvider);
    final activePreset = ui.activeLayoutPreset;

    void updateUi(MeowUiPrefs Function(MeowUiPrefs s) f) => ref.read(meowUiPrefsProvider.notifier).update(f);

    void toggleSubCard(HomeCard c, bool on) => ref.read(meowSettingProvider.notifier).updateState(
      (s) => s.copyWith(
        homeHiddenCards: on ? s.homeHiddenCards.where((n) => n != c.name).toList() : [...s.homeHiddenCards, c.name],
      ),
    );

    void moveBlock(int index, int delta) {
      final target = index + delta;
      if (target < 0 || target >= ui.blockOrder.length) return;
      MeowHaptics.select();
      final next = [...ui.blockOrder];
      final item = next.removeAt(index);
      next.insert(target, item);
      updateUi((s) => s.copyWith(blockOrder: next));
    }

    final subCards = [
      for (final c in HomeCard.values)
        if (!(isDesktopUi && c == HomeCard.chart) &&
            (c != HomeCard.apps || _hasAppsCard) &&
            (c != HomeCard.mesh || meshAvailable))
          c,
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        // 1. 布局预设
        Row(
          children: [
            for (final (i, p) in HomeLayoutPreset.values.indexed) ...[
              if (i > 0) const SizedBox(width: 6),
              Expanded(
                child: _PresetChip(
                  label: p.label,
                  selected: activePreset == p,
                  onTap: () {
                    MeowHaptics.select();
                    updateUi((s) => s.withLayoutPreset(p));
                  },
                ),
              ),
            ],
          ],
        ),
        const SizedBox(height: 12),
        // 2. 自适应列数
        Text('列数', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: cs.primary)),
        const SizedBox(height: 6),
        MeowSlideSegment<HomeColumnsMode>(
          items: const [
            (HomeColumnsMode.auto, '自动'),
            (HomeColumnsMode.single, '单列'),
            (HomeColumnsMode.doubleCol, '双列'),
          ],
          selected: ui.columnsMode,
          height: 36,
          fontSize: 13,
          onChanged: (v) => updateUi((s) => s.copyWith(columnsMode: v)),
        ),
        const SizedBox(height: 10),
        // 3. 自适应卡片高度
        Text('卡片高度', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: cs.primary)),
        const SizedBox(height: 6),
        MeowSlideSegment<HomeCardHeightMode>(
          items: const [
            (HomeCardHeightMode.compact, '紧凑'),
            (HomeCardHeightMode.standard, '标准'),
            (HomeCardHeightMode.comfortable, '舒展'),
          ],
          selected: ui.heightMode,
          height: 36,
          fontSize: 13,
          onChanged: (v) => updateUi((s) => s.copyWith(heightMode: v)),
        ),
        const SizedBox(height: 12),
        // 4. 卡片排序与整行/半宽
        Text('模块顺序与宽度', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: cs.primary)),
        const SizedBox(height: 6),
        M3SegmentedList(
          children: [
            for (final (i, block) in ui.blockOrder.indexed)
              _BlockRow(
                block: block,
                visible: block == HomeBlockId.hero || !ui.hiddenBlocks.contains(block),
                halfWidth: ui.halfWidthBlocks.contains(block),
                canMoveUp: i > 0,
                canMoveDown: i < ui.blockOrder.length - 1,
                onMoveUp: () => moveBlock(i, -1),
                onMoveDown: () => moveBlock(i, 1),
                onToggleVisible: block == HomeBlockId.hero
                    ? null
                    : () {
                        MeowHaptics.select();
                        updateUi((s) {
                          final next = {...s.hiddenBlocks};
                          if (!next.remove(block)) next.add(block);
                          return s.copyWith(hiddenBlocks: next);
                        });
                      },
                onToggleWidth: !block.canHalfWidth
                    ? null
                    : () {
                        MeowHaptics.select();
                        updateUi((s) {
                          final next = {...s.halfWidthBlocks};
                          if (!next.remove(block)) next.add(block);
                          return s.copyWith(halfWidthBlocks: next);
                        });
                      },
              ),
          ],
        ),
        const SizedBox(height: 12),
        // 5. 细项显示开关
        Text('细项开关', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: cs.primary)),
        const SizedBox(height: 6),
        M3SegmentedList(
          children: [
            for (final c in subCards)
              M3ListRow(
                title: c.label,
                titleSize: 14,
                color: meowDialogRowColor(cs),
                padding: const EdgeInsets.fromLTRB(14, 2, 8, 2),
                onTap: () => toggleSubCard(c, hidden.contains(c.name)),
                trailing: Transform.scale(
                  scale: 0.86,
                  child: Switch(
                    value: !hidden.contains(c.name),
                    onChanged: MeowHaptics.onSwitch((on) => toggleSubCard(c, on)),
                  ),
                ),
              ),
          ],
        ),
        const SizedBox(height: 10),
        TextButton(
          onPressed: () {
            MeowHaptics.tap();
            updateUi((s) => s.withLayoutPreset(HomeLayoutPreset.classic));
          },
          child: const Text('恢复默认布局'),
        ),
      ],
    );
  }
}

class _PresetChip extends StatelessWidget {
  const _PresetChip({required this.label, required this.selected, required this.onTap});
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = context.cs;
    return Material(
      color: selected ? cs.primary : cs.surfaceContainerHighest,
      shape: const StadiumBorder(),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              color: selected ? cs.onPrimary : cs.onSurface,
            ),
          ),
        ),
      ),
    );
  }
}

class _BlockRow extends StatelessWidget {
  const _BlockRow({
    required this.block,
    required this.visible,
    required this.halfWidth,
    required this.canMoveUp,
    required this.canMoveDown,
    required this.onMoveUp,
    required this.onMoveDown,
    required this.onToggleVisible,
    required this.onToggleWidth,
  });

  final HomeBlockId block;
  final bool visible, halfWidth, canMoveUp, canMoveDown;
  final VoidCallback onMoveUp, onMoveDown;
  final VoidCallback? onToggleVisible, onToggleWidth;

  @override
  Widget build(BuildContext context) {
    final cs = context.cs;
    return Container(
      decoration: BoxDecoration(
        color: meowDialogRowColor(cs),
        borderRadius: BorderRadius.circular(18),
      ),
      padding: const EdgeInsets.fromLTRB(12, 6, 8, 6),
      child: Row(
        children: [
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              InkWell(
                onTap: canMoveUp ? onMoveUp : null,
                child: Icon(Icons.keyboard_arrow_up_rounded, size: 18, color: canMoveUp ? cs.onSurfaceVariant : cs.outline.withValues(alpha: 0.35)),
              ),
              InkWell(
                onTap: canMoveDown ? onMoveDown : null,
                child: Icon(Icons.keyboard_arrow_down_rounded, size: 18, color: canMoveDown ? cs.onSurfaceVariant : cs.outline.withValues(alpha: 0.35)),
              ),
            ],
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              block.label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: visible ? cs.onSurface : cs.onSurfaceVariant.withValues(alpha: 0.55),
              ),
            ),
          ),
          if (onToggleWidth != null)
            Material(
              color: halfWidth ? cs.secondaryContainer : cs.surfaceContainerHighest,
              shape: const StadiumBorder(),
              clipBehavior: Clip.antiAlias,
              child: InkWell(
                onTap: onToggleWidth,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  child: Text(
                    halfWidth ? '半宽' : '整行',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      color: halfWidth ? cs.onSecondaryContainer : cs.onSurfaceVariant,
                    ),
                  ),
                ),
              ),
            ),
          if (onToggleVisible != null) ...[
            const SizedBox(width: 4),
            IconButton(
              visualDensity: VisualDensity.compact,
              iconSize: 18,
              tooltip: visible ? '隐藏' : '显示',
              onPressed: onToggleVisible,
              icon: Icon(
                visible ? Icons.visibility_rounded : Icons.visibility_off_rounded,
                color: visible ? cs.primary : cs.onSurfaceVariant,
              ),
            ),
          ],
        ],
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
      final spinner = SizedBox.square(
        dimension: 48,
        child: Center(
          child: SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2.2, color: context.cs.onSurface)),
        ),
      );
      if (meowGlassOn(context)) {
        return MeowGlassButton(tooltip: '正在查询出口 IP', onTap: null, child: spinner);
      }
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
