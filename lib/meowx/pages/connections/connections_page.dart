import 'dart:async';

import 'package:bett_box/clash/clash.dart';
import 'package:bett_box/enum/enum.dart';
import 'package:bett_box/models/models.dart';
import 'package:bett_box/providers/providers.dart';
import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/meow_tab.dart';
import '../../app/strings.dart';
import '../../state/connection.dart';
import '../../state/format.dart';
import '../../state/status.dart';
import '../../theme/page_title.dart';
import '../../theme/tokens.dart';
import '../../theme/two_pane.dart';
import '../../theme/widgets.dart';

enum _Seg { connections, logs }

/// 动态页：「连接 | 日志」分段 + 搜索；仅在页可见且已连接时每 1.5s 轮询。
/// 窄屏（手机、平板竖屏）= 标题 / 分段 / 搜索 / 汇总行 / 一张卡片里的连接列表，点一行弹出详情；
/// 两栏（≥900）= 标题行内联分段与搜索，下面连接表 + 右侧详情（设计稿 AActivity / WActivity）。
class ConnectionsPage extends ConsumerStatefulWidget {
  const ConnectionsPage({super.key, this.fetch});

  /// 取连接快照；默认问核心，只有测试会换掉。
  @visibleForTesting
  final Future<List<TrackerInfo>> Function()? fetch;

  @override
  ConsumerState<ConnectionsPage> createState() => _ConnectionsPageState();
}

class _ConnectionsPageState extends ConsumerState<ConnectionsPage> {
  _Seg _seg = _Seg.connections;
  final _search = TextEditingController();
  String _query = '';
  List<TrackerInfo> _conns = const [];
  String? _selectedId;
  Timer? _timer;
  bool _polling = false;

  /// 进入本页后是否已拿到过一次快照（之前显示「加载中」而不是「暂无连接」）
  bool _loaded = false;

  /// 上一份快照的时间：相邻两份快照的字节差 / 间隔 = 每条连接的速率
  DateTime? _polledAt;

  /// 窄屏底部弹层正在看的那条连接：轮询到新快照时跟着刷新
  final _sheetConn = ValueNotifier<TrackerInfo?>(null);

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(milliseconds: 1500), (_) => unawaited(_poll()));
    // 切到本页立即拉一次，不等定时器
    ref.listenManual(meowTabProvider, (prev, next) {
      if (next == MeowTab.connections) {
        unawaited(_poll());
      } else {
        _loaded = false;
      }
    });
    ref.listenManual(isRunningProvider, (prev, next) {
      _loaded = false;
      if (next) unawaited(_poll());
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(_poll()));
  }

  @override
  void dispose() {
    _timer?.cancel();
    _search.dispose();
    _sheetConn.dispose();
    super.dispose();
  }

  bool get _visible => ref.read(meowTabProvider) == MeowTab.connections;

  Future<void> _poll() async {
    if (!mounted || _polling) return;
    if (!ref.read(isRunningProvider)) {
      if (_conns.isNotEmpty) setState(() => _conns = const []);
      return;
    }
    if (!_visible) {
      if (_conns.isNotEmpty) setState(() => _conns = const []);   // 离屏清空
      return;
    }
    _polling = true;
    try {
      final list = await (widget.fetch ?? clashCore.getConnections)();
      if (!mounted) return;
      final now = DateTime.now();
      final ms = _polledAt == null ? 0 : now.difference(_polledAt!).inMilliseconds;
      final old = {for (final c in _conns) c.id: c};
      // 上一份快照里没有的连接（新建的、刚回到本页的）速率记 0
      int rate(int cur, int? prev) => (prev == null || ms <= 0 || cur <= prev) ? 0 : (cur - prev) * 1000 ~/ ms;
      final next = [
        for (final c in list)
          c.copyWith(
            uploadSpeed: rate(c.upload, old[c.id]?.upload),
            downloadSpeed: rate(c.download, old[c.id]?.download),
          ),
      ];
      _polledAt = now;
      setState(() {
        _conns = next;
        _loaded = true;
      });
      final watching = _sheetConn.value;
      if (watching != null) {
        final fresh = next.firstWhereOrNull((c) => c.id == watching.id);
        if (fresh != null) _sheetConn.value = fresh;
      }
    } catch (_) {
    } finally {
      _polling = false;
    }
  }

  List<TrackerInfo> get _filtered {
    if (_query.isEmpty) return _conns;
    final q = _query.toLowerCase();
    return _conns.where((c) {
      return c.metadata.host.toLowerCase().contains(q) ||
          c.metadata.destinationIP.contains(q) ||
          c.chains.any((s) => s.toLowerCase().contains(q)) ||
          c.rule.toLowerCase().contains(q) ||
          c.rulePayload.toLowerCase().contains(q) ||
          _inboundOf(c).toLowerCase().contains(q);
    }).toList();
  }

  void _switchSeg(_Seg v) {
    if (v == _seg) return;
    _search.clear();
    setState(() {
      _seg = v;
      _query = '';
    });
  }

  void _close(String id) {
    clashCore.closeConnection(id);
    setState(() {
      _conns = _conns.where((c) => c.id != id).toList();
      if (_selectedId == id) _selectedId = null;
    });
  }

  void _closeAll() {
    clashCore.closeConnections();
    setState(() => _conns = const []);
  }

  /// 窄屏没有右栏：详情放进底部弹层，内容随轮询刷新。
  Future<void> _openSheet(TrackerInfo c) async {
    FocusManager.instance.primaryFocus?.unfocus();
    _sheetConn.value = c;
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: context.mm.bg,   // 详情是白卡片，弹层用页面底色衬着
      showDragHandle: true,
      isScrollControlled: true,
      builder: (ctx) => SafeArea(
        child: ValueListenableBuilder<TrackerInfo?>(
          valueListenable: _sheetConn,
          builder: (ctx, live, _) {
            if (live == null) return const SizedBox.shrink();
            return SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _ConnDetail(c: live),
                  const SizedBox(height: 14),
                  _CloseConnButton(
                    onTap: () {
                      Navigator.of(ctx).pop();
                      _close(live.id);
                    },
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
    if (mounted) _sheetConn.value = null;
  }

  @override
  Widget build(BuildContext context) {
    final mm = context.mm;
    final twoPane = ref.watch(isTwoPaneProvider);
    final wide = ref.watch(isWideLayoutProvider);
    final running = ref.watch(isRunningProvider);
    final onConns = _seg == _Seg.connections;
    final items = onConns ? _filtered : _conns;
    final sum = _Sum.of(items);
    final summary = '${items.length} 条 · 代理 ${sum.proxied} · 直连 ${sum.direct}';

    final segment = MeowSegment<_Seg>(
      items: [
        (_Seg.connections, running && _loaded ? '连接 · ${_conns.length}' : '连接'),
        (_Seg.logs, '日志'),
      ],
      value: _seg,
      onChanged: _switchSeg,
      height: twoPane ? 40 : 44,
      fontSize: twoPane ? 13 : 14,
    );
    final search = _SearchField(
      controller: _search,
      hint: onConns ? '搜索域名 / 目标 / 规则' : '搜索日志',
      onChanged: (v) => setState(() => _query = v.trim()),
      height: twoPane ? 40 : 44,
      fontSize: twoPane ? 13 : 14,
    );
    final emptyText = _query.isEmpty ? '暂无活动连接' : '无匹配连接';

    if (!twoPane) {
      // 手机：悬浮底栏盖在内容上，列表底部让出它的高度；平板竖屏 / 窄窗口有侧栏，底边留白在外层
      final bottom = (wide ? 0.0 : 16.0) + MediaQuery.paddingOf(context).bottom;
      final Widget body;
      if (!onConns) {
        body = _LogList(query: _query, bottomPadding: bottom);
      } else if (!running) {
        body = const _Empty(icon: Icons.power_off_rounded, text: S.tunnelNotConnected);
      } else if (!_loaded) {
        body = const _Loading();
      } else {
        body = Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _SummaryRow(text: summary, action: '全部关闭', color: mm.slow, onAction: _conns.isEmpty ? null : _closeAll),
            Expanded(
              child: items.isEmpty
                  ? _Empty(icon: Icons.inbox_rounded, text: emptyText)
                  : ListView.builder(
                      padding: EdgeInsets.only(bottom: bottom),
                      itemCount: items.length,
                      itemBuilder: (_, i) => _CardSlice(
                        first: i == 0,
                        last: i == items.length - 1,
                        child: _ConnRow(
                          c: items[i],
                          onTap: () => unawaited(_openSheet(items[i])),
                          onClose: () => _close(items[i].id),
                        ),
                      ),
                    ),
            ),
          ],
        );
      }
      return Padding(
        padding: wide ? widePagePadding() : const EdgeInsets.symmetric(horizontal: 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            PageTitle(
              MeowTab.connections.label,
              trailing: running ? _Totals(up: sum.up, down: sum.down) : null,
            ),
            const SizedBox(height: 12),
            segment,
            const SizedBox(height: 12),
            search,
            const SizedBox(height: 4),
            Expanded(child: body),
          ],
        ),
      );
    }

    final selected = _conns.firstWhereOrNull((c) => c.id == _selectedId);
    final Widget body;
    if (!onConns) {
      body = _LogList(query: _query, bottomPadding: 0);
    } else if (!running) {
      body = const _Empty(icon: Icons.power_off_rounded, text: S.tunnelNotConnected);
    } else if (!_loaded) {
      body = const _Loading();
    } else {
      body = Padding(
        padding: const EdgeInsets.only(top: 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: _ConnTable(
                items: items,
                selectedId: _selectedId,
                emptyText: emptyText,
                // 再点一次选中的行 = 取消选中，右栏回到汇总
                onSelect: (id) => setState(() => _selectedId = _selectedId == id ? null : id),
              ),
            ),
            const SizedBox(width: 14),
            SizedBox(
              width: 268,
              child: selected == null
                  ? _SummaryPane(summary: summary, sum: sum)
                  : Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Expanded(child: SingleChildScrollView(child: _ConnDetail(c: selected))),
                        const SizedBox(height: 10),
                        _CloseConnButton(onTap: () => _close(selected.id)),
                      ],
                    ),
            ),
          ],
        ),
      );
    }
    return Padding(
      padding: widePagePadding(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // 标题行：标题 + 分段 + 搜索 + 本页操作（窗口按钮在上面的全局标题栏里，这里不画）
          Row(
            children: [
              Text(
                MeowTab.connections.label,
                style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold, color: mm.t1, height: 1.15),
              ),
              const SizedBox(width: 14),
              // 分段定宽 190，跟着文字缩放放大
              SizedBox(width: 190 * MediaQuery.textScalerOf(context).scale(13) / 13, child: segment),
              const SizedBox(width: 8),
              Expanded(child: search),
              if (onConns) ...[
                const SizedBox(width: 8),
                _PillButton(label: '全部关闭', color: mm.slow, onTap: _conns.isEmpty ? null : _closeAll),
              ],
            ],
          ),
          const SizedBox(height: 4),
          Expanded(child: body),
        ],
      ),
    );
  }
}

/// 行首标签与数字列（速率 / 时长）最多跟到 1.2 倍字号：定长的辅助信息，大字号时把宽度让给主机名。
TextScaler _auxScaler(BuildContext context) => MediaQuery.textScalerOf(context).clamp(maxScaleFactor: 1.2);

/// 装这些定长文字的定宽格子跟着同一个缩放比放大。
/// 按 [font] 这一档字号的实际缩放比算（Android 的非线性缩放各字号比例不同）。
double _auxWidth(BuildContext context, double width, {double font = 11}) =>
    width * _auxScaler(context).scale(font) / font;

String _hostOf(TrackerInfo c) => c.metadata.host.isNotEmpty ? c.metadata.host : c.metadata.destinationIP;
String _targetOf(TrackerInfo c) => c.chains.isEmpty ? '—' : c.chains.first;
String _ruleOf(TrackerInfo c) => c.rulePayload.isEmpty ? c.rule : '${c.rule}(${c.rulePayload})';
bool _isUdp(TrackerInfo c) => c.metadata.network.toLowerCase() == 'udp';

/// 入站：TUN / HTTP（系统代理、本地代理）/ SOCKS，来自核心的 metadata.type。
String _inboundOf(TrackerInfo c) => switch (c.metadata.type) {
  'Tun' => 'TUN',
  'HTTP' || 'HTTPS' => 'HTTP',
  'Socks4' || 'Socks5' => 'SOCKS',
  final t => t,
};

/// 经节点 / 代理组出去的连接（DIRECT、REJECT 之外的）：出站名用强调色。
bool _isProxied(TrackerInfo c) {
  final via = c.chains.firstOrNull ?? '';
  return via.isNotEmpty && via != 'DIRECT' && !via.startsWith('REJECT');
}

/// 连接时长：mm:ss，满一小时 h:mm:ss。
String _age(DateTime start) {
  final d = DateTime.now().difference(start);
  final s = d.isNegative ? 0 : d.inSeconds;
  String two(int n) => n.toString().padLeft(2, '0');
  final h = s ~/ 3600;
  return h > 0 ? '$h:${two(s % 3600 ~/ 60)}:${two(s % 60)}' : '${two(s ~/ 60)}:${two(s % 60)}';
}

/// 一份连接列表的汇总：代理 / 直连条数（口径同侧栏角标的 ConnStats）与累计上下行。
class _Sum {
  const _Sum(this.proxied, this.direct, this.up, this.down);
  final int proxied, direct, up, down;

  factory _Sum.of(List<TrackerInfo> items) {
    var proxied = 0, direct = 0, up = 0, down = 0;
    for (final c in items) {
      up += c.upload;
      down += c.download;
      if (_isProxied(c)) {
        proxied++;
      } else if (c.chains.firstOrNull == 'DIRECT') {
        direct++;
      }
    }
    return _Sum(proxied, direct, up, down);
  }
}

/// 标题右侧：当前列表累计 ↑ 上传（玫红箭头）/ ↓ 下载（紫箭头）。
class _Totals extends StatelessWidget {
  const _Totals({required this.up, required this.down});
  final int up, down;

  @override
  Widget build(BuildContext context) {
    final mm = context.mm;
    final style = MeowFont.mono(size: MeowFont.caption, color: mm.t2);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        MeowIcon(MeowGlyph.up, size: 12, color: mm.accent),
        const SizedBox(width: 3),
        Text(fmtSize(up), style: style),
        const SizedBox(width: 10),
        MeowIcon(MeowGlyph.down, size: 12, color: mm.pur),
        const SizedBox(width: 3),
        Text(fmtSize(down), style: style),
      ],
    );
  }
}

/// 搜索框：卡片底胶囊。
class _SearchField extends StatelessWidget {
  const _SearchField({
    required this.controller,
    required this.hint,
    required this.onChanged,
    required this.height,
    required this.fontSize,
  });
  final TextEditingController controller;
  final String hint;
  final ValueChanged<String> onChanged;
  final double height, fontSize;

  @override
  Widget build(BuildContext context) {
    final mm = context.mm;
    return Container(
      constraints: BoxConstraints(minHeight: height),
      padding: const EdgeInsets.symmetric(horizontal: 14),
      decoration: BoxDecoration(color: mm.elev, borderRadius: BorderRadius.circular(height / 2)),
      child: Row(
        children: [
          Icon(Icons.search_rounded, size: 18, color: mm.t2),
          const SizedBox(width: 8),
          Expanded(
            child: TextField(
              controller: controller,
              onChanged: onChanged,
              textInputAction: TextInputAction.search,
              cursorColor: mm.accent,
              style: TextStyle(fontSize: fontSize, color: mm.t1),
              decoration: InputDecoration(
                isCollapsed: true,
                filled: false,
                border: InputBorder.none,
                enabledBorder: InputBorder.none,
                focusedBorder: InputBorder.none,
                hintText: hint,
                hintMaxLines: 1,
                hintStyle: TextStyle(fontSize: fontSize, color: mm.t2),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 汇总行：左边一段说明（放不下省略），右边一个文字操作；操作不可用时变淡。
class _SummaryRow extends StatelessWidget {
  const _SummaryRow({required this.text, required this.action, required this.color, required this.onAction});
  final String text, action;
  final Color color;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final mm = context.mm;
    return Row(
      children: [
        Expanded(
          child: Text(text, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: MeowFont.caption, color: mm.t2)),
        ),
        Semantics(
          button: true,
          enabled: onAction != null,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: onAction,
            child: Opacity(
              opacity: onAction == null ? 0.4 : 1,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(14, 10, 0, 10),
                child: Text(action, style: TextStyle(fontSize: MeowFont.footnote, fontWeight: FontWeight.w600, color: color)),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// 两栏标题行里的胶囊按钮（卡片底 + 彩色字）。
class _PillButton extends StatelessWidget {
  const _PillButton({required this.label, required this.color, required this.onTap});
  final String label;
  final Color color;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: onTap == null ? 0.4 : 1,
      child: Material(
        color: context.mm.elev,
        shape: const StadiumBorder(),
        child: InkWell(
          customBorder: const StadiumBorder(),
          onTap: onTap,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 40),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14),
              child: Center(
                widthFactor: 1,
                child: Text(label, style: TextStyle(fontSize: MeowFont.footnote, fontWeight: FontWeight.w600, color: color)),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty({required this.icon, required this.text});
  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final mm = context.mm;
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 40, color: mm.t3),
            const SizedBox(height: 10),
            Text(text, textAlign: TextAlign.center, style: TextStyle(fontSize: MeowFont.subheadline, color: mm.t2)),
          ],
        ),
      ),
    );
  }
}

class _Loading extends StatelessWidget {
  const _Loading();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2, color: context.mm.t3)),
    );
  }
}

/// 懒加载列表里的一行，拼起来是一张卡片：首行带上圆角、末行带下圆角、行间 1px 分隔线。
/// （整张卡片随列表滚动，又不用把上千行一次建出来。）
class _CardSlice extends StatelessWidget {
  const _CardSlice({required this.first, required this.last, required this.child, this.edge = 2});
  final bool first, last;

  /// 卡片上下内边距
  final double edge;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final mm = context.mm;
    const r = Radius.circular(24);
    return Container(
      padding: EdgeInsets.fromLTRB(14, first ? edge : 0, 14, last ? edge : 0),
      decoration: BoxDecoration(
        color: mm.elev,
        borderRadius: BorderRadius.vertical(top: first ? r : Radius.zero, bottom: last ? r : Radius.zero),
      ),
      child: first
          ? child
          : DecoratedBox(
              decoration: BoxDecoration(border: Border(top: BorderSide(color: mm.line))),
              child: child,
            ),
    );
  }
}

/// 行首的等宽小标签（TCP / UDP，Windows 上是入站 TUN / HTTP / SOCKS）：次级底，紫 = UDP / TUN。
class _Tag extends StatelessWidget {
  const _Tag(this.text, {required this.highlight, required this.width});
  final String text;
  final bool highlight;
  final double width;

  @override
  Widget build(BuildContext context) {
    final mm = context.mm;
    return Container(
      width: _auxWidth(context, width, font: 10),
      padding: const EdgeInsets.symmetric(vertical: 2),
      alignment: Alignment.center,
      decoration: BoxDecoration(color: mm.card2, borderRadius: BorderRadius.circular(5)),
      child: Text(
        text.isEmpty ? '—' : text,
        maxLines: 1,
        softWrap: false,
        overflow: TextOverflow.clip,
        textScaler: _auxScaler(context),
        style: MeowFont.mono(size: 10, weight: FontWeight.w700, color: highlight ? mm.pur : mm.t2),
      ),
    );
  }
}

/// 行首标签：桌面形态标入站（TUN 与系统代理并存，看得出流量是怎么被接管进来的）；
/// Android 全走 VPN（TUN），标入站是噪音，标 TCP / UDP。
Widget _leadTag(TrackerInfo c) {
  if (isDesktopUi) {
    final inbound = _inboundOf(c);
    return _Tag(inbound, highlight: inbound == 'TUN', width: 46);
  }
  return _Tag(_isUdp(c) ? 'UDP' : 'TCP', highlight: _isUdp(c), width: 34);
}

/// 行首标了入站时，TCP / UDP 挪到规则前面。
String _subOf(TrackerInfo c) => isDesktopUi ? '${c.metadata.network.toUpperCase()} · ${_ruleOf(c)}' : _ruleOf(c);

/// 窄屏连接行：标签 + 主机（下面一行：出站 + 规则）+ 右侧下载速率 / 时长 + 关闭。点行看详情。
class _ConnRow extends StatelessWidget {
  const _ConnRow({required this.c, required this.onTap, required this.onClose});
  final TrackerInfo c;
  final VoidCallback onTap, onClose;

  @override
  Widget build(BuildContext context) {
    final mm = context.mm;
    final num = MeowFont.mono(size: MeowFont.caption2, color: mm.t2);
    final aux = _auxScaler(context);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 9),
        child: Row(
          children: [
            _leadTag(c),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${_hostOf(c)}:${c.metadata.destinationPort}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: mm.t1),
                  ),
                  const SizedBox(height: 2),
                  // 出站名比规则要紧：放不下时出站最多占六成，其余给规则
                  Row(
                    children: [
                      Flexible(
                        flex: 3,
                        child: Text(
                          _targetOf(c),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: MeowFont.caption2, fontWeight: FontWeight.w600, color: _isProxied(c) ? mm.accent : mm.t2),
                        ),
                      ),
                      const SizedBox(width: 6),
                      Flexible(
                        flex: 2,
                        child: Text(_subOf(c), maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: MeowFont.caption2, color: mm.t2)),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(width: 10),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text('↓ ${fmtRate(c.downloadSpeed ?? 0)}', textScaler: aux, style: num),
                const SizedBox(height: 2),
                Text(_age(c.start), textScaler: aux, style: num),
              ],
            ),
            // 关闭：图标贴着卡片内容右缘，左边 10 的间距也算进点按范围
            Semantics(
              button: true,
              label: '关闭这条连接',
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: onClose,
                child: Container(
                  constraints: const BoxConstraints(minWidth: 34, minHeight: 44),
                  alignment: Alignment.centerRight,
                  child: Icon(Icons.close_rounded, size: 17, color: mm.t2),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 两栏连接表：一张撑满高度的卡片，表头固定、行懒加载；选中行柔粉底。
/// 「出站」列与「主机」列按 2:3 分剩余宽度（设计稿 1100 宽时出站 ≈ 128），窗口窄 / 字号大时一起收窄。
class _ConnTable extends StatelessWidget {
  const _ConnTable({required this.items, required this.selectedId, required this.emptyText, required this.onSelect});
  final List<TrackerInfo> items;
  final String? selectedId;
  final String emptyText;
  final ValueChanged<String> onSelect;

  @override
  Widget build(BuildContext context) {
    final mm = context.mm;
    final head = TextStyle(fontSize: MeowFont.caption2, fontWeight: FontWeight.w600, color: mm.t2);
    final tagW = _auxWidth(context, isDesktopUi ? 46 : 34, font: 10);
    final rateW = _auxWidth(context, 70);
    final ageW = _auxWidth(context, 52);
    Widget cell(String s, {TextAlign align = TextAlign.start}) =>
        Text(s, maxLines: 1, overflow: TextOverflow.ellipsis, textAlign: align, style: head);
    return Container(
      padding: const EdgeInsets.fromLTRB(6, 4, 6, 4),
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(color: mm.elev, borderRadius: BorderRadius.circular(22)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 34),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10),
              child: Row(
                children: [
                  SizedBox(width: tagW, child: cell(isDesktopUi ? '入站' : '网络')),
                  const SizedBox(width: 10),
                  Expanded(flex: 3, child: cell('主机')),
                  const SizedBox(width: 10),
                  Expanded(flex: 2, child: cell('出站')),
                  const SizedBox(width: 10),
                  SizedBox(width: rateW, child: cell('下载', align: TextAlign.end)),
                  const SizedBox(width: 10),
                  SizedBox(width: ageW, child: cell('时长', align: TextAlign.end)),
                ],
              ),
            ),
          ),
          Expanded(
            child: items.isEmpty
                ? _Empty(icon: Icons.inbox_rounded, text: emptyText)
                : ListView.builder(
                    itemCount: items.length,
                    itemBuilder: (_, i) => _ConnTableRow(
                      c: items[i],
                      selected: items[i].id == selectedId,
                      rateWidth: rateW,
                      ageWidth: ageW,
                      onTap: () => onSelect(items[i].id),
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}

class _ConnTableRow extends StatelessWidget {
  const _ConnTableRow({
    required this.c,
    required this.selected,
    required this.rateWidth,
    required this.ageWidth,
    required this.onTap,
  });
  final TrackerInfo c;
  final bool selected;
  final double rateWidth, ageWidth;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final mm = context.mm;
    final num = MeowFont.mono(size: MeowFont.caption2, color: mm.t2);
    final aux = _auxScaler(context);
    // 数字列定宽右对齐；超长的（上百小时的时长）缩小而不是溢出
    Widget fit(String s, double width) => SizedBox(
      width: width,
      child: FittedBox(fit: BoxFit.scaleDown, alignment: Alignment.centerRight, child: Text(s, maxLines: 1, textScaler: aux, style: num)),
    );
    return Material(
      color: selected ? mm.soft : Colors.transparent,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 44),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            child: Row(
              children: [
                _leadTag(c),
                const SizedBox(width: 10),
                Expanded(
                  flex: 3,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        '${_hostOf(c)}:${c.metadata.destinationPort}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: MeowFont.footnote, fontWeight: FontWeight.w600, color: mm.t1),
                      ),
                      Text(_subOf(c), maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: MeowFont.caption2, color: mm.t2)),
                    ],
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  flex: 2,
                  child: Text(
                    _targetOf(c),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: MeowFont.caption, fontWeight: FontWeight.w600, color: _isProxied(c) ? mm.accent : mm.t2),
                  ),
                ),
                const SizedBox(width: 10),
                fit(fmtRate(c.downloadSpeed ?? 0), rateWidth),
                const SizedBox(width: 10),
                fit(_age(c.start), ageWidth),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 详情里的小卡片：小字标题 + 值。[hero] = 樱粉主卡。
class _InfoCard extends StatelessWidget {
  const _InfoCard({required this.label, required this.value, this.hero = false, this.mono = false});
  final String label, value;
  final bool hero, mono;

  @override
  Widget build(BuildContext context) {
    final mm = context.mm;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(color: hero ? mm.hero : mm.elev, borderRadius: BorderRadius.circular(20)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: TextStyle(fontSize: MeowFont.caption2, color: mm.t2)),
          const SizedBox(height: 4),
          Text(
            value,
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            style: mono
                ? MeowFont.mono(size: MeowFont.footnote, weight: FontWeight.w600, color: mm.t1)
                : TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: mm.t1),
          ),
        ],
      ),
    );
  }
}

/// 上传 / 下载两格：小字标题 + 大数字。
class _StatPair extends StatelessWidget {
  const _StatPair({required this.up, required this.down});
  final int up, down;

  @override
  Widget build(BuildContext context) {
    final mm = context.mm;
    Widget cell(String label, int bytes) => Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(color: mm.elev, borderRadius: BorderRadius.circular(18)),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label, style: TextStyle(fontSize: MeowFont.caption2, color: mm.t2)),
            const SizedBox(height: 1),
            Text(
              fmtSize(bytes),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: mm.t1, fontFamilyFallback: meowRounded),
            ),
          ],
        ),
      ),
    );
    return Row(children: [cell(S.upload, up), const SizedBox(width: 10), cell(S.download, down)]);
  }
}

/// 连接详情：出站链路（主卡）/ 命中规则 / 上传 · 下载 / 网络 · 入站 · 主机 · 目标 IP · 已持续。
/// 宽屏放右栏，窄屏放底部弹层；「关闭这条连接」由外层另放。
class _ConnDetail extends StatelessWidget {
  const _ConnDetail({required this.c});
  final TrackerInfo c;

  @override
  Widget build(BuildContext context) {
    final mm = context.mm;
    final inbound = _inboundOf(c);
    final facts = <(String, String)>[
      ('网络', c.metadata.network.toUpperCase()),
      if (inbound.isNotEmpty) ('入站', '$inbound${c.metadata.inboundName.isEmpty ? '' : ' · ${c.metadata.inboundName}'}'),
      ('主机', '${_hostOf(c)}:${c.metadata.destinationPort}'),
      if (c.metadata.destinationIP.isNotEmpty && c.metadata.host.isNotEmpty) ('目标 IP', c.metadata.destinationIP),
      ('已持续', _age(c.start)),
    ];
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _InfoCard(label: '出站链路', value: c.chains.isEmpty ? '—' : c.chains.reversed.join(' › '), hero: true),
        const SizedBox(height: 10),
        _InfoCard(label: '命中规则', value: _ruleOf(c), mono: true),
        const SizedBox(height: 10),
        _StatPair(up: c.upload, down: c.download),
        const SizedBox(height: 10),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
          decoration: BoxDecoration(color: mm.elev, borderRadius: BorderRadius.circular(20)),
          child: Column(
            children: [
              for (final (i, f) in facts.indexed)
                Container(
                  constraints: const BoxConstraints(minHeight: 36),
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  decoration: i == 0 ? null : BoxDecoration(border: Border(top: BorderSide(color: mm.line))),
                  child: Row(
                    children: [
                      Text(f.$1, style: TextStyle(fontSize: MeowFont.caption, color: mm.t2)),
                      const SizedBox(width: 8),
                      // 值拿键之外的全部宽度、右对齐
                      Expanded(
                        child: Text(
                          f.$2,
                          textAlign: TextAlign.end,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: MeowFont.mono(size: MeowFont.caption, color: mm.t1),
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

class _CloseConnButton extends StatelessWidget {
  const _CloseConnButton({required this.onTap});
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final mm = context.mm;
    return Material(
      color: mm.elev,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: Container(
          constraints: const BoxConstraints(minHeight: 44),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          alignment: Alignment.center,
          child: Text('关闭这条连接', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: mm.slow)),
        ),
      ),
    );
  }
}

/// 两栏右栏、没选连接时：当前列表的汇总（条数 / 累计上下行），选一行换成该连接的详情。
class _SummaryPane extends StatelessWidget {
  const _SummaryPane({required this.summary, required this.sum});
  final String summary;
  final _Sum sum;

  @override
  Widget build(BuildContext context) {
    final mm = context.mm;
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _InfoCard(label: '活动连接', value: summary, hero: true),
          const SizedBox(height: 10),
          _StatPair(up: sum.up, down: sum.down),
          const SizedBox(height: 14),
          Text(
            '选择一条连接查看详情',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: MeowFont.caption, color: mm.t2),
          ),
        ],
      ),
    );
  }
}

/// 日志：汇总行（状态 + 清空）+ 一张卡片里的日志行（级别点 + 时间 HH:mm:ss + 消息，等宽）；默认关；自动滚底。
class _LogList extends ConsumerStatefulWidget {
  const _LogList({required this.query, required this.bottomPadding});
  final String query;
  final double bottomPadding;

  @override
  ConsumerState<_LogList> createState() => _LogListState();
}

class _LogListState extends ConsumerState<_LogList> {
  final _scroll = ScrollController();

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  static final _time = RegExp(r'\d{2}:\d{2}:\d{2}');

  @override
  Widget build(BuildContext context) {
    final mm = context.mm;
    final open = ref.watch(appSettingProvider.select((s) => s.openLogs));
    final all = ref.watch(logsProvider).list;
    final q = widget.query.toLowerCase();
    final logs = q.isEmpty ? all : all.where((l) => l.payload.toLowerCase().contains(q)).toList();
    if (!open) {
      return const _Empty(icon: Icons.notes_rounded, text: '日志已关闭 · 在「我的 → 设置」打开「记录日志」');
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients && q.isEmpty) _scroll.jumpTo(_scroll.position.maxScrollExtent);
    });
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _SummaryRow(
          text: q.isEmpty ? '记录日志已开启 · 自动滚动到底' : '${logs.length} 条匹配',
          action: '清空',
          color: mm.accent,
          onAction: all.isEmpty ? null : () => ref.read(logsProvider.notifier).clearLogs(),
        ),
        Expanded(
          child: logs.isEmpty
              ? _Empty(icon: Icons.notes_rounded, text: q.isEmpty ? '暂无日志' : '无匹配日志')
              : ListView.builder(
                  controller: _scroll,
                  padding: EdgeInsets.only(bottom: widget.bottomPadding),
                  itemCount: logs.length,
                  itemBuilder: (_, i) => _CardSlice(
                    first: i == 0,
                    last: i == logs.length - 1,
                    edge: 4,
                    child: _logRow(mm, logs[i]),
                  ),
                ),
        ),
      ],
    );
  }

  Widget _logRow(MeowTokens mm, Log l) {
    final color = switch (l.logLevel) {
      LogLevel.error => mm.slow,
      LogLevel.warning => mm.mid,
      _ => mm.good,
    };
    final t = _time.firstMatch(l.dateTime)?.group(0) ?? l.dateTime;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      // 级别点嵌在时间文字里按行居中，整行与消息按基线对齐：任意字号下点都不偏上
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.baseline,
        textBaseline: TextBaseline.alphabetic,
        children: [
          Text.rich(
            TextSpan(
              style: MeowFont.mono(size: MeowFont.caption2, color: mm.t2),
              children: [
                WidgetSpan(
                  alignment: PlaceholderAlignment.middle,
                  child: Padding(padding: const EdgeInsets.only(right: 8), child: StatusDot(color: color, size: 7)),
                ),
                TextSpan(text: t),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(l.payload, style: MeowFont.mono(size: MeowFont.caption, color: mm.t1).copyWith(height: 17 / 12)),
          ),
        ],
      ),
    );
  }
}
