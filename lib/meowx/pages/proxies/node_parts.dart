import 'package:bett_box/enum/enum.dart';
import 'package:bett_box/providers/providers.dart';
import 'package:bett_box/widgets/icon.dart';
import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../panel/account.dart';
import '../../state/latency.dart';
import '../../theme/badges.dart';
import '../../theme/button_fill.dart';
import '../../theme/tokens.dart';
import '../../theme/unlock_badge.dart';

/// 名字是某个代理组时它的 icon（配置里组的 `icon`）；不是组、或者没配 icon 为空串。
/// 成员是代理组的节点格、组卡上的「当前选中」都拿它画图标，和组标签 / 组卡标题上的是同一张。
final groupIconProvider = Provider.autoDispose.family<String, String>(
  (ref, name) => ref.watch(
    currentGroupsStateProvider.select(
      (s) => s.value.firstWhereOrNull((g) => g.name == name)?.icon ?? '',
    ),
  ),
);

/// 嵌套代理组的小图标：[name] 不是组、或者那个组没配 icon 时什么都不画、不占位。
class NestedGroupIcon extends ConsumerWidget {
  const NestedGroupIcon(this.name, {super.key, required this.size, this.gap = 6});

  final String name;
  final double size;

  /// 图标与后面文字的间距（有图标时才有）。
  final double gap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (name.isEmpty) return const SizedBox.shrink();
    final icon = ref.watch(groupIconProvider(name));
    if (icon.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: EdgeInsets.only(right: gap),
      child: CommonTargetIcon(src: icon, size: size),
    );
  }
}

/// 延迟胶囊：等宽粗体的彩色字（只写数字，不带 ms，同 iOS），底用所在卡片的次级色（白卡上 = card2，樱粉主卡上 = 卡片底）；[bg] 为 null 只画字。
class MsChip extends StatelessWidget {
  const MsChip(this.ms, {super.key, required this.mode, this.bg, this.size = 11});

  final int? ms;
  final LatencyMode mode;
  final Color? bg;
  final double size;

  @override
  Widget build(BuildContext context) {
    final (text, color) = msStyle(context.mm, ms, mode, unit: false);   // 只写数字（同 iOS）
    final label = Text(
      text,
      maxLines: 1,
      softWrap: false,
      style: MeowFont.mono(size: size, weight: FontWeight.w700, color: color),
    );
    if (bg == null) return label;
    final big = size > 11;
    return Container(
      padding: EdgeInsets.symmetric(horizontal: big ? 8 : 7, vertical: big ? 3 : 2),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(big ? 10 : 9)),
      child: label,
    );
  }
}

/// 代理组类型小标签（select / url-test / fallback …）：等宽玫红字，底由所在卡片决定。
class GroupTypeTag extends StatelessWidget {
  const GroupTypeTag(this.type, {super.key, required this.bg, this.small = false});

  final GroupType type;
  final Color bg;
  final bool small;

  @override
  Widget build(BuildContext context) {
    final mm = context.mm;
    return Container(
      padding: EdgeInsets.symmetric(horizontal: small ? 6 : 7, vertical: small ? 1 : 2),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(small ? 7 : 8)),
      child: Text(
        groupBadge(type.name, mm).label,
        maxLines: 1,
        softWrap: false,
        style: MeowFont.mono(size: small ? 10 : 11, weight: FontWeight.w600, color: mm.accent),
      ),
    );
  }
}

/// 胶囊按钮（图标 + 文字）：卡片底配墨色字、玫红图标；[filled] = 墨色实底（本页主操作；液态玻璃主题下是按钮那档静态半透明、墨色字）。
/// [busy] 时图标位转圈、不可点。
class PillButton extends StatelessWidget {
  const PillButton({
    super.key,
    required this.label,
    required this.onTap,
    this.icon = Icons.bolt_rounded,
    this.filled = false,
    this.busy = false,
    this.height = 44,
  });

  final String label;
  final VoidCallback? onTap;
  final IconData icon;
  final bool filled, busy;
  final double height;

  @override
  Widget build(BuildContext context) {
    final mm = context.mm;
    final tint = filled ? mm.onProminent : mm.accent;
    return Material(
      color: mm.buttonFill(filled ? MeowButtonFill.prominent : MeowButtonFill.plain),
      shape: StadiumBorder(side: mm.buttonSide),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: busy ? null : onTap,
        child: Container(
          constraints: BoxConstraints(minHeight: height),
          padding: const EdgeInsets.symmetric(horizontal: 14),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: 15,
                height: 15,
                child: busy
                    ? CircularProgressIndicator(strokeWidth: 2, color: tint)
                    : Icon(icon, size: 15, color: tint),
              ),
              const SizedBox(width: 4),
              Text(
                label,
                maxLines: 1,
                softWrap: false,
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: filled ? mm.onProminent : mm.t1),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 一行 =「可省略的文字 + 定宽的头 / 尾」（徽标、延迟胶囊这些不能省略的东西）。
/// 定宽部分放得下就按原大小；放不下（窄屏 + 大字号）整体缩小到行宽（头尾都有时各占一半）、文字让到 0——任何宽度都不会溢出。
class FitRow extends StatelessWidget {
  const FitRow({super.key, this.head, required this.text, this.tail});

  final Widget? head, tail;
  final Widget text;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, c) {
        final limit = head != null && tail != null ? c.maxWidth / 2 : c.maxWidth;
        Widget fixed(Widget w) => ConstrainedBox(
          constraints: BoxConstraints(maxWidth: limit),
          child: FittedBox(fit: BoxFit.scaleDown, child: w),
        );
        return Row(
          children: [
            if (head != null) fixed(head!),
            Expanded(child: text),
            if (tail != null) fixed(tail!),
          ],
        );
      },
    );
  }
}

/// 组当前选中的节点，沿选中链解析到叶子（组里选的是另一个组就继续往下找）。
final _currentLeafProvider = Provider.autoDispose.family<String, String>((ref, groupName) {
  var name = groupName;
  final seen = <String>{};
  while (seen.add(name)) {
    final next = ref.watch(getSelectedProxyNameProvider(name));
    if (next == null || next.isEmpty) break;   // 不是组（已到叶子）或还没有选中
    name = next;
  }
  return name == groupName ? '' : name;
});

/// 组当前选中节点（叶子）的回程奖牌 + 解锁徽标，跟在「当前选中」的名字后面；都没有就不占位。
class CurrentBadges extends ConsumerWidget {
  const CurrentBadges({super.key, required this.groupName});
  final String groupName;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final leaf = ref.watch(_currentLeafProvider(groupName));
    if (leaf.isEmpty) return const SizedBox.shrink();
    final medal = ref.watch(nodeMedalsProvider.select((m) => m[leaf]));
    final unlocks = ref.watch(nodeUnlocksProvider.select((m) => m[leaf]));
    if (medal == null && unlocks == null) return const SizedBox.shrink();
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        const SizedBox(width: 4),
        if (medal != null) MedalBadge(medal, size: 14),
        // 奖牌 / 解锁之间留 4（各自还有 2 的点按边距）：无底符号贴在一起分不开
        if (medal != null && unlocks != null) const SizedBox(width: 4),
        if (unlocks != null) UnlockBadge(unlocks, size: 14),
      ],
    );
  }
}
