import 'package:flutter/material.dart';

import '../../../theme/m3.dart';
import '../../../theme/m3_kit.dart';
import '../../../theme/tokens.dart';

/// 「高级 › 工具」几页（脚本 / 资源 / 请求记录）共用的小元件。

/// 空状态卡片：图标 + 一句话，放在卡片底上（列表型二级页里没有内容时）。
class ToolsEmptyCard extends StatelessWidget {
  const ToolsEmptyCard({super.key, required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final cs = context.cs;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
      decoration: BoxDecoration(color: cs.card, borderRadius: BorderRadius.circular(M3ListRow.outer)),
      child: Column(
        children: [
          Icon(icon, size: 40, color: cs.outline),
          const SizedBox(height: 10),
          Text(
            text,
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: MeowFont.subheadline, color: cs.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}

/// 整页空状态（懒加载列表那块地方没东西时）：居中的图标 + 一句话。
class ToolsEmptyState extends StatelessWidget {
  const ToolsEmptyState({super.key, required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final cs = context.cs;
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 40, color: cs.outline),
            const SizedBox(height: 10),
            Text(
              text,
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: MeowFont.subheadline, color: cs.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }
}

/// [M3IconButton] 的忙碌态：[busy] 时同样大小的圆底里转圈、不能点。
class ToolsBusyIconButton extends StatelessWidget {
  const ToolsBusyIconButton({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.busy,
    required this.onPressed,
    this.size = 48,
    this.tonal = false,
  });

  final IconData icon;
  final String tooltip;
  final bool busy;
  final VoidCallback? onPressed;
  final double size;
  final bool tonal;

  @override
  Widget build(BuildContext context) {
    if (!busy) return M3IconButton(icon: icon, tooltip: tooltip, size: size, tonal: tonal, onPressed: onPressed);
    final cs = context.cs;
    final (bg, fg) = tonal
        ? (cs.secondaryContainer, cs.onSecondaryContainer)
        : (cs.surfaceContainerHighest, cs.onSurface);
    return Tooltip(
      message: '$tooltip中',
      child: Container(
        width: size,
        height: size,
        alignment: Alignment.center,
        decoration: BoxDecoration(color: bg, shape: BoxShape.circle),
        child: SizedBox.square(
          dimension: size * 0.42,
          child: CircularProgressIndicator(strokeWidth: 2.4, color: fg),
        ),
      ),
    );
  }
}
