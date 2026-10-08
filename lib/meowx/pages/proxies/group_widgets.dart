import 'package:bett_box/enum/enum.dart';
import 'package:bett_box/models/models.dart';
import 'package:bett_box/providers/providers.dart';
import 'package:bett_box/views/proxies/common.dart';
import 'package:bett_box/widgets/icon.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/strings.dart';
import '../../state/latency.dart';
import '../../state/meow_settings.dart';
import '../../theme/tokens.dart';
import '../../theme/widgets.dart';
import 'node_grid.dart';
import 'node_parts.dart';

/// 组标签（手机标签布局顶部横滑的那一条）：icon + 组名；选中 = 墨色实底配页面底色的字。
class GroupChip extends StatelessWidget {
  const GroupChip({
    super.key,
    required this.group,
    required this.selected,
    required this.onTap,
  });
  final Group group;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final mm = context.mm;
    return Material(
      color: selected ? mm.t1 : mm.elev,
      shape: const StadiumBorder(),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Container(
          constraints: const BoxConstraints(minHeight: 44, maxWidth: 240),
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (group.icon.isNotEmpty) ...[
                CommonTargetIcon(src: group.icon, size: 18),
                const SizedBox(width: 6),
              ],
              Flexible(
                child: Text(
                  group.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                    color: selected ? mm.bg : mm.t1,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 测速本组；测速中转圈。默认是摘要卡里的「测速」胶囊，[compact] = 列表布局组卡上的小闪电。
class GroupTestButton extends StatelessWidget {
  const GroupTestButton({super.key, required this.group, this.compact = false, this.height = 44});
  final Group group;
  final bool compact;
  final double height;

  @override
  Widget build(BuildContext context) {
    final mm = context.mm;
    return ListenableBuilder(
      listenable: delayTestCoordinator,
      builder: (_, _) {
        final testing = delayTestCoordinator.isTestingGroup(group.name);
        void run() => delayTest(group.all, testUrl: group.testUrl, groupName: group.name);
        if (!compact) {
          return Tooltip(
            message: S.testGroup,
            child: PillButton(label: '测速', busy: testing, height: height, onTap: run),
          );
        }
        return SizedBox(
          width: 36,
          height: 36,
          child: testing
              ? Center(
                  child: SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2, color: mm.accent),
                  ),
                )
              : IconButton(
                  padding: EdgeInsets.zero,
                  iconSize: 20,
                  icon: Icon(Icons.bolt_rounded, color: mm.accent),
                  tooltip: S.testGroup,
                  onPressed: run,
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
      onChanged: (_) => toggle(),
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
    );
    final body = Material(
      color: mm.elev,
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

/// 组卡：名 + 类型 / 当前选中 + 延迟。两处用：
/// - 宽屏左栏的一行（[selected] = 柔粉底 + 玫红 2px 描边）；
/// - 手机列表布局里可展开的组头（[expanded] 非 null）：多画成员数、测速钮和箭头，展开时换成樱粉底，下面接节点网格。
class GroupCard extends ConsumerWidget {
  const GroupCard({super.key, required this.group, required this.onTap, this.selected = false, this.expanded});
  final Group group;
  final VoidCallback onTap;
  final bool selected;
  final bool? expanded;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mm = context.mm;
    final list = expanded != null;
    final open = expanded == true;
    final current = ref.watch(getSelectedProxyNameProvider(group.name)) ?? '';
    final mode = ref.watch(meowSettingProvider.select((s) => s.latencyMode));
    return Material(
      // 深色主题的 soft 是半透明的，先叠到卡片底上
      color: selected ? Color.alphaBlend(mm.soft, mm.elev) : (open ? mm.hero : mm.elev),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(list ? 22 : 16),
        side: BorderSide(color: selected ? mm.accent : Colors.transparent, width: 2),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Container(
          constraints: const BoxConstraints(minHeight: 58),
          padding: list ? const EdgeInsets.fromLTRB(14, 10, 12, 10) : const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
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
                        style: TextStyle(fontSize: list ? 16 : 14, fontWeight: FontWeight.w600, color: mm.t1),
                      ),
                      tail: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const SizedBox(width: 6),
                          if (list) ...[
                            Text('${group.all.length}', style: MeowFont.mono(size: 11, color: mm.t2)),
                            const SizedBox(width: 6),
                          ],
                          GroupTypeTag(group.type, bg: selected || open ? mm.elev : mm.card2, small: !list),
                        ],
                      ),
                    ),
                    const SizedBox(height: 4),
                    FitRow(
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
                          if (current.isNotEmpty) ...[
                            const SizedBox(width: 6),
                            MsChip(
                              ref.watch(getDelayProvider(proxyName: current, testUrl: group.testUrl)),
                              mode: mode,
                            ),
                          ],
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              if (list) ...[
                const SizedBox(width: 4),
                GroupTestButton(group: group, compact: true),
                RotatedBox(
                  quarterTurns: open ? 3 : 1,
                  child: MeowIcon(MeowGlyph.chevron, size: 16, color: mm.t2),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// 当前组摘要（樱粉主卡）：类型 + 成员数 + 当前选中 + 延迟 + 测速；url-test / fallback 组带「自动选择」开关，手选 = 固定。
/// 手机（标签布局每页的头）按 ANodes 排成两行；[wide] = 宽屏右栏，按 WNodes 排成一行并带组名。
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
    final mode = ref.watch(meowSettingProvider.select((s) => s.latencyMode));
    final delay = current.isEmpty
        ? null
        : ref.watch(getDelayProvider(proxyName: current, testUrl: group.testUrl));
    final members = Text(
      '${group.all.length} 个成员${computed ? (fixed.isEmpty ? ' · 自动' : ' · 已固定') : ''}',
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(fontSize: 12, color: mm.t2),
    );
    final tag = GroupTypeTag(group.type, bg: mm.elev);

    if (wide) {
      return Container(
        padding: const EdgeInsets.fromLTRB(14, 10, 12, 10),
        decoration: BoxDecoration(color: mm.hero, borderRadius: BorderRadius.circular(20)),
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
                        child: Text(
                          current.isEmpty ? '当前 —' : '当前 $current',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 12, color: mm.t2),
                        ),
                      ),
                      if (current.isNotEmpty)
                        Text(
                          ' · ${msStyle(mm, delay, mode).$1}',
                          maxLines: 1,
                          softWrap: false,
                          style: TextStyle(fontSize: 12, color: mm.t2),
                        ),
                      CurrentBadges(groupName: group.name),
                    ],
                  ),
                ],
              ),
            ),
            if (computed) ...[const SizedBox(width: 10), AutoSelectToggle(group: group, pill: true)],
            const SizedBox(width: 10),
            GroupTestButton(group: group, height: 40),
          ],
        ),
      );
    }

    // 当前节点和节点格同一画法：国旗换成地区码标签
    final (code, name) = splitRegion(current);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(color: mm.hero, borderRadius: BorderRadius.circular(22)),
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
                      head: code == null
                          ? null
                          : Padding(padding: const EdgeInsets.only(right: 6), child: RegionTag(code)),
                      text: Text(
                        current.isEmpty ? '—' : name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: mm.t1),
                      ),
                      tail: CurrentBadges(groupName: group.name),
                    ),
                  ],
                ),
              ),
              if (current.isNotEmpty) ...[
                const SizedBox(width: 10),
                MsChip(delay, mode: mode, bg: mm.elev, size: 12),
              ],
              const SizedBox(width: 10),
              GroupTestButton(group: group),
            ],
          ),
          if (computed) ...[const SizedBox(height: 10), AutoSelectToggle(group: group)],
        ],
      ),
    );
  }
}
