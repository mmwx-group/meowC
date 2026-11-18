import 'dart:async';

import 'package:bett_box/enum/enum.dart';
import 'package:bett_box/providers/providers.dart';
import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/meow_settings.dart';
import '../../theme/haptics.dart';
import '../../theme/m3.dart';
import '../../theme/m3_kit.dart';
import '../proxies/group_widgets.dart';
import '../proxies/node_grid.dart';
import '../proxies/node_parts.dart';

/// 宽屏首页点「当前节点」行就地弹出的节点浮层（同 iOS iPad / Duo 的 NodePickerPopover）：
/// 上面一排可选的代理组（手动选择 / 延迟最低 / 故障转移）、下面这个组的成员与延迟，点成员 = 切过去（规则同节点页，见 [pickNode]）。
class NodePickerPanel extends ConsumerStatefulWidget {
  const NodePickerPanel({super.key, this.initialGroup});

  /// 先停在哪个组（当前出口所在的组）；不在可选的组里就取第一个
  final String? initialGroup;

  @override
  ConsumerState<NodePickerPanel> createState() => _NodePickerPanelState();
}

class _NodePickerPanelState extends ConsumerState<NodePickerPanel> {
  String? _group;

  @override
  Widget build(BuildContext context) {
    final cs = context.cs;
    final groups = [
      for (final g in ref.watch(currentGroupsStateProvider.select((s) => s.value)))
        if (g.type == GroupType.Selector || g.type.isComputedSelected) g,
    ];
    if (groups.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(16),
        child: Text('没有可选的代理组', style: TextStyle(color: cs.onSurfaceVariant)),
      );
    }
    final group =
        groups.firstWhereOrNull((g) => g.name == (_group ?? widget.initialGroup)) ?? groups.first;
    final selected = ref.watch(getSelectedProxyNameProvider(group.name)) ?? '';
    final pending = ref.watch(pendingPickProvider.select((m) => m[group.name]));
    final shown = (pending != null && pending.isNotEmpty) ? pending : selected;
    final mode = ref.watch(meowSettingProvider.select((s) => s.latencyMode));
    final members = group.all;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        GroupChipBar(
          groups: groups,
          selected: group.name,
          onSelected: (name) {
            MeowHaptics.select();
            setState(() => _group = name);
          },
        ),
        const SizedBox(height: 10),
        for (final (i, p) in members.indexed)
          Padding(
            padding: EdgeInsets.only(top: i == 0 ? 0 : 3),
            child: M3SegmentSlot(
              index: i,
              count: members.length,
              child: M3ListRow(
                title: p.name,
                titleSize: 14,
                selected: p.name == shown,
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                onTap: () {
                  if (group.type.isComputedSelected || p.name != selected) MeowHaptics.select();
                  unawaited(pickNode(ref, group, p));
                },
                trailing: MsChip(
                  ref.watch(getDelayProvider(proxyName: p.name, testUrl: group.testUrl)),
                  mode: mode,
                  bg: cs.surfaceContainerHighest,
                ),
              ),
            ),
          ),
      ],
    );
  }
}
