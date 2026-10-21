import 'package:bett_box/common/navigator.dart';
import 'package:flutter/material.dart';

import '../../state/format.dart';
import '../../state/speed_test.dart';
import '../../theme/tokens.dart';
import '../../theme/widgets.dart';
import '../me/me_kit.dart';

/// 测速记录（测速页右上角「记录」进来；与 iOS 的 SpeedTestHistoryView 同一套）：樱粉汇总卡 + 按节点筛选 + 按日列表，
/// 左滑删除、右上角清空。点一条进详情。
class SpeedTestHistoryPage extends StatefulWidget {
  const SpeedTestHistoryPage({super.key, required this.controller});
  final SpeedTestController controller;

  @override
  State<SpeedTestHistoryPage> createState() => _SpeedTestHistoryPageState();
}

class _SpeedTestHistoryPageState extends State<SpeedTestHistoryPage> {
  /// 当前筛选的出站；null = 全部
  String? _filter;

  SpeedTestHistory get history => widget.controller.history;

  Future<void> _open(SpeedTestRecord record) async {
    final again = await BaseNavigator.push<bool>(
      context,
      SpeedTestRecordPage(controller: widget.controller, id: record.id),
    );
    // 「用同样设置再测一次」：详情已退出，这里再退回测速页
    if (again == true && mounted) Navigator.of(context).pop();
  }

  Future<void> _confirmClear() async {
    final mm = context.mm;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('清空全部 ${history.records.length} 条测速记录？'),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('取消')),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text('清空', style: TextStyle(color: mm.slow)),
          ),
        ],
      ),
    );
    if (ok == true) history.clear();
  }

  @override
  Widget build(BuildContext context) {
    final mm = context.mm;
    return ListenableBuilder(
      listenable: history,
      builder: (context, _) {
        final all = history.records;
        final options = SpeedTestHistory.filterOptions(all);
        // 筛选的节点记录被删光了就回到全部
        final current = options.contains(_filter) ? _filter : null;
        final rows = SpeedTestHistory.filtered(all, current);
        final fastest = SpeedTestHistory.fastest(all);
        return MeSubPage.list(
          title: '测速记录',
          actions: [if (all.isNotEmpty) MePill(label: '清空', onTap: _confirmClear)],
          children: all.isEmpty
              ? [
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 60),
                    child: Text(
                      '还没有测速记录，测完一次会出现在这里',
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 14, color: mm.t2),
                    ),
                  ),
                ]
              : [
                  SpeedTestSummaryCard(records: rows, filter: current),
                  _FilterChips(options: options, selection: current, onChanged: (v) => setState(() => _filter = v)),
                  for (final (title, group) in SpeedTestHistory.groupedByDay(rows))
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Padding(
                          padding: const EdgeInsets.fromLTRB(4, 0, 4, 6),
                          child: Row(
                            children: [
                              Expanded(child: Text(title, style: _groupStyle(mm))),
                              Text('${group.length} 次', style: _groupStyle(mm)),
                            ],
                          ),
                        ),
                        for (final (i, r) in group.indexed) ...[
                          if (i > 0) const SizedBox(height: 8),
                          Dismissible(
                            key: ValueKey(r.id),
                            direction: DismissDirection.endToStart,
                            background: _deleteBackground(mm),
                            onDismissed: (_) => history.delete(r.id),
                            child: SpeedTestRecordRow(record: r, isFastest: r.id == fastest, onTap: () => _open(r)),
                          ),
                        ],
                      ],
                    ),
                  Text(
                    '只存本机，最多保留 ${SpeedTestHistory.limit} 条 · 左滑删除单条',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 12, color: mm.t2),
                  ),
                ],
        );
      },
    );
  }

  TextStyle _groupStyle(MeowTokens mm) => TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: mm.t2);

  Widget _deleteBackground(MeowTokens mm) => Container(
    alignment: Alignment.centerRight,
    padding: const EdgeInsets.only(right: 20),
    decoration: BoxDecoration(color: mm.slow, borderRadius: BorderRadius.circular(18)),
    child: const Text('删除', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: Colors.white)),
  );
}

/// 一条记录的详情：曲线、参数；「用同样设置再测一次」预填后回测速页（pop 时带 true）。
class SpeedTestRecordPage extends StatelessWidget {
  const SpeedTestRecordPage({super.key, required this.controller, required this.id});
  final SpeedTestController controller;
  final String id;

  @override
  Widget build(BuildContext context) {
    final mm = context.mm;
    return ListenableBuilder(
      listenable: Listenable.merge([controller, controller.history]),
      builder: (context, _) {
        final record = controller.history.byId(id);
        final running = controller.isRunning;
        return MeSubPage.list(
          title: '记录详情',
          children: record == null
              ? const []
              : [
                  SpeedTestRecordDetail(record: record),
                  Row(
                    children: [
                      Expanded(
                        child: AnimatedOpacity(
                          duration: const Duration(milliseconds: 150),
                          opacity: running ? 0.45 : 1,
                          child: _pillButton(
                            color: mm.t1,
                            label: '用同样设置再测一次',
                            textColor: mm.bg,
                            onTap: running
                                ? null
                                : () {
                                    controller.prefill(record);
                                    Navigator.of(context).pop(true);
                                  },
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      SizedBox(
                        width: 96,
                        child: _pillButton(
                          color: mm.elev,
                          label: '删除',
                          textColor: mm.slow,
                          onTap: () {
                            Navigator.of(context).pop();
                            controller.history.delete(record.id);
                          },
                        ),
                      ),
                    ],
                  ),
                ],
        );
      },
    );
  }

  Widget _pillButton({required Color color, required String label, required Color textColor, VoidCallback? onTap}) =>
      Material(
        color: color,
        shape: const StadiumBorder(),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: SizedBox(
            height: 46,
            child: Center(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: textColor),
              ),
            ),
          ),
        ),
      );
}

/// 汇总卡（樱粉底）：最近 30 天次数、三项最好成绩（各带节点名）、下载速率走势。
class SpeedTestSummaryCard extends StatelessWidget {
  const SpeedTestSummaryCard({super.key, required this.records, this.filter});
  final List<SpeedTestRecord> records;

  /// 当前筛选的出站；null = 全部
  final String? filter;

  @override
  Widget build(BuildContext context) {
    final mm = context.mm;
    final s = SpeedTestHistory.summary(records);
    final head = TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: mm.t1.withValues(alpha: 0.75));
    final foot = TextStyle(fontSize: 11, color: mm.t2);
    final trend = s.trend;
    return Container(
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 12),
      decoration: BoxDecoration(color: mm.hero, borderRadius: BorderRadius.circular(24)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Text('最近 30 天 · ${s.count} 次', style: head),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  filter == null ? '全部节点' : speedTestDisplayName(filter!),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.end,
                  style: head,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              _stat(mm, '最快下载', s.fastestDownload == null ? null : fmtRecordMbps(s.fastestDownload!.downloadMbps),
                  'Mbps', mm.down, s.fastestDownload),
              const SizedBox(width: 8),
              _stat(mm, '最快上传', s.fastestUpload == null ? null : fmtRecordMbps(s.fastestUpload!.uploadMbps), 'Mbps',
                  mm.accent, s.fastestUpload),
              const SizedBox(width: 8),
              _stat(mm, '最低延迟', s.lowestLatency?.latencyMs?.toString(), 'ms', mm.t1, s.lowestLatency),
            ],
          ),
          if (trend.length > 1) ...[
            const SizedBox(height: 10),
            SizedBox(
              height: 64,
              child: CustomPaint(painter: _TrendPainter(trend, mm.down, mm.elev), size: Size.infinite),
            ),
            const SizedBox(height: 6),
            Row(
              children: [
                Expanded(child: Text('下载速率走势（按时间）', style: foot)),
                Text(
                  '${fmtRecordMbps(trend.reduce((a, b) => a < b ? a : b))}–'
                  '${fmtRecordMbps(trend.reduce((a, b) => a > b ? a : b))} Mbps',
                  style: foot,
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _stat(MeowTokens mm, String title, String? value, String unit, Color tint, SpeedTestRecord? record) =>
      Expanded(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
          decoration: BoxDecoration(color: mm.elev.withValues(alpha: 0.78), borderRadius: BorderRadius.circular(14)),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: mm.t2)),
              const SizedBox(height: 2),
              FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.baseline,
                  textBaseline: TextBaseline.alphabetic,
                  children: [
                    Text(value ?? '–', style: _numStyle(19, tint)),
                    if (value != null) ...[
                      const SizedBox(width: 2),
                      Text(unit, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: mm.t2)),
                    ],
                  ],
                ),
              ),
              const SizedBox(height: 2),
              Text(
                record?.displayName ?? ' ',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 11, color: mm.t2),
              ),
            ],
          ),
        ),
      );
}

/// 大数字：圆体、等宽数字
TextStyle _numStyle(double size, Color color) => TextStyle(
  fontSize: size,
  fontWeight: FontWeight.w800,
  color: color,
  fontFamilyFallback: meowRounded,
  fontFeatures: const [FontFeature.tabularFigures()],
);

/// 筛选胶囊：全部 / 直连 / 各节点（横向滚动）；选中 = 墨色实底 + 奶白字。
class _FilterChips extends StatelessWidget {
  const _FilterChips({required this.options, required this.selection, required this.onChanged});
  final List<String> options;
  final String? selection;
  final ValueChanged<String?> onChanged;

  @override
  Widget build(BuildContext context) => SingleChildScrollView(
    scrollDirection: Axis.horizontal,
    child: Row(
      children: [
        _chip(context, null, '全部'),
        for (final o in options) ...[const SizedBox(width: 8), _chip(context, o, speedTestDisplayName(o))],
      ],
    ),
  );

  Widget _chip(BuildContext context, String? value, String title) {
    final mm = context.mm;
    final on = selection == value;
    return GestureDetector(
      onTap: () => onChanged(value),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 7),
        decoration: ShapeDecoration(color: on ? mm.t1 : mm.elev, shape: const StadiumBorder()),
        child: Text(
          title,
          maxLines: 1,
          style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: on ? mm.bg : mm.t2),
        ),
      ),
    );
  }
}

/// 记录名：直连 = 浅粉底「直连」小标签 +「本机网络」；其余是节点名。
class SpeedTestRecordName extends StatelessWidget {
  const SpeedTestRecordName({super.key, required this.outbound, this.fontSize = 15});
  final String outbound;
  final double fontSize;

  @override
  Widget build(BuildContext context) {
    final mm = context.mm;
    final style = TextStyle(fontSize: fontSize, fontWeight: FontWeight.w700, color: mm.t1);
    if (outbound != kSpeedTestDirect) {
      return Text(outbound, maxLines: 1, overflow: TextOverflow.ellipsis, style: style);
    }
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          decoration: BoxDecoration(color: mm.soft, borderRadius: BorderRadius.circular(6)),
          child: Text(
            '直连',
            style: TextStyle(fontSize: fontSize * 0.66, fontWeight: FontWeight.w800, color: mm.accent),
          ),
        ),
        const SizedBox(width: 6),
        Flexible(child: Text('本机网络', maxLines: 1, overflow: TextOverflow.ellipsis, style: style)),
      ],
    );
  }
}

/// 列表里的一条（白卡 18 圆角）：名字 + 测速源 · 线程 · 时间 + 迷你下载曲线 + 下载 / 上传 / 延迟；
/// 失败的写原因（红字）；全部记录里下载最快那条右上角「最快」角标。
class SpeedTestRecordRow extends StatelessWidget {
  const SpeedTestRecordRow({super.key, required this.record, this.isFastest = false, this.onTap});
  final SpeedTestRecord record;
  final bool isFastest;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final mm = context.mm;
    final r = record;
    final card = Material(
      color: mm.elev,
      borderRadius: BorderRadius.circular(18),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SpeedTestRecordName(outbound: r.outbound),
                    const SizedBox(height: 3),
                    Text(
                      '${r.source.title} · ${r.threadsTitle} · ${r.timeTitle}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 12, color: mm.t2),
                    ),
                  ],
                ),
              ),
              if (r.downloadSamples.length > 1) ...[
                const SizedBox(width: 12),
                SizedBox(
                  width: 64,
                  height: 30,
                  child: CustomPaint(painter: _SparklinePainter(r.downloadSamples, mm.down)),
                ),
              ],
              const SizedBox(width: 12),
              ConstrainedBox(
                constraints: const BoxConstraints(minWidth: 78, maxWidth: 120),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: r.error != null
                      ? [
                          Text('失败', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w800, color: mm.slow)),
                          Text(
                            r.error!,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontSize: 11, color: mm.t2),
                          ),
                        ]
                      : [
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.baseline,
                            textBaseline: TextBaseline.alphabetic,
                            children: [
                              Text(fmtRecordMbps(r.downloadMbps), style: _numStyle(17, mm.down)),
                              const SizedBox(width: 1),
                              Text('Mbps', style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: mm.t2)),
                            ],
                          ),
                          if (r.uploadMbps != null)
                            Text(
                              '↑ ${fmtRecordMbps(r.uploadMbps)}',
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w700,
                                color: mm.accent,
                                fontFeatures: const [FontFeature.tabularFigures()],
                              ),
                            ),
                          if (r.latencyMs != null)
                            Text('${r.latencyMs} ms', style: TextStyle(fontSize: 11, color: mm.t2)),
                        ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
    if (!isFastest) return card;
    return Stack(
      clipBehavior: Clip.none,
      children: [
        card,
        Positioned(
          top: -6,
          right: 12,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
            decoration: ShapeDecoration(color: mm.t1, shape: const StadiumBorder()),
            child: Text('最快', style: TextStyle(fontSize: 10, fontWeight: FontWeight.w800, color: mm.bg)),
          ),
        ),
      ],
    );
  }
}

/// 出口两行（同 iOS）：「AS2516」小标签 + 运营商（去掉公司后缀），下面一行「203.0.113.8 · JP」；还在查时是「… 查询出口…」，
/// 第二行留空占位（查到时高度不变）。以前「运营商 · IP」挤在一行，运营商名只剩一半。测速页节点行与记录详情共用。
class SpeedTestExitLine extends StatelessWidget {
  const SpeedTestExitLine({super.key, required this.exit, this.pending = false, this.center = false});
  final SpeedTestExit? exit;
  final bool pending;

  /// 居中（记录详情的标题下面）
  final bool center;

  /// 有东西可显示：查到了，或者还在查
  static bool visible(SpeedTestExit? exit, {bool pending = false}) => exit != null || pending;

  @override
  Widget build(BuildContext context) {
    final mm = context.mm;
    final e = exit;
    if (!visible(e, pending: pending)) return const SizedBox.shrink();
    final tag = e == null ? '…' : e.asnTag;
    final org = e == null ? '查询出口…' : e.shortOrg;
    return Column(
      crossAxisAlignment: center ? CrossAxisAlignment.center : CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (tag != null || org != null)
          Row(
            mainAxisSize: center ? MainAxisSize.min : MainAxisSize.max,
            children: [
              if (tag != null) ...[
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                  decoration: BoxDecoration(color: mm.down.withValues(alpha: 0.14), borderRadius: BorderRadius.circular(6)),
                  child: Text(tag, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w800, color: mm.down)),
                ),
                if (org != null) const SizedBox(width: 6),
              ],
              if (org != null)
                Flexible(
                  child: Text(org, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12, color: mm.t2)),
                ),
            ],
          ),
        const SizedBox(height: 2),
        Text(
          e?.ipLine ?? ' ',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: MeowFont.mono(size: MeowFont.caption2, color: mm.t2),
        ),
      ],
    );
  }
}

/// 详情：标题、平均 / 峰值大字、速率曲线、参数表（操作按钮在 [SpeedTestRecordPage] 里）。
class SpeedTestRecordDetail extends StatelessWidget {
  const SpeedTestRecordDetail({super.key, required this.record});
  final SpeedTestRecord record;

  @override
  Widget build(BuildContext context) {
    final mm = context.mm;
    final r = record;
    final hasChart = r.downloadSamples.length > 1 || r.uploadSamples.length > 1;
    final small = TextStyle(fontSize: 12, color: mm.t2);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Column(
            children: [
              Text(
                r.isDirect ? '直连 · 本机网络' : r.outbound,
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800, color: mm.t1),
              ),
              const SizedBox(height: 3),
              Text(
                '${r.dayTitle} ${r.timeTitle} · ${r.source.title} · ${r.threadsTitle}',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 13, color: mm.t2),
              ),
              if (r.exit != null) ...[
                const SizedBox(height: 6),
                SpeedTestExitLine(exit: r.exit, center: true),
              ],
            ],
          ),
        ),
        const SizedBox(height: 10),
        if (r.error != null)
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(color: mm.elev, borderRadius: BorderRadius.circular(18)),
            child: Text(
              '测速失败：${r.error}',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: mm.slow),
            ),
          )
        else ...[
          Row(
            children: [
              _big(mm, '下载', mm.down, r.downloadMbps, r.downloadPeakMbps),
              const SizedBox(width: 8),
              _big(mm, '上传', mm.accent, r.uploadMbps, r.uploadPeakMbps),
            ],
          ),
          if (hasChart) ...[
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.all(18),
              decoration: BoxDecoration(color: mm.elev, borderRadius: BorderRadius.circular(24)),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text('速率曲线', style: small.copyWith(fontWeight: FontWeight.w600)),
                  const SizedBox(height: 8),
                  SizedBox(
                    height: 150,
                    child: CustomPaint(
                      painter: _RecordChartPainter(r.downloadSamples, r.uploadSamples, mm.down, mm.accent, mm.line),
                      size: Size.infinite,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      _legend('下载', mm.down, small),
                      const SizedBox(width: 14),
                      _legend('上传', mm.accent, small),
                      const Spacer(),
                      Text(
                        '最高 ${fmtRecordMbps(_peak([...r.downloadSamples, ...r.uploadSamples]))} Mbps',
                        style: small,
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ],
        const SizedBox(height: 10),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 6),
          decoration: BoxDecoration(color: mm.elev, borderRadius: BorderRadius.circular(24)),
          child: Column(
            children: [
              _kv(mm, '延迟', r.latencyMs == null ? '–' : '${r.latencyMs} ms'),
              _kv(mm, '经由', r.isDirect ? '直连（DIRECT）' : (r.via ?? r.outbound)),
              _kv(mm, '测速服务器', r.server ?? '–'),
              _kv(mm, '测速源 · 线程', '${r.source.title} · ${r.threadsTitle}'),
              _kv(mm, '用量', fmtSize(r.bytesUsed), last: true),
            ],
          ),
        ),
      ],
    );
  }

  static double _peak(List<double> values) => values.isEmpty ? 0 : values.reduce((a, b) => a > b ? a : b);

  Widget _big(MeowTokens mm, String title, Color tint, double? value, double? peak) => Expanded(
    child: Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(color: mm.elev, borderRadius: BorderRadius.circular(18)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _legend(title, tint, TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: mm.t2)),
          const SizedBox(height: 4),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                Text(fmtRecordMbps(value), style: _numStyle(30, tint)),
                if (value != null) ...[
                  const SizedBox(width: 3),
                  Text('Mbps', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: mm.t2)),
                ],
              ],
            ),
          ),
          const SizedBox(height: 4),
          Text(
            peak != null ? '峰值 ${fmtRecordMbps(peak)} Mbps' : (value == null ? '未测' : ' '),
            style: TextStyle(fontSize: 12, color: mm.t2),
          ),
        ],
      ),
    ),
  );

  Widget _legend(String title, Color tint, TextStyle style) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Container(width: 8, height: 8, decoration: BoxDecoration(color: tint, shape: BoxShape.circle)),
      const SizedBox(width: 5),
      Text(title, style: style),
    ],
  );

  Widget _kv(MeowTokens mm, String key, String value, {bool last = false}) => Container(
    padding: const EdgeInsets.symmetric(vertical: 11),
    decoration: last ? null : BoxDecoration(border: Border(bottom: BorderSide(color: mm.line))),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(key, style: TextStyle(fontSize: 14, color: mm.t2)),
        const SizedBox(width: 12),
        Expanded(
          child: Text(
            value,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.end,
            style: TextStyle(fontSize: 14, color: mm.t1, fontFeatures: const [FontFeature.tabularFigures()]),
          ),
        ),
      ],
    ),
  );
}

// —— 几张小图：自己画 Path，配色同测速页（下载紫 mm.down、上传玫红 mm.accent）——

/// 列表行里的迷你下载曲线
class _SparklinePainter extends CustomPainter {
  _SparklinePainter(this.samples, this.color);
  final List<double> samples;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    if (samples.length < 2) return;
    final peak = samples.reduce((a, b) => a > b ? a : b).clamp(0.001, double.infinity);
    final path = Path();
    for (final (i, v) in samples.indexed) {
      final x = size.width * i / (samples.length - 1);
      final y = size.height - 2 - (size.height - 5) * (v / peak);
      i == 0 ? path.moveTo(x, y) : path.lineTo(x, y);
    }
    canvas.drawPath(path, _stroke(color, 1.6));
  }

  @override
  bool shouldRepaint(_SparklinePainter old) => !identical(old.samples, samples) || old.color != color;
}

/// 汇总卡里的下载速率走势：每次测速一个点，按时间先后（填充 + 折线 + 空心点）
class _TrendPainter extends CustomPainter {
  _TrendPainter(this.values, this.color, this.dotFill);
  final List<double> values;
  final Color color, dotFill;

  @override
  void paint(Canvas canvas, Size size) {
    if (values.length < 2) return;
    final peak = (values.reduce((a, b) => a > b ? a : b) * 1.1).clamp(0.001, double.infinity);
    final points = [
      for (final (i, v) in values.indexed)
        Offset(size.width * i / (values.length - 1), size.height - 4 - (size.height - 10) * (v / peak)),
    ];
    final line = Path()..addPolygon(points, false);
    // 填充：左下角 → 各点 → 右下角
    final fill = Path()..moveTo(0, size.height);
    for (final p in points) {
      fill.lineTo(p.dx, p.dy);
    }
    fill
      ..lineTo(size.width, size.height)
      ..close();
    canvas.drawPath(fill, Paint()..color = color.withValues(alpha: 0.14));
    canvas.drawPath(line, _stroke(color, 2));
    final dot = Paint()..color = dotFill;
    final ring = _stroke(color, 1.8);
    for (final p in points) {
      canvas.drawCircle(p, 3, dot);
      canvas.drawCircle(p, 3, ring);
    }
  }

  @override
  bool shouldRepaint(_TrendPainter old) =>
      !identical(old.values, values) || old.color != color || old.dotFill != dotFill;
}

/// 详情页的速率曲线：下载、上传两条叠在一张图上，纵轴共用；底线实线、中线虚线
class _RecordChartPainter extends CustomPainter {
  _RecordChartPainter(this.download, this.upload, this.downColor, this.upColor, this.lineColor);
  final List<double> download, upload;
  final Color downColor, upColor, lineColor;

  @override
  void paint(Canvas canvas, Size size) {
    final grid = Paint()
      ..color = lineColor
      ..strokeWidth = 1;
    canvas.drawLine(Offset(0, size.height - 0.5), Offset(size.width, size.height - 0.5), grid);
    final mid = size.height / 2;
    for (double x = 0; x < size.width; x += 7) {
      canvas.drawLine(Offset(x, mid), Offset((x + 3).clamp(0, size.width), mid), grid);
    }
    final count = [download.length, upload.length, 2].reduce((a, b) => a > b ? a : b);
    final all = [...download, ...upload];
    final peak = ((all.isEmpty ? 1.0 : all.reduce((a, b) => a > b ? a : b)) * 1.1).clamp(0.001, double.infinity);
    void line(List<double> values, Color color) {
      if (values.length < 2) return;
      final path = Path();
      for (final (i, v) in values.indexed) {
        final x = size.width * i / (count - 1);
        final y = size.height - 2 - (size.height - 6) * (v / peak);
        i == 0 ? path.moveTo(x, y) : path.lineTo(x, y);
      }
      canvas.drawPath(path, _stroke(color, 2));
    }

    line(download, downColor);
    line(upload, upColor);
  }

  @override
  bool shouldRepaint(_RecordChartPainter old) =>
      !identical(old.download, download) ||
      !identical(old.upload, upload) ||
      old.downColor != downColor ||
      old.upColor != upColor ||
      old.lineColor != lineColor;
}

Paint _stroke(Color color, double width) => Paint()
  ..color = color
  ..style = PaintingStyle.stroke
  ..strokeWidth = width
  ..strokeCap = StrokeCap.round
  ..strokeJoin = StrokeJoin.round;
