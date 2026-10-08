import 'package:flutter/material.dart';

import '../panel/models.dart';
import '../panel/unlock_catalog.dart';
import 'popover.dart';
import 'tokens.dart';

/// 三态的颜色 / 图标（绿开锁 = 全部解锁，橙开锁 = 部分解锁，灰闭锁 = 一个都没解锁；颜色取主题 token，设计稿 --good / --warn）。
Color unlockLevelColor(UnlockLevel level, MeowTokens mm) => switch (level) {
  UnlockLevel.full => mm.good,
  UnlockLevel.partial => mm.mid,
  UnlockLevel.none => mm.t2,
};

IconData unlockLevelIcon(UnlockLevel level) => level == UnlockLevel.none ? Icons.lock_rounded : Icons.lock_open_rounded;

/// 节点解锁徽标（无底纯色符号，与奖牌同模具）；点按弹分类详情，点其他地方关闭。
class UnlockBadge extends StatelessWidget {
  const UnlockBadge(this.node, {super.key, this.size = 14});

  final NodeUnlocks node;
  final double size;

  @override
  Widget build(BuildContext context) {
    final level = node.level;
    return Builder(
      builder: (ctx) => GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => showAnchoredPopover(ctx, builder: (_) => UnlockDetail(node: node)),
        child: Padding(
          padding: const EdgeInsets.all(2),
          child: Icon(unlockLevelIcon(level), size: size, color: unlockLevelColor(level, context.mm)),
        ),
      ),
    );
  }
}

/// 详情：头行「节点名 · 解锁 n/m」→ 分类选项卡（流媒体 / AI / 其他，带 x/y）→ 逐行服务 + 状态 + 地区 → 页脚说明。
class UnlockDetail extends StatefulWidget {
  const UnlockDetail({super.key, required this.node});
  final NodeUnlocks node;

  /// 记住上次看的分类
  static UnlockCategory lastTab = UnlockCategory.streaming;

  @override
  State<UnlockDetail> createState() => _UnlockDetailState();
}

class _UnlockDetailState extends State<UnlockDetail> {
  late UnlockCategory _tab;
  late final Map<UnlockCategory, List<UnlockEntry>> _groups = widget.node.grouped;

  @override
  void initState() {
    super.initState();
    _tab = _groups[UnlockDetail.lastTab]?.isNotEmpty == true
        ? UnlockDetail.lastTab
        : UnlockCategory.values.firstWhere((c) => _groups[c]!.isNotEmpty, orElse: () => UnlockCategory.streaming);
  }

  @override
  Widget build(BuildContext context) {
    final mm = context.mm;
    final rows = _groups[_tab]!;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(unlockLevelIcon(widget.node.level), size: 14, color: unlockLevelColor(widget.node.level, mm)),
              const SizedBox(width: 6),
              Expanded(
                child: Text(widget.node.name, maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: MeowFont.footnote, fontWeight: FontWeight.w600, color: mm.t1)),
              ),
              const SizedBox(width: 8),
              // 与徽标同口径（信息类不计），三端一致
              Text('${widget.node.level.label} ${widget.node.summary.unlocked}/${widget.node.summary.total}',
                  style: MeowFont.mono(size: MeowFont.caption2, color: mm.t2)),
            ],
          ),
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.all(2),
            decoration: BoxDecoration(color: mm.t1.withValues(alpha: 0.06), borderRadius: BorderRadius.circular(9)),
            // 三段拉成等高：被 FittedBox 缩小的那段，选中底也不比别的段矮（只有 3 段，IntrinsicHeight 开销可忽略）
            child: IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final c in UnlockCategory.values)
                    Expanded(
                      child: GestureDetector(
                        onTap: () => setState(() => UnlockDetail.lastTab = _tab = c),
                        child: Container(
                          padding: const EdgeInsets.symmetric(vertical: 5),
                          decoration: BoxDecoration(
                            color: _tab == c ? mm.elev : Colors.transparent,
                            borderRadius: BorderRadius.circular(7),
                            boxShadow: _tab == c ? [BoxShadow(color: Colors.black.withValues(alpha: 0.08), blurRadius: 3)] : null,
                          ),
                          // 大字时整段缩小而不是折成两行，分段高度不跳
                          child: FittedBox(
                            fit: BoxFit.scaleDown,
                            child: Text(
                              '${c.label} ${UnlockSummary.of(_groups[c]!).unlocked}/${UnlockSummary.of(_groups[c]!).total}',
                              textAlign: TextAlign.center,
                              maxLines: 1,
                              softWrap: false,
                              style: TextStyle(fontSize: MeowFont.caption2, fontWeight: FontWeight.w600, color: _tab == c ? mm.t1 : mm.t2),
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 6),
          Flexible(
            child: rows.isEmpty
                ? Padding(padding: const EdgeInsets.symmetric(vertical: 12), child: Center(child: Text('—', style: TextStyle(color: mm.t3))))
                : ListView(
                    shrinkWrap: true,
                    padding: EdgeInsets.zero,
                    children: [
                      for (final e in rows)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 4),
                          child: Row(
                            children: [
                              Expanded(
                                child: Text(e.meta.label, maxLines: 1, overflow: TextOverflow.ellipsis,
                                    style: TextStyle(fontSize: MeowFont.caption, color: mm.t1)),
                              ),
                              const SizedBox(width: 8),
                              Builder(builder: (_) {
                                final st = unlockStatusMeta(e.status);
                                final color = e.meta.info ? mm.t2 : unlockToneColor(st.tone, mm);
                                return Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    ConstrainedBox(
                                      constraints: const BoxConstraints(maxWidth: 120),
                                      child: Text(e.statusText, maxLines: 1, overflow: TextOverflow.ellipsis,
                                          style: MeowFont.mono(size: MeowFont.caption2, color: color)),
                                    ),
                                    if (!e.meta.info) ...[const SizedBox(width: 4), Icon(unlockToneIcon(st.tone), size: 12, color: color)],
                                  ],
                                );
                              }),
                            ],
                          ),
                        ),
                    ],
                  ),
          ),
          const SizedBox(height: 4),
          Text('结果来自主控，按节点真实出口推断', style: TextStyle(fontSize: 10, color: mm.t3)),
        ],
      ),
    );
  }
}
