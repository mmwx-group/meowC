import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../panel/realtime.dart';
import '../../state/realtime_sync.dart';
import '../../theme/popover.dart';
import '../../theme/tokens.dart';

/// 节点格上的「主控指定入口」小标（入口即时切换，规格 §6 的诊断显示）：这个节点的 server 现在被主控指定成某几个入口 IP 时
/// 画一个小图标，点开（桌面上悬停也行）看「主控指定入口 IP · 切换时间」。没有覆盖时什么都不画、不占位。
class EntryOverrideBadge extends ConsumerWidget {
  const EntryOverrideBadge(this.nodeName, {super.key, this.size = 14});

  final String nodeName;
  final double size;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final entry = ref.watch(nodeEntryOverrideProvider(nodeName));
    if (entry == null) return const SizedBox.shrink();
    final mm = context.mm;
    final label = entryOverrideLabel(entry);
    return Builder(
      builder: (ctx) => Tooltip(
        message: label,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => showAnchoredPopover(ctx, width: 260, builder: (_) => _EntryOverrideDetail(entry: entry)),
          child: Padding(
            padding: const EdgeInsets.all(2),
            child: Icon(Icons.alt_route_rounded, size: size, color: mm.accent),
          ),
        ),
      ),
    );
  }
}

class _EntryOverrideDetail extends StatelessWidget {
  const _EntryOverrideDetail({required this.entry});

  final EntryOverride entry;

  @override
  Widget build(BuildContext context) {
    final mm = context.mm;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      child: Text(
        entryOverrideLabel(entry),
        style: TextStyle(fontSize: MeowFont.footnote, color: mm.t1, height: 1.35),
      ),
    );
  }
}
