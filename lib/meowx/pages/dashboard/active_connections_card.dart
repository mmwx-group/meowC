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
import '../../theme/glass_card.dart';
import '../../theme/tokens.dart';
import '../../theme/widgets.dart';

/// 一次最多留这么多条（最大化的窗口也排不下更多行）。
const _maxRows = 30;

/// 宽屏首页右列底部的「活跃连接」：最近建立的几条连接（入站 / 主机 / 出站 / 下载速率），点了去「动态」。
/// 每秒取一次连接表，只在首页可见且核心运行中时取；速率 = 相邻两次快照的下载字节差。
/// 取数经壳的 ConnStatsController：这份快照顺手更新连接计数，壳同一拍不再另拉一次。
/// [expand]：外层给了定高（两列布局里撑满右列），能排几行排几行，至少 [minRows] 行的高度；否则固定排 [minRows] 行。
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
    // 切回首页立即拉一次，不等下一跳
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
      // 离屏 / 停止：清空，回来时从头算速率（隔了很久的差值不是「每秒」）
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

  /// 入站：TUN / HTTP（系统代理、本地代理）/ SOCKS，来自核心的 metadata.type（与动态页同一口径）。
  static String _inbound(TrackerInfo c) => switch (c.metadata.type) {
    'Tun' => 'TUN',
    'HTTP' || 'HTTPS' => 'HTTP',
    'Socks4' || 'Socks5' => 'SOCKS',
    '' => '—',
    final t => t,
  };

  Widget _row(BuildContext context, TrackerInfo c, double height) {
    final mm = context.mm;
    final inbound = _inbound(c);
    final host = c.metadata.host.isNotEmpty ? c.metadata.host : c.metadata.destinationIP;
    final via = c.chains.isEmpty ? '—' : c.chains.first;   // chains 首项 = 实际落地的节点（或 DIRECT）
    final proxied = c.chains.isNotEmpty && via != 'DIRECT' && !via.startsWith('REJECT');
    final speed = _speeds[c.id];
    return Container(
      height: height,
      decoration: BoxDecoration(border: Border(top: BorderSide(color: mm.line))),
      child: Row(
        children: [
          Container(
            width: 46,
            padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 2),
            decoration: BoxDecoration(color: mm.card2, borderRadius: BorderRadius.circular(5)),
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(
                inbound,
                maxLines: 1,
                textScaler: MediaQuery.textScalerOf(context).clamp(maxScaleFactor: 1.2),
                style: MeowFont.mono(size: 10, weight: FontWeight.w700, color: inbound == 'TUN' ? mm.pur : mm.t2),
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
              style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: mm.t1),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            flex: 2,
            child: Text(
              proxied ? stripFlag(via) : via,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.end,
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: proxied ? mm.accent : mm.t2),
            ),
          ),
          const SizedBox(width: 8),
          SizedBox(
            width: 78,
            child: FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerRight,
              child: Text(speed == null ? '—' : fmtRate(speed), maxLines: 1, style: MeowFont.mono(size: 11, color: mm.t2)),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final mm = context.mm;
    final running = ref.watch(isRunningProvider);
    final total = ref.watch(connStatsProvider.select((s) => s.total));
    final conns = running ? _conns : const <TrackerInfo>[];
    // 行高按字号走（1.0 倍 = 设计稿的 38）：行是定高的，文字放大后不能被裁
    final rowH = math.max(38.0, MediaQuery.textScalerOf(context).scale(13) * 1.5 + 14);
    final minHeight = rowH * widget.minRows;

    Widget rows(int count) {
      if (conns.isEmpty) {
        return Center(
          child: Text(
            running ? '暂无连接' : '未连接',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 12, color: mm.t2),
          ),
        );
      }
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [for (final c in conns.take(count)) _row(context, c, rowH)],
      );
    }

    return GlassCard(
      radius: 22,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      onTap: () => goTab(ref, MeowTab.connections),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: widget.expand ? MainAxisSize.max : MainAxisSize.min,
        children: [
          ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 30),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    '活跃连接',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: mm.t2),
                  ),
                ),
                if (running && total > 0)
                  Text('查看全部 $total 条', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: mm.accent)),
              ],
            ),
          ),
          if (widget.expand)
            Expanded(
              child: _IntrinsicBarrier(
                minHeight: minHeight,
                child: LayoutBuilder(builder: (context, c) => rows((c.maxHeight / rowH).floor())),
              ),
            )
          else
            SizedBox(height: minHeight, child: rows(widget.minRows)),
        ],
      ),
    );
  }
}

/// 向上只报一个固定的最小高度、不把 intrinsic 量度传给子项的容器。
/// 宽屏首页用 IntrinsicHeight 判断「一屏放不放得下」（见 dashboard_page.dart），而 LayoutBuilder 不支持 intrinsic 量度（会断言）；
/// CustomSingleChildLayout 的 intrinsic 只问 delegate、不问子项，正好隔开。布局时子项铺满拿到的空间。
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

  // 量 intrinsic 时传进来的高度无界：报 0，由外面的 minHeight 垫底
  @override
  Size getSize(BoxConstraints constraints) =>
      Size(constraints.maxWidth, constraints.hasBoundedHeight ? constraints.maxHeight : constraints.minHeight);

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) => BoxConstraints.tight(getSize(constraints));

  @override
  bool shouldRelayout(_FillDelegate oldDelegate) => false;
}
