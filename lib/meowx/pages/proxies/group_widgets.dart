import 'package:bett_box/enum/enum.dart';
import 'package:bett_box/models/models.dart';
import 'package:bett_box/providers/providers.dart';
import 'package:bett_box/views/proxies/common.dart';
import 'package:bett_box/widgets/icon.dart';
import '../../theme/card_surface.dart';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/strings.dart';
import '../../state/latency.dart';
import '../../state/meow_settings.dart';
import '../../theme/button_fill.dart';
import '../../theme/haptics.dart';
import '../../theme/motion.dart';
import '../../theme/popover.dart';
import '../../theme/tokens.dart';
import '../../theme/widgets.dart';
import 'node_grid.dart';
import 'node_parts.dart';

/// 单组布局顶部的组按钮：当前组的 icon + 组名 / 类型 · 成员数 · 共几个组，行尾「切换」胶囊。点开选组面板（[showGroupPicker]）。
/// [onTap] 拿到的是按钮自己的 context：宽屏的选组面板从按钮下面弹出，要按它定位。
class GroupPickerButton extends StatelessWidget {
  const GroupPickerButton({super.key, required this.group, required this.groupCount, required this.onTap});
  final Group group;
  final int groupCount;
  final void Function(BuildContext anchor) onTap;

  @override
  Widget build(BuildContext context) {
    final mm = context.mm;
    return Semantics(
      button: true,
      label: '当前代理组 ${group.name}，${S.pickGroup}',
      excludeSemantics: true,
      child: MeowCardMaterial(
        shape: const RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(20))),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => onTap(context),
          child: Container(
            constraints: const BoxConstraints(minHeight: 58),
            padding: const EdgeInsets.fromLTRB(14, 10, 12, 10),
            child: Row(
              children: [
                if (group.icon.isNotEmpty) ...[
                  CommonTargetIcon(src: group.icon, size: 22),
                  const SizedBox(width: 10),
                ],
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        group.name,   // 国旗原样显示，和组卡、节点格一个画法
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: mm.t1),
                      ),
                      const SizedBox(height: 3),
                      FitRow(
                        head: Padding(
                          padding: const EdgeInsets.only(right: 6),
                          child: GroupTypeTag(group.type, bg: mm.card2, small: true),
                        ),
                        text: Text(
                          '${group.all.length} 个成员 · 共 $groupCount 个组',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 12, color: mm.t2),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Container(
                  constraints: const BoxConstraints(minHeight: 32),
                  padding: const EdgeInsets.only(left: 12, right: 8),
                  decoration: ShapeDecoration(
                    color: mm.buttonFill(MeowButtonFill.accent, classic: Color.alphaBlend(mm.soft, mm.elev)),
                    shape: StadiumBorder(side: mm.buttonSide),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        '切换',
                        maxLines: 1,
                        softWrap: false,
                        style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: mm.accent),
                      ),
                      const SizedBox(width: 2),
                      Icon(Icons.unfold_more_rounded, size: 18, color: mm.accent),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 选组面板：每组一张组卡（icon / 名 / 类型 / 成员数 / 当前选中 + 延迟），当前组高亮。点一组 → 收起并返回组名；点外面收起 → null。
/// 手机是底部弹出面板；有侧栏的宽屏（平板竖屏、Windows 窄窗口）从组按钮下面弹出（同奖牌详情的 popover），宽度跟按钮。
Future<String?> showGroupPicker(
  BuildContext anchor, {
  required List<Group> groups,
  required String current,
  required bool wide,
}) {
  Widget list(BuildContext ctx, EdgeInsets padding) => ListView.separated(
    shrinkWrap: true,
    padding: padding,
    itemCount: groups.length,
    separatorBuilder: (_, _) => const SizedBox(height: 8),
    itemBuilder: (_, i) => GroupCard(
      group: groups[i],
      selected: groups[i].name == current,
      showCount: true,
      onTap: () => Navigator.of(ctx).pop(groups[i].name),
    ),
  );

  if (wide) {
    final width = anchor.size?.width ?? 360;
    return showAnchoredPopover<String>(
      anchor,
      width: math.min(width, 440),
      builder: (ctx) => ColoredBox(color: ctx.mm.bg, child: list(ctx, const EdgeInsets.all(8))),
    );
  }
  return showModalBottomSheet<String>(
    context: anchor,
    showDragHandle: true,
    isScrollControlled: true,   // 默认上限是屏高的 9/16；组多时放到 3/4
    useSafeArea: true,
    backgroundColor: anchor.mm.bg,   // 组卡是白卡，垫在页面底色上（同页面里的样子）
    builder: (ctx) {
      final mm = ctx.mm;
      return ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(ctx).height * 0.75),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 10),
              child: Text(
                S.pickGroup,
                style: TextStyle(fontSize: MeowFont.headline, fontWeight: FontWeight.w600, color: mm.t1),
              ),
            ),
            Flexible(child: list(ctx, EdgeInsets.fromLTRB(16, 0, 16, 16 + MediaQuery.paddingOf(ctx).bottom))),
          ],
        ),
      );
    },
  );
}

/// 测速本组 + 组延迟合成一个钮（与 iOS / macOS 的 LatencyTestButton 一致）：没测过是闪电（摘要卡的胶囊带「测速」二字），
/// 测过显示组延迟（= 当前选中节点的延迟，色阶同 [MsChip]），测速中转圈；点一下重新测本组。
/// 默认是摘要卡里的胶囊，[compact] = 列表布局组卡上奶白胶囊。
class GroupTestButton extends ConsumerWidget {
  const GroupTestButton({super.key, required this.group, required this.delay, this.compact = false, this.height = 44});
  final Group group;

  /// 组延迟（getDelayProvider 同口径：null = 没测过，0 = 测试中，<0 = 超时）
  final int? delay;
  final bool compact;
  final double height;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mm = context.mm;
    final mode = ref.watch(meowSettingProvider.select((s) => s.latencyMode));
    return ListenableBuilder(
      listenable: delayTestCoordinator,
      builder: (_, _) {
        final testing = delayTestCoordinator.isTestingGroup(group.name) || delay == 0;
        void run() {
          MeowHaptics.tap();
          delayTest(group.all, testUrl: group.testUrl, groupName: group.name);
        }
        final Widget content;
        if (testing) {
          content = SizedBox(width: 13, height: 13, child: CircularProgressIndicator(strokeWidth: 2, color: mm.accent));
        } else if (delay == null) {
          // 20 号：Material 的 bolt 在 24 格里留白多，20 号才和 iOS 胶囊里 14pt 的 bolt.fill 一样大
          final bolt = Icon(Icons.bolt_rounded, size: compact ? 20 : 17, color: mm.accent);
          content = compact
              ? bolt
              : Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    bolt,
                    const SizedBox(width: 2),
                    Text('测速', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: mm.t1)),
                  ],
                );
        } else {
          final (text, color) = msStyle(mm, delay, mode, unit: false);
          content = Text(
            text,
            maxLines: 1,
            softWrap: false,
            style: MeowFont.mono(size: compact ? 12 : 13, weight: FontWeight.w700, color: color),
          );
        }
        return Tooltip(
          message: S.testGroup,
          child: Material(
            color: compact ? mm.card2 : mm.elev,
            shape: const StadiumBorder(),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: testing ? null : run,
              child: Container(
                constraints: BoxConstraints(minWidth: compact ? MeowChip.width : 64, minHeight: compact ? MeowChip.height : height),
                padding: EdgeInsets.symmetric(horizontal: compact ? 9 : 14),
                alignment: Alignment.center,
                child: AnimatedSwitcher(duration: const Duration(milliseconds: 180), child: content),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// url-test / fallback 组的「自动选择」开关：开 = 按策略自动选（健康检查 / 故障转移照常）；手选节点后翻成关（已固定）。
/// 打开 = 取消固定，关掉 = 把当前自动选中的节点固定下来。
/// 默认是一整行（名称 + 说明 + 开关）；[pill] = 宽屏摘要卡里的胶囊，说明放进悬停提示。
class AutoSelectToggle extends ConsumerWidget {
  const AutoSelectToggle({super.key, required this.group, this.pill = false});
  final Group group;
  final bool pill;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mm = context.mm;
    final auto = watchFixedMember(ref, group).isEmpty;
    final hint = auto
        ? (group.type == GroupType.Fallback ? '按可用性自动切换' : '按延迟自动切换')
        : '已手动固定，打开恢复';
    void toggle() => toggleAutoSelect(ref, group);
    final label = Text(
      '自动选择',
      maxLines: 1,
      softWrap: false,
      style: TextStyle(
        fontSize: pill ? 13 : 14,
        fontWeight: pill ? FontWeight.w600 : FontWeight.w500,
        color: mm.t1,
      ),
    );
    final sw = Switch(
      value: auto,
      onChanged: MeowHaptics.onSwitch((_) => toggle()),
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
    );
    final body = MeowCardMaterial(
      shape: pill
          ? const StadiumBorder()
          : const RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(14))),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: toggle,
        child: Container(
          constraints: BoxConstraints(minHeight: pill ? 40 : 44),
          padding: EdgeInsets.only(left: 12, right: pill ? 6 : 8),
          child: Row(
            mainAxisSize: pill ? MainAxisSize.min : MainAxisSize.max,
            children: [
              label,
              const SizedBox(width: 8),
              if (!pill) ...[
                Expanded(
                  child: Text(
                    hint,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.end,
                    style: TextStyle(fontSize: 12, color: mm.t2),
                  ),
                ),
                const SizedBox(width: 8),
              ],
              sw,
            ],
          ),
        ),
      ),
    );
    return pill ? Tooltip(message: hint, child: body) : body;
  }
}

/// 组卡：名 + 类型 / 当前选中 + 延迟。三处用：
/// - 宽屏左栏的一行（[selected] = 柔粉底 + 玫红 2px 描边）；
/// - 单组布局选组面板里的一行（同上，[showCount] 多画成员数）；
/// - 手机列表布局里可展开的组头（[expanded] 非 null）：多画成员数、测速钮和箭头，展开时换成樱粉底（液态玻璃主题下不换，
///   全部卡片一致，展开看箭头），下面接节点网格。
class GroupCard extends ConsumerWidget {
  const GroupCard({
    super.key,
    required this.group,
    required this.onTap,
    this.selected = false,
    this.expanded,
    this.showCount = false,
  });
  final Group group;
  final VoidCallback onTap;
  final bool selected;
  final bool? expanded;
  final bool showCount;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mm = context.mm;
    final list = expanded != null;
    final open = expanded == true;
    final current = ref.watch(getSelectedProxyNameProvider(group.name)) ?? '';
    final mode = ref.watch(meowSettingProvider.select((s) => s.latencyMode));
    final delay = current.isEmpty ? null : ref.watch(getDelayProvider(proxyName: current, testUrl: group.testUrl));
    if (list) return _listCard(context, mm, current, delay, open);
    return MeowCardMaterial(
      // 深色主题的 soft 是半透明的，先叠到卡片底上
      color: selected ? mm.selectedCard : null,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: selected ? mm.accent : Colors.transparent, width: 2),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Container(
          constraints: const BoxConstraints(minHeight: 58),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
          child: Row(
            children: [
              if (group.icon.isNotEmpty) ...[
                CommonTargetIcon(src: group.icon, size: 20),
                const SizedBox(width: 8),
              ],
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    FitRow(
                      text: Text(
                        group.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: mm.t1),
                      ),
                      tail: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const SizedBox(width: 6),
                          if (showCount) ...[
                            Text('${group.all.length}', style: MeowFont.mono(size: 11, color: mm.t2)),
                            const SizedBox(width: 6),
                          ],
                          GroupTypeTag(group.type, bg: selected ? mm.elev : mm.card2, small: true),
                        ],
                      ),
                    ),
                    const SizedBox(height: 4),
                    FitRow(
                      head: NestedGroupIcon(current, size: 14, gap: 4),   // 当前选中的是代理组时带上它的 icon
                      text: Text(
                        current.isEmpty ? '—' : current,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 12, color: mm.t2),
                      ),
                      tail: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          CurrentBadges(groupName: group.name),
                          // 选组面板的组卡没有测速钮，延迟留在这一行（列表布局见 _listCard）
                          if (current.isNotEmpty) ...[
                            const SizedBox(width: 6),
                            MsChip(delay, mode: mode),
                          ],
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 列表布局的组卡（同 iOS 节点页）：第一行 图标 · 组名 · 类型标签 ……… 成员数 · 延迟测速钮 · 展开钮；
  /// 第二行 当前选中 ……… 奖牌 / 解锁（贴卡片右边，按钮只占第一行）。延迟在测速钮上，第二行不再重复。
  Widget _listCard(BuildContext context, MeowTokens mm, String current, int? delay, bool open) {
    // 液态玻璃主题下展开了也是普通的玻璃卡片
    final hero = open && !mm.glass;
    return MeowCardMaterial(
      color: hero ? mm.hero : null,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(22))),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 12, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // 左块 图标 · 组名 · 类型标签（组名先省略，标签放不下就等比缩小）；右块 成员数 · 测速钮 · 展开钮
              // （最多占六成，放不下也等比缩小）。窄屏 + 大字号时任何宽度都不溢出
              LayoutBuilder(
                builder: (context, box) => Row(
                  children: [
                    Expanded(
                      child: Row(
                        children: [
                          if (group.icon.isNotEmpty) ...[
                            CommonTargetIcon(src: group.icon, size: 20),
                            const SizedBox(width: 8),
                          ],
                          Flexible(
                            flex: 3,
                            child: Text(
                              group.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: mm.t1),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Flexible(
                            flex: 2,
                            child: FittedBox(
                              fit: BoxFit.scaleDown,
                              alignment: Alignment.centerLeft,
                              child: GroupTypeTag(group.type, bg: hero ? mm.elev : mm.card2),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    ConstrainedBox(
                      constraints: BoxConstraints(maxWidth: box.maxWidth * 0.6),
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        alignment: Alignment.centerRight,
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text('${group.all.length}', style: MeowFont.mono(size: 12, color: mm.t2)),
                            const SizedBox(width: 8),
                            GroupTestButton(group: group, delay: delay, compact: true),
                            const SizedBox(width: 6),
                            // 箭头胶囊本身也能点：与点组卡同一个动作（展开 / 收起）
                            MeowChip(onTap: onTap, child: _GroupChevron(open: open)),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              if (current.isNotEmpty) ...[
                const SizedBox(height: 10),
                FitRow(
                  head: NestedGroupIcon(current, size: 16, gap: 6),   // 当前选中的是代理组时带上它的 icon
                  text: Text(
                    current,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500, color: mm.t2),
                  ),
                  tail: Padding(padding: const EdgeInsets.only(left: 6), child: CurrentBadges(groupName: group.name)),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// 组卡上的箭头：收起朝下、展开朝上，转动用弹跳弹簧。初值按当前状态给：滚动回来 / 重建时不重播。
class _GroupChevron extends StatefulWidget {
  const _GroupChevron({required this.open});
  final bool open;

  @override
  State<_GroupChevron> createState() => _GroupChevronState();
}

class _GroupChevronState extends State<_GroupChevron> with SingleTickerProviderStateMixin {
  /// 0 = 朝下，1 = 朝上（转过 180°）
  late final _turn = AnimationController.unbounded(vsync: this, value: widget.open ? 1 : 0);

  @override
  void didUpdateWidget(_GroupChevron old) {
    super.didUpdateWidget(old);
    if (old.open != widget.open) {
      MeowMotion.spring(_turn, widget.open ? 1 : 0, MeowMotion.bouncy, reduce: MeowMotion.reduced(context));
    }
  }

  @override
  void dispose() {
    _turn.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _turn,
    // 图形本身朝右：先转 90° 朝下，再按进度转到朝上
    // 同 iOS：收起朝右、展开转 90° 朝下（以前收起朝下、展开转 180° 朝上，和 iOS 不一致）
    builder: (_, child) => Transform.rotate(angle: _turn.value * math.pi / 2, child: child),
    child: const MeowChipChevron(),
  );
}

/// 当前组摘要（樱粉主卡；液态玻璃主题下和其它卡片一样是磨砂玻璃卡片）：类型 + 成员数 + 当前选中 + 延迟 + 测速；
/// url-test / fallback 组带「自动选择」开关，手选 = 固定。
/// 手机（单组布局组按钮下面）按 ANodes 排成两行；[wide] = 宽屏右栏，按 WNodes 排成一行并带组名。
class GroupSummary extends ConsumerWidget {
  const GroupSummary({super.key, required this.group, this.wide = false});
  final Group group;
  final bool wide;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mm = context.mm;
    final computed = group.type.isComputedSelected;
    final fixed = watchFixedMember(ref, group);
    // 和网格的高亮同一口径：正在切换时先显示目标节点
    final pending = computed ? ref.watch(pendingPickProvider.select((m) => m[group.name])) : null;
    final current = (pending != null && pending.isNotEmpty)
        ? pending
        : (ref.watch(getSelectedProxyNameProvider(group.name)) ?? '');
    final currentIcon = current.isEmpty ? '' : ref.watch(groupIconProvider(current));
    final delay = current.isEmpty
        ? null
        : ref.watch(getDelayProvider(proxyName: current, testUrl: group.testUrl));
    final members = Text(
      '${group.all.length} 个成员${computed ? (fixed.isEmpty ? ' · 自动' : ' · 已固定') : ''}',
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(fontSize: 12, color: mm.t2),
    );
    // 樱粉主卡上的小标签用卡片底；液态玻璃主题下主卡是普通的玻璃卡片，标签用卡片里的次级块
    final tag = GroupTypeTag(group.type, bg: mm.glass ? mm.card2 : mm.elev);
    final heroColor = mm.glass ? null : mm.hero;

    if (wide) {
      return MeowCard(
        padding: const EdgeInsets.fromLTRB(14, 10, 12, 10),
        radius: BorderRadius.circular(20),
        color: heroColor,
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  FitRow(
                    head: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 200),
                          child: Text(
                            group.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: mm.t1),
                          ),
                        ),
                        const SizedBox(width: 6),
                        tag,
                        const SizedBox(width: 6),
                      ],
                    ),
                    text: members,
                  ),
                  const SizedBox(height: 2),
                  // 延迟单独一段、不参与省略：名字再长也看得到
                  Row(
                    children: [
                      Flexible(
                        // 当前选中的是代理组、且它配了 icon 时，名字前带上它的 icon
                        child: Text.rich(
                          TextSpan(
                            children: [
                              TextSpan(text: current.isEmpty ? '当前 —' : '当前 '),
                              if (currentIcon.isNotEmpty)
                                WidgetSpan(
                                  alignment: PlaceholderAlignment.middle,
                                  child: Padding(
                                    padding: const EdgeInsets.only(right: 4),
                                    child: CommonTargetIcon(src: currentIcon, size: 14),
                                  ),
                                ),
                              if (current.isNotEmpty) TextSpan(text: current),
                            ],
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 12, color: mm.t2),
                        ),
                      ),
                      CurrentBadges(groupName: group.name),
                    ],
                  ),
                ],
              ),
            ),
            if (computed) ...[const SizedBox(width: 10), AutoSelectToggle(group: group, pill: true)],
            const SizedBox(width: 10),
            GroupTestButton(group: group, delay: delay, height: 40),
          ],
        ),
      );
    }

    return MeowCard(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      radius: BorderRadius.circular(22),
      color: heroColor,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    FitRow(
                      head: Padding(padding: const EdgeInsets.only(right: 6), child: tag),
                      text: members,
                    ),
                    const SizedBox(height: 3),
                    FitRow(
                      head: NestedGroupIcon(current, size: 18),   // 当前选中的是代理组时带上它的 icon
                      text: Text(
                        current.isEmpty ? '—' : current,   // 国旗原样显示，和节点格、组名一个画法
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: mm.t1),
                      ),
                      tail: CurrentBadges(groupName: group.name),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 10),
              GroupTestButton(group: group, delay: delay),
            ],
          ),
          if (computed) ...[const SizedBox(height: 10), AutoSelectToggle(group: group)],
        ],
      ),
    );
  }
}
