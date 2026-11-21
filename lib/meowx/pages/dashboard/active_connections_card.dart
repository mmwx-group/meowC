import 'dart:async';
import 'dart:math' as math;

import 'package:bett_box/models/models.dart';
import 'package:bett_box/state.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/meow_tab.dart';
import '../../state/connection.dart';
import '../../state/format.dart';
import '../../state/status.dart';
import '../../theme/m3.dart';
import '../../theme/m3_kit.dart';
import '../../theme/tokens.dart';

/// 一次最多留这么多条（最大化的窗口也排不下更多行）。
const _maxRows = 30;

/// 宽屏首页右列底部的「活跃连接」：最近建立的几条连接（入站 / 目标主机 / 出口节点 / 速率），点了去「动态」。
/// 每秒取一次连接表，只在首页可见且核心运行中时取；速率 = 相邻两次快照的下载字节差。
class HomeActiveConnections extends ConsumerStatefulWidget {
  const HomeActiveConnections({super.key, this.expand = false, this.minRows = 3, this.fetch});
  final bool expand;
  final int minRows;

  /// 取连接快照；默认问核心，只有测试会换掉。
  final Future<List<TrackerInfo>> Function()? fetch;

  @override
  ConsumerState<HomeActiveConnections> createState() => _HomeActiveConnectionsState();
}

class _HomeActiveConnectionsState extends ConsumerState<HomeActiveConnections> {
  List<TrackerInfo> _conns = const [];
  Map<String, int> _speeds = const {};
  Map<String, int> _lastDown = const {};
  DateTime? _lastAt;
  bool _polling = false;

  @override
  void initState() {
    super.initState();
    dashboardRefreshManager.tick1s.addListener(_tick);
    ref.listenManual(meowTabProvider, (prev, next) {
      if (next == MeowTab.home) _tick();
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => _tick());
  }

  @override
  void dispose() {
    dashboardRefreshManager.tick1s.removeListener(_tick);
    super.dispose();
  }

  void _tick() => unawaited(_poll());

  Future<void> _poll() async {
    if (!mounted || _polling) return;
    if (!ref.read(isRunningProvider) || ref.read(meowTabProvider) != MeowTab.home) {
      _lastDown = const {};
      _lastAt = null;
      if (_conns.isNotEmpty) setState(() => _conns = const []);
      return;
    }
    _polling = true;
    try {
      final list = await (widget.fetch ?? ref.read(connStatsProvider.notifier).fetchConnections)();
      if (!mounted) return;
      final now = DateTime.now();
      final secs = _lastAt == null ? 0.0 : now.difference(_lastAt!).inMilliseconds / 1000;
      final speeds = <String, int>{};
      final down = <String, int>{};
      for (final c in list) {
        down[c.id] = c.download;
        final prev = _lastDown[c.id];
        if (prev != null && secs > 0) speeds[c.id] = math.max(0, ((c.download - prev) / secs).round());
      }
      final recent = [...list]..sort((a, b) => b.start.compareTo(a.start));
      setState(() {
        _conns = recent.length > _maxRows ? recent.sublist(0, _maxRows) : recent;
        _speeds = speeds;
        _lastDown = down;
        _lastAt = now;
      });
    } catch (_) {
    } finally {
      _polling = false;
    }
  }

  static String _inbound(TrackerInfo c) => switch (c.metadata.type) {
    'Tun' => 'TUN',
    'HTTP' || 'HTTPS' => 'HTTP',
    'Socks4' || 'Socks5' => 'SOCKS',
    '' => '—',
    final t => t,
  };

  Widget _tableHeader(BuildContext context) {
    final cs = context.cs;
    final style = TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: cs.onSurfaceVariant.withValues(alpha: 0.78));
    return Padding(
      padding: const EdgeInsets.only(top: 2, bottom: 6),
      child: Row(
        children: [
          SizedBox(width: 48, child: Text('入站', style: style)),
          const SizedBox(width: 8),
          Expanded(flex: 3, child: Text('目标主机', style: style)),
          const SizedBox(width: 8),
          Expanded(flex: 2, child: Text('出口节点', textAlign: TextAlign.end, style: style)),
          const SizedBox(width: 8),
          SizedBox(width: 76, child: Text('速率', textAlign: TextAlign.end, style: style)),
        ],
      ),
    );
  }

  Widget _row(BuildContext context, TrackerInfo c, double height) {
    final cs = context.cs;
    final mm = context.mm;
    final dark = context.isDarkMode;
    final inbound = _inbound(c);
    final host = c.metadata.host.isNotEmpty ? c.metadata.host : c.metadata.destinationIP;
    final via = c.chains.isEmpty ? '—' : c.chains.first;
    final proxied = c.chains.isNotEmpty && via != 'DIRECT' && !via.startsWith('REJECT');
    final speed = _speeds[c.id];
    final isTun = inbound == 'TUN';
    final tagBg = isTun
        ? mm.pur.withValues(alpha: dark ? 0.22 : 0.12)
        : cs.surfaceContainerHighest.withValues(alpha: dark ? 0.7 : 0.85);
    final tagFg = isTun ? mm.pur : cs.onSurfaceVariant;
    return Container(
      height: height,
      decoration: BoxDecoration(border: Border(top: BorderSide(color: cs.outlineVariant.withValues(alpha: 0.55)))),
      child: Row(
        children: [
          Container(
            width: 48,
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2.5),
            decoration: BoxDecoration(color: tagBg, borderRadius: BorderRadius.circular(6)),
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(
                inbound,
                maxLines: 1,
                textScaler: MediaQuery.textScalerOf(context).clamp(maxScaleFactor: 1.2),
                style: MeowFont.mono(size: 10, weight: FontWeight.w700, color: tagFg),
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            flex: 3,
            child: Text(
              c.metadata.destinationPort.isEmpty ? host : '$host:${c.metadata.destinationPort}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: cs.onSurface),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            flex: 2,
            child: Text(
              via,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.end,
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: proxied ? cs.primary : cs.onSurfaceVariant),
            ),
          ),
          const SizedBox(width: 8),
          SizedBox(
            width: 76,
            child: FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerRight,
              child: Text(speed == null ? '—' : fmtRate(speed), maxLines: 1, style: MeowFont.mono(size: 11, color: cs.onSurfaceVariant)),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = context.cs;
    final running = ref.watch(isRunningProvider);
    final total = ref.watch(connStatsProvider.select((s) => s.total));
    final conns = running ? _conns : const <TrackerInfo>[];
    final rowH = math.max(38.0, MediaQuery.textScalerOf(context).scale(13) * 1.5 + 14);
    final minHeight = rowH * widget.minRows;

    Widget rows(int count) {
      if (conns.isEmpty) {
        return Center(
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                running ? Icons.wifi_tethering_rounded : Icons.power_settings_new_rounded,
                size: 16,
                color: cs.onSurfaceVariant.withValues(alpha: 0.65),
              ),
              const SizedBox(width: 6),
              Text(
                running ? '暂无活跃连接' : '连接后显示实时流量明细',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
              ),
            ],
          ),
        );
      }
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [for (final c in conns.take(count)) _row(context, c, rowH)],
      );
    }

    return M3Card(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 10),
      onTap: () => goTab(ref, MeowTab.connections),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: widget.expand ? MainAxisSize.max : MainAxisSize.min,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  '活跃连接',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 14, fontWeight: FontWeight.w800, color: cs.onSurface),
                ),
              ),
              if (running && total > 0)
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text('查看全部 $total 条', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: cs.primary)),
                    const SizedBox(width: 2),
                    Icon(Icons.chevron_right_rounded, size: 16, color: cs.primary),
                  ],
                ),
            ],
          ),
          const SizedBox(height: 6),
          if (conns.isNotEmpty) _tableHeader(context),
          if (widget.expand)
            Expanded(
              child: _IntrinsicBarrier(
                minHeight: minHeight,
                child: LayoutBuilder(builder: (context, c) => rows(math.max(1, (c.maxHeight / rowH).floor()))),
              ),
            )
          else
            SizedBox(height: minHeight, child: rows(widget.minRows)),
        ],
      ),
    );
  }
}

class _IntrinsicBarrier extends StatelessWidget {
  const _IntrinsicBarrier({required this.minHeight, required this.child});
  final double minHeight;
  final Widget child;

  @override
  Widget build(BuildContext context) => ConstrainedBox(
    constraints: BoxConstraints(minHeight: minHeight),
    child: CustomSingleChildLayout(delegate: const _FillDelegate(), child: child),
  );
}

class _FillDelegate extends SingleChildLayoutDelegate {
  const _FillDelegate();

  @override
  Size getSize(BoxConstraints constraints) =>
      Size(constraints.maxWidth, constraints.hasBoundedHeight ? constraints.maxHeight : constraints.minHeight);

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) => BoxConstraints.tight(getSize(constraints));

  @override
  bool shouldRelayout(_FillDelegate oldDelegate) => false;
}
