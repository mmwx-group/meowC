import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/mesh.dart';
import '../../theme/m3.dart';
import '../../theme/meow_dialog.dart';
import '../../theme/mesh_glyph.dart';
import '../../theme/tokens.dart';

/// 节点格上的「喵窝」小标（喵窝白名单直连，规格 B4）：订阅里的白名单节点（`_mmwx-mesh`）这次经喵窝拨号时画喵窝图标，
/// 点开说明。不是这种节点时什么都不画、不占位。
class MeshViaBadge extends ConsumerWidget {
  const MeshViaBadge(this.nodeName, {super.key, this.size = 14});

  final String nodeName;
  final double size;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final via = ref.watch(meshWhitelistNodesProvider.select((s) => s.contains(nodeName)));
    if (!via) return const SizedBox.shrink();
    final mm = context.mm;
    return Builder(
      builder: (ctx) => Tooltip(
        message: '经喵窝连接',
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => showMeowPopover<void>(ctx, title: '经喵窝连接', width: 280, builder: (_) => const MeshViaNote()),
          child: Padding(
            padding: const EdgeInsets.all(2),
            child: MeshGlyph(size: size, color: mm.accent),
          ),
        ),
      ),
    );
  }
}

/// 「喵窝」小标的说明（气泡内容）。
class MeshViaNote extends StatelessWidget {
  const MeshViaNote({super.key});

  @override
  Widget build(BuildContext context) {
    final cs = context.cs;
    return Text(
      '这是服务器的白名单节点，现在经喵窝连接：不占服务器的 IP 白名单名额，延迟测试同样经喵窝。关掉喵窝后这个节点会从列表里拿掉。',
      style: TextStyle(fontSize: MeowFont.footnote, color: cs.onSurfaceVariant, height: 1.45),
    );
  }
}
