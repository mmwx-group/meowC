import 'dart:math' as math;

import 'package:bett_box/common/common.dart';
import 'package:flutter/material.dart';

import '../../state/speed_test.dart';
import '../../theme/m3.dart';
import '../../theme/m3_kit.dart';
import '../../theme/tokens.dart';
import '../speedtest/speed_test_history_page.dart';
import '../speedtest/speed_test_page.dart';

/// 宽屏首页的「网络测速」卡（同 iOS iPad / Duo 首页的 HomeSpeedTestCard）：测速记录最新一条的三个数 + 一排逐秒速率柱 +
/// 「来源 · 线程 · 时间」，「开始测速」打开测速页并直接开测，「测速记录」打开记录列表。没测过显示空状态。
class HomeSpeedTestCard extends StatefulWidget {
  const HomeSpeedTestCard({super.key, this.controller});

  /// 测试里换成假的；缺省用全局那一份
  final SpeedTestController? controller;

  @override
  State<HomeSpeedTestCard> createState() => _HomeSpeedTestCardState();
}

class _HomeSpeedTestCardState extends State<HomeSpeedTestCard> {
  late final SpeedTestController c = widget.controller ?? speedTestController;

  @override
  void initState() {
    super.initState();
    c.history.load();   // 没进过测速页时记录还没读盘
  }

  /// 采样并成至多 [count] 根柱子，按最高那根归一（同 iOS SpeedTestCardSummary.bars）
  static List<double> _bars(List<double> samples, {int count = 20}) {
    if (samples.isEmpty) return const [];
    final n = math.min(count, samples.length);
    final out = <double>[];
    for (var i = 0; i < n; i++) {
      final from = (i * samples.length / n).floor(), to = math.max(from + 1, ((i + 1) * samples.length / n).floor());
      final seg = samples.sublist(from, math.min(to, samples.length));
      out.add(seg.fold(0.0, (a, b) => a + math.max(0, b)) / seg.length);
    }
    final peak = out.fold(0.0, math.max);
    return peak <= 0 ? [for (final _ in out) 0.0] : [for (final v in out) v / peak];
  }

  static String _when(DateTime d) {
    final now = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    final time = '${two(d.hour)}:${two(d.minute)}';
    final day = DateTime(d.year, d.month, d.day), today = DateTime(now.year, now.month, now.day);
    final diff = today.difference(day).inDays;
    if (diff == 0) return '今天 $time';
    if (diff == 1) return '昨天 $time';
    return '${d.month}月${d.day}日 $time';
  }

  @override
  Widget build(BuildContext context) {
    final cs = context.cs;
    return ListenableBuilder(
      listenable: c.history,
      builder: (context, _) {
        final r = c.history.records.firstOrNull;
        Widget stat(String label, String value, String unit, Color color) => Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label, style: TextStyle(fontSize: MeowFont.caption, fontWeight: FontWeight.w600, color: cs.onSurfaceVariant)),
              Row(
                crossAxisAlignment: CrossAxisAlignment.baseline,
                textBaseline: TextBaseline.alphabetic,
                children: [
                  Flexible(
                    child: Text(
                      value,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800, color: color, fontFeatures: const [FontFeature.tabularFigures()]),
                    ),
                  ),
                  const SizedBox(width: 2),
                  Text(unit, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: cs.onSurfaceVariant)),
                ],
              ),
            ],
          ),
        );
        final useUpload = r != null && r.downloadSamples.isEmpty && r.uploadSamples.isNotEmpty;
        final bars = r == null ? const <double>[] : _bars(useUpload ? r.uploadSamples : r.downloadSamples);
        return M3Card(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Icon(Icons.speed_rounded, size: 20, color: cs.primary),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text('网络测速', style: TextStyle(fontSize: MeowFont.headline, fontWeight: FontWeight.w800, color: cs.onSurface)),
                  ),
                  TextButton(
                    onPressed: () => BaseNavigator.push(context, SpeedTestHistoryPage(controller: c)),
                    child: const Text('测速记录'),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              if (r == null)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  child: Text('还没有测过。测一次看看经当前节点能跑多快', style: TextStyle(fontSize: MeowFont.footnote, color: cs.onSurfaceVariant)),
                )
              else if (r.failed)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  child: Text('上次测速没有完成：${r.error}', maxLines: 2, overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: MeowFont.footnote, color: cs.error)),
                )
              else ...[
                Row(
                  children: [
                    stat('下载', fmtRecordMbps(r.downloadMbps), 'Mbps', cs.primary),
                    stat('上传', fmtRecordMbps(r.uploadMbps), 'Mbps', cs.tertiary),
                    stat('延迟', r.latencyMs == null ? '–' : '${r.latencyMs!.round()}', 'ms', cs.onSurface),
                  ],
                ),
                if (bars.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  SizedBox(
                    height: 36,
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        for (final (i, h) in bars.indexed) ...[
                          if (i > 0) const SizedBox(width: 3),
                          Expanded(
                            child: FractionallySizedBox(
                              heightFactor: math.max(0.06, h),
                              child: DecoratedBox(
                                decoration: BoxDecoration(
                                  color: (useUpload ? cs.tertiary : cs.primary).withValues(alpha: 0.75),
                                  borderRadius: BorderRadius.circular(3),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
              ],
              if (r != null) ...[
                const SizedBox(height: 10),
                Text(
                  [r.source.title, r.connections > 1 ? '多线程' : '单线程', _when(r.date)].join(' · '),
                  style: TextStyle(fontSize: MeowFont.caption, color: cs.onSurfaceVariant),
                ),
              ],
              const SizedBox(height: 12),
              FilledButton.icon(
                onPressed: () => BaseNavigator.push(context, const SpeedTestPage(autoStart: true)),
                icon: const Icon(Icons.play_arrow_rounded),
                label: const Text('开始测速'),
              ),
            ],
          ),
        );
      },
    );
  }
}
