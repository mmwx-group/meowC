import 'dart:async';

import 'package:bett_box/clash/clash.dart';
import 'package:bett_box/models/models.dart';
import 'package:flutter/material.dart';

import '../../state/format.dart';
import '../../theme/m3.dart';
import '../../theme/m3_kit.dart';
import '../../theme/tokens.dart';

/// 点首页「内存」格：核心的内存构成（同 iOS 的「扩展内存构成」）。弹层开着时每 3 秒问一次核心，关掉即停。
Future<void> showMemoryReport(BuildContext context, {Future<CoreStatus?> Function()? fetch}) => showModalBottomSheet<void>(
  context: context,
  showDragHandle: true,
  isScrollControlled: true,
  builder: (_) => SafeArea(child: MemoryReport(fetch: fetch ?? clashCore.getCoreStatus)),
);

class MemoryReport extends StatefulWidget {
  const MemoryReport({super.key, required this.fetch});
  final Future<CoreStatus?> Function() fetch;

  @override
  State<MemoryReport> createState() => _MemoryReportState();
}

class _MemoryReportState extends State<MemoryReport> {
  CoreStatus? _status;
  bool _failed = false;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
    _timer = Timer.periodic(const Duration(seconds: 3), (_) => unawaited(_load()));
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final s = await widget.fetch();
      if (mounted) setState(() => (_status = s ?? _status, _failed = s == null && _status == null));
    } catch (_) {
      if (mounted && _status == null) setState(() => _failed = true);
    }
  }

  static String _ago(int lastGcMs) {
    if (lastGcMs <= 0) return '—';
    final d = DateTime.now().difference(DateTime.fromMillisecondsSinceEpoch(lastGcMs));
    if (d.isNegative || d.inSeconds < 1) return '刚刚';
    if (d.inMinutes < 1) return '${d.inSeconds} 秒前';
    if (d.inHours < 1) return '${d.inMinutes} 分钟前';
    return '${d.inHours} 小时前';
  }

  @override
  Widget build(BuildContext context) {
    final cs = context.cs;
    final s = _status;
    final rows = s == null
        ? const <(String, String)>[]
        : [
            ('常驻（使用中 + 未归还）', fmtSize(s.physical)),
            ('使用中（堆 + 栈）', fmtSize(s.inUse)),
            ('空闲未归还系统', fmtSize(s.reclaimable)),
            ('堆对象', '${s.heapObjects}'),
            ('协程', '${s.goroutines}'),
            ('上次 GC', _ago(s.lastGC)),
            ('规则', '${s.rules}'),
            ('节点', '${s.proxies}'),
            ('代理组', '${s.proxyGroups}'),
            ('规则集', '${s.ruleProviders}'),
            ('节点集', '${s.proxyProviders}'),
            ('地理数据', s.geodataUse),
          ];
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('核心内存构成', style: TextStyle(fontSize: MeowFont.title3, fontWeight: FontWeight.w800, color: cs.onSurface)),
          const SizedBox(height: 4),
          Text('每 3 秒刷新；首页「内存」格显示的是常驻那一项', style: TextStyle(fontSize: MeowFont.caption, color: cs.onSurfaceVariant)),
          const SizedBox(height: 14),
          if (s == null)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 32),
              child: Center(
                child: _failed
                    ? Text('取不到核心状态（核心没在运行？）', style: TextStyle(color: cs.onSurfaceVariant))
                    : const CircularProgressIndicator(),
              ),
            )
          else
            Flexible(
              child: SingleChildScrollView(
                child: Column(
                  children: [
                    for (final (i, (label, value)) in rows.indexed)
                      Padding(
                        padding: EdgeInsets.only(top: i == 0 ? 0 : 3),
                        child: M3SegmentSlot(
                          index: i,
                          count: rows.length,
                          child: M3ListRow(
                            title: label,
                            titleSize: 14,
                            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                            trailing: Text(
                              value,
                              style: MeowFont.mono(size: 13, weight: FontWeight.w700, color: cs.onSurface),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}
