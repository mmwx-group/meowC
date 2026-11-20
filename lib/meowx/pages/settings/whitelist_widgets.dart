import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../panel/po0.dart';
import '../../panel/whitelist_common.dart';
import '../../state/po0_reporter.dart';
import '../../theme/m3.dart';
import '../../theme/m3_kit.dart';
import '../../theme/meow_dialog.dart';
import '../../theme/tokens.dart';

// po0 / GGY 加白列表共用的行、备注输入框与 po0 槽位气泡（五端同一份规格：MeowX 仓库 Design/po0-ggy-results.md）。

/// 结果那一行的颜色档：成功 / 提醒（防火墙没开、加白未生效）/ 失败 / 还没报过
enum WhitelistTone { good, warn, bad, none }

WhitelistTone po0Tone(Po0Result? r) => switch (r?.kind) {
  null => WhitelistTone.none,
  Po0ResultKind.success => WhitelistTone.good,
  Po0ResultKind.disabled || Po0ResultKind.notApplied => WhitelistTone.warn,
  _ => WhitelistTone.bad,
};

/// 列表行里结果那一行的文字：`<结果> · <上次上报时间>`；还没报过 =「还没上报」。
String po0ResultLine(Po0Result? r, [DateTime? now]) =>
    r == null ? whitelistNeverReported : '${r.summary} · ${fmtReportTime(r.date, now)}';

/// 每隔一会儿重建一次（「N 分钟前」要跟着走）。
class WhitelistClock extends StatefulWidget {
  const WhitelistClock({super.key, required this.builder});

  final WidgetBuilder builder;

  @override
  State<WhitelistClock> createState() => _WhitelistClockState();
}

class _WhitelistClockState extends State<WhitelistClock> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 30), (_) => setState(() {}));
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.builder(context);
}

/// 一条加白目标：标题（有备注时是备注）/ 副标题（脱敏写法）/ 上一次结果（成功绿、提醒橙、失败红、没报过灰）+ 行尾按钮。
/// [onTap] 不为 null 时点整行（编辑备注）。
class WhitelistItemRow extends StatelessWidget {
  const WhitelistItemRow({
    super.key,
    required this.title,
    this.monoTitle = false,
    this.subtitle,
    required this.result,
    required this.tone,
    this.onTap,
    this.actions = const [],
  });

  final String title;

  /// 标题是地址 / 脱敏 token 时用等宽字（备注、主控给的名字用正文字）
  final bool monoTitle;
  final String? subtitle;
  final String result;
  final WhitelistTone tone;
  final VoidCallback? onTap;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final mm = context.mm;
    final resultColor = switch (tone) {
      WhitelistTone.good => mm.good,
      WhitelistTone.warn => mm.mid,
      WhitelistTone.bad => mm.slow,
      WhitelistTone.none => mm.t2,
    };
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 4, 8),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: monoTitle
                        ? MeowFont.mono(size: MeowFont.subheadline, color: mm.t1)
                        : TextStyle(fontSize: MeowFont.subheadline, fontWeight: FontWeight.w600, color: mm.t1),
                  ),
                  if (subtitle != null)
                    Text(
                      subtitle!,
                      // 「地址 · 脱敏 token」在窄屏上放不下一行：最多两行，别把 token 尾巴截掉
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: MeowFont.mono(size: MeowFont.footnote, color: mm.t2),
                    ),
                  Text(
                    result,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: MeowFont.caption, color: resultColor),
                  ),
                ],
              ),
            ),
            ...actions,
          ],
        ),
      ),
    );
  }
}

/// 「备注（可选）」输入框：最多 [whitelistNoteMax] 个字符。
Widget whitelistNoteField(TextEditingController controller, {bool autofocus = false}) => TextField(
  controller: controller,
  autofocus: autofocus,
  maxLength: whitelistNoteMax,
  decoration: const InputDecoration(labelText: '备注（可选）', hintText: '方便自己认出是哪一个'),
  inputFormatters: [LengthLimitingTextInputFormatter(whitelistNoteMax)],
);

/// 改备注的对话框：返回规范化后的备注（空串 = 清除备注）；取消返回 null。
Future<String?> editWhitelistNote(BuildContext context, {required String subject, required String initial}) {
  final c = TextEditingController(text: initial);
  return showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      // 横屏弹键盘时高度不够：整体可滚，别把输入框压到按钮上
      scrollable: true,
      title: const Text('编辑备注'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            subject,
            style: MeowFont.mono(size: MeowFont.footnote, color: ctx.mm.t2),
          ),
          const SizedBox(height: 8),
          whitelistNoteField(c, autofocus: true),
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text('取消')),
        FilledButton(onPressed: () => Navigator.of(ctx).pop(normalizeWhitelistNote(c.text)), child: const Text('保存')),
      ],
    ),
  );
}

/// 行尾的「查看槽位」按钮：点开锚定在按钮上的气泡，看这台 po0 当前的白名单槽位（只读）。
class Po0SlotButton extends StatelessWidget {
  const Po0SlotButton({super.key, required this.url, required this.title});

  /// 这台 po0 的上报地址（结论的键，不显示）
  final String url;

  /// 气泡标题：主控给的名字 / 备注 / 地址
  final String title;

  @override
  Widget build(BuildContext context) => Builder(
    builder: (anchor) => IconButton(
      tooltip: '查看槽位',
      icon: Icon(Icons.shield_outlined, size: 20, color: context.mm.t2),
      onPressed: () => showPo0SlotPopover(anchor, url: url, title: title),
    ),
  );
}

/// po0 槽位气泡（规格 §2）：概况、名单逐行（槽位 / 本机）、空位、本机出口与槽位、上次上报；没有 200 结果时只写那句结果与时间。
Future<void> showPo0SlotPopover(BuildContext anchor, {required String url, required String title}) =>
    showMeowPopover<void>(
      anchor,
      title: title,
      builder: (ctx) =>
          Consumer(builder: (ctx, ref, _) => Po0SlotSheet(result: ref.watch(po0ResultsProvider.select((m) => m[url])))),
    );

/// 气泡的内容（单独成一个组件，方便测试与截图）。
class Po0SlotSheet extends StatelessWidget {
  const Po0SlotSheet({super.key, required this.result, this.now});

  final Po0Result? result;
  final DateTime? now;

  @override
  Widget build(BuildContext context) {
    final cs = context.cs;
    final mm = context.mm;
    final r = result;
    final small = TextStyle(fontSize: MeowFont.footnote, color: cs.onSurfaceVariant, height: 1.45);
    Widget line(String text, {Color? color, EdgeInsets pad = const EdgeInsets.fromLTRB(8, 0, 8, 2)}) => Padding(
      padding: pad,
      child: Text(text, style: color == null ? small : small.copyWith(color: color)),
    );

    if (r == null || !r.hasWhitelist) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          line(
            r == null ? whitelistNeverReported : r.summary,
            color: r == null ? null : mm.slow,
            pad: const EdgeInsets.fromLTRB(8, 4, 8, 4),
          ),
          if (r != null) line('上次上报 ${fmtReportTime(r.date, now)}'),
        ],
      );
    }

    final self = r.selfIndex;
    // 老版 po0 可能不回名单：不画名单、也不补空位（规格 §1.1「缺字段时信 200」）
    final entries = r.entries;
    final free = entries == null ? 0 : (r.limit ?? 0) - entries.length;
    final rowColor = meowDialogRowColor(cs);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        line(r.overview, color: r.enabled == true ? null : mm.mid, pad: const EdgeInsets.fromLTRB(8, 0, 8, 10)),
        if (entries != null && entries.length + free > 0) ...[
          M3SegmentedList(
            children: [
              for (final (i, e) in entries.indexed)
                _SlotRow(ip: e.ip.isEmpty ? '—' : e.ip, slot: e.slot, self: i == self, color: rowColor),
              for (var i = 0; i < free; i++) _SlotRow(ip: '空位', empty: true, color: rowColor),
            ],
          ),
          const SizedBox(height: 10),
        ],
        if (r.currentIp != null) line('本机出口 ${r.currentIp}'),
        line(r.slot == null ? '本机未固定槽位，名单满时最久没上报的会被挤掉' : '本机使用槽位 ${r.slot}'),
        line('上次上报 ${fmtReportTime(r.date, now)}'),
      ],
    );
  }
}

class _SlotRow extends StatelessWidget {
  const _SlotRow({required this.ip, this.slot, this.self = false, this.empty = false, required this.color});

  final String ip;
  final int? slot;
  final bool self, empty;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final cs = context.cs;
    final mm = context.mm;
    final pos = M3SegmentSlot.maybeOf(context);
    final radius = pos == null
        ? BorderRadius.circular(16)
        : MeowShape.segment(pos.index, pos.count, outer: 16, inner: 4);
    final fg = empty ? mm.t2.withValues(alpha: 0.7) : (self ? cs.primary : cs.onSurface);
    return Container(
      decoration: BoxDecoration(color: color, borderRadius: radius),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      child: Row(
        children: [
          Expanded(
            child: Text(
              ip,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: empty
                  ? TextStyle(fontSize: MeowFont.footnote, color: fg)
                  : MeowFont.mono(size: MeowFont.footnote, color: fg, weight: self ? FontWeight.w800 : FontWeight.w500),
            ),
          ),
          if (slot != null) ...[
            Icon(Icons.push_pin_rounded, size: 14, color: mm.t2),
            const SizedBox(width: 2),
            Text(
              '槽位 $slot',
              style: TextStyle(fontSize: MeowFont.caption, color: mm.t2),
            ),
          ],
          if (self) ...[
            const SizedBox(width: 8),
            Text(
              '本机',
              style: TextStyle(fontSize: MeowFont.caption, fontWeight: FontWeight.w800, color: cs.primary),
            ),
          ],
        ],
      ),
    );
  }
}
