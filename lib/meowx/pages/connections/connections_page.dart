import '../../theme/card_surface.dart';
import 'dart:async';

import 'package:bett_box/clash/clash.dart';
import 'package:bett_box/common/common.dart';
import 'package:bett_box/enum/enum.dart';
import 'package:bett_box/models/models.dart';
import 'package:bett_box/providers/providers.dart';
import 'package:bett_box/state.dart';
import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollDirection;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/meow_tab.dart';
import '../../app/window_controls.dart';
import '../../app/strings.dart';
import '../../state/closed_connections.dart';
import '../../state/connection.dart';
import '../../state/custom_rules.dart';
import '../../state/dial_failures.dart';
import '../../state/format.dart';
import '../../state/log_source.dart';
import '../../state/status.dart';
import '../../state/traffic_kind.dart';
import '../../theme/m3.dart';
import '../../theme/m3_kit.dart';
import '../../theme/page_title.dart';
import '../../theme/tokens.dart';
import '../../theme/two_pane.dart';
import '../me/me_kit.dart' show MeSegmentGap;
import 'conn_rule_card.dart';

enum _Seg { connections, logs }

/// 「已关闭」那份记录：放在页面外，页面重建 / 离开再回来都还在；断开代理、内核重启时清空。
/// 只有动态页在轮询（页面可见、App 在前台）时才比得出谁关了，所以只记这段时间里关闭的。
final _closedConnsProvider = Provider<ClosedConnections>((ref) {
  final closed = ClosedConnections();
  ref.listen(isRunningProvider, (prev, next) => closed.clear());
  ref.listen(isRestartingCoreProvider, (prev, next) => closed.clear());
  return closed;
});

/// 没有画面在用、动态页的轮询该停。[background] = globalState.backgroundMode（口径同每秒节拍）：
/// 桌面只有隐藏或最小化才为真，失焦不算，为真就停。移动端它把 inactive 也算后台，而 Android 分屏 / 小窗里
/// 焦点在另一个 App 时一直是 inactive——本页整屏看得见（一边用别的 App 一边看它建了哪些连接），照常刷新；
/// 真正不可见（hidden / paused / detached）才停。
@visibleForTesting
bool connPollingPaused({required bool background, required bool desktop, required AppLifecycleState? lifecycle}) =>
    background && (desktop || lifecycle != AppLifecycleState.inactive);

/// 动态页：「连接 | 日志」分段 + 搜索；仅在页可见、App 在前台且已连接时每 1.5s 轮询。
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

  /// 类型筛选（全部 / 推送 / DNS / 直连 / 代理 / 已关闭），连接与日志共用（对应 iOS，APNs 换成 Google 推送）；
  /// 「已关闭」只作用于连接，日志按「全部」
  ActivityKind _kind = ActivityKind.all;

  bool get _closedMode => _kind == ActivityKind.closed;

  // 「已关闭」= 关闭的连接 + 拨号失败（同 iOS），按时刻新的在前；两份输入都没变就用上一份（筛选按 identical 判断要不要重算）
  List<ClosedConnection>? _mergedClosed;
  List<DialFailure>? _mergedFailures;
  List<TrackerInfo> _merged = const [];
  final Map<String, DialFailure> _failureById = {};
  final Map<String, DateTime> _endedAt = {};

  List<TrackerInfo> get _closedSource {
    final closed = _closed.items;
    final failures = ref.read(dialFailuresProvider);
    if (identical(closed, _mergedClosed) && identical(failures, _mergedFailures)) return _merged;
    _mergedClosed = closed;
    _mergedFailures = failures;
    _failureById.clear();
    _endedAt.clear();
    final rows = <(DateTime, TrackerInfo)>[
      for (final c in closed) (c.closedAt, c.info),
      for (final f in failures) (f.at, f.info),
    ];
    for (final f in failures) {
      _failureById['fail:${f.seq}'] = f;
    }
    for (final (at, info) in rows) {
      _endedAt[info.id] = at;
    }
    rows.sort((a, b) => b.$1.compareTo(a.$1));
    _merged = List.unmodifiable([for (final r in rows) r.$2]);
    return _merged;
  }

  ClosedConnections get _closed => ref.read(_closedConnsProvider);
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

  /// 轮询改了 [_conns] / [_loaded] 之后敲一下：只重建吃这两样的那几块（列表、汇总、标题里的累计、分段上的条数），
  /// 标题、搜索框和整页骨架不跟着每 1.5s 重建。
  final _polled = _Signal();

  // 当前显示的那份列表（按搜索词筛过）与它的汇总：快照或搜索词变了才重算（见 _view）
  List<TrackerInfo>? _viewOf;
  String? _viewQuery;
  ActivityKind? _viewKind;
  List<TrackerInfo> _viewItems = const [];
  _Sum _viewSum = const _Sum(0, 0, 0, 0);

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(milliseconds: 1500), (_) => unawaited(_poll()));
    // 退到后台期间不拉（见 _poll）：回到前台立即补一次，不等定时器
    globalState.backgroundMode.addListener(_onBackgroundChanged);
    // 切到本页：先显示上一份快照（不转圈），等切页平推（380ms）播完再拉——以前离开时把快照作废、切回来先转圈，
    // 数据一到整张列表正好在平推中间建出来，切到动态页那一下明显顿一下
    ref.listenManual(meowTabProvider, (prev, next) {
      if (next == MeowTab.connections) {
        Future<void>.delayed(const Duration(milliseconds: 400), () => unawaited(_poll()));
      }
    });
    ref.listenManual(isRunningProvider, (prev, next) {
      _loaded = false;
      // 「已关闭」随之清空（见 _closedConnsProvider）；手上的旧快照不能拿来和新内核的比
      _polledAt = null;
      _polled.fire();
      if (next) unawaited(_poll());
    });
    // 内核重启：连接 id 全换了，旧快照里的不是「关闭了」
    ref.listenManual(isRestartingCoreProvider, (prev, next) {
      _polledAt = null;
      _polled.fire();
    });
    // 拨号失败记在壳上（见 dial_failures.dart）：来了新的，「已关闭」那份跟着刷
    ref.listenManual(dialFailuresProvider, (prev, next) {
      if (_closedMode) _polled.fire();
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(_poll()));
  }

  @override
  void dispose() {
    _timer?.cancel();
    globalState.backgroundMode.removeListener(_onBackgroundChanged);
    _search.dispose();
    _sheetConn.dispose();
    _polled.dispose();
    super.dispose();
  }

  bool get _visible => ref.read(meowTabProvider) == MeowTab.connections;

  void _onBackgroundChanged() {
    if (!globalState.backgroundMode.value) unawaited(_poll());
  }

  void _clearConns() {
    if (_conns.isEmpty) return;
    _conns = const [];
    _polled.fire();
  }

  Future<void> _poll() async {
    if (!mounted || _polling) return;
    if (!ref.read(isRunningProvider)) {
      _clearConns();
      return;
    }
    if (!_visible) {
      // 被别的 Tab 盖着：不拉，旧快照留着——切回来那一帧不重建列表（平推动画中间不建几十行），播完再拉新的。
      // 隔了很久的字节差不是「每秒」，回来的第一拍速率记 0
      _polledAt = null;
      return;
    }
    // App 退到后台 / 窗口收进托盘（见 connPollingPaused）：没有画面在用，不拉。
    // 旧快照留着，回来第一眼不是空的；隔了很久的字节差不是「每秒」，回来的第一拍速率记 0
    if (connPollingPaused(
      background: globalState.backgroundMode.value,
      desktop: system.isDesktop,
      lifecycle: WidgetsBinding.instance.lifecycleState,
    )) {
      _polledAt = null;
      return;
    }
    _polling = true;
    try {
      // 经壳的 ConnStatsController 取：这份快照顺手更新连接计数，壳这段时间不再另拉一次
      final list = await (widget.fetch ?? ref.read(connStatsProvider.notifier).fetchConnections)();
      if (!mounted) return;
      final now = DateTime.now();
      final ms = _polledAt == null ? 0 : now.difference(_polledAt!).inMilliseconds;
      // 上一轮有、这一轮没有 = 关闭了。中间隔了一段没拉（切到别的 Tab、退到后台、刚连上 / 内核重启）时，
      // 不知道是什么时候关的，只拿这一份当新的基准
      if (_polledAt != null && !ref.read(isRestartingCoreProvider)) _closed.recordDiff(_conns, list, now);
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
      _conns = next;
      _loaded = true;
      _polled.fire();
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

  static List<TrackerInfo> _filter(List<TrackerInfo> conns, String query) {
    final q = query.toLowerCase();
    return conns.where((c) {
      return c.metadata.host.toLowerCase().contains(q) ||
          c.metadata.sniffHost.toLowerCase().contains(q) ||
          c.metadata.destinationIP.contains(q) ||
          c.chains.any((s) => s.toLowerCase().contains(q)) ||
          c.rule.toLowerCase().contains(q) ||
          c.rulePayload.toLowerCase().contains(q) ||
          _inboundOf(c).toLowerCase().contains(q);
    }).toList();
  }

  /// 要显示的列表与汇总。[filtered] = 按搜索词筛（「日志」分段的搜索词不作用于连接）。
  /// 每条连接要做五六次 toLowerCase，快照或搜索词变了才重算；选中一行、布局变化之类的重建直接用上一份。
  /// 「已关闭」时列表换成最近关闭的那几条（新的在前），同样按搜索词筛。
  ({List<TrackerInfo> items, _Sum sum}) _view(bool filtered) {
    final query = filtered ? _query : '';
    final kind = filtered ? _kind : ActivityKind.all;
    final source = kind == ActivityKind.closed ? _closedSource : _conns;
    if (!identical(_viewOf, source) || _viewQuery != query || _viewKind != kind) {
      _viewOf = source;
      _viewQuery = query;
      _viewKind = kind;
      final byQuery = query.isEmpty ? source : _filter(source, query);
      _viewItems = kind == ActivityKind.all || kind == ActivityKind.closed
          ? byQuery
          : byQuery.where((c) => connectionKinds(c).contains(kind)).toList();
      _viewSum = _Sum.of(_viewItems);
    }
    return (items: _viewItems, sum: _viewSum);
  }

  void _clearQuery() {
    _search.clear();
    setState(() => _query = '');
  }

  void _switchSeg(_Seg v) {
    if (v == _seg) return;
    _search.clear();
    setState(() {
      _seg = v;
      _query = '';
    });
  }

  /// 手动关的也进「已关闭」：它马上从 [_conns] 里拿掉，下一轮比快照时就比不出来了
  void _close(String id) {
    clashCore.closeConnection(id);
    setState(() {
      _closed.add(_conns.where((c) => c.id == id), DateTime.now());
      _conns = _conns.where((c) => c.id != id).toList();
      if (_selectedId == id) _selectedId = null;
    });
  }

  void _closeAll() {
    clashCore.closeConnections();
    setState(() {
      _closed.add(_conns, DateTime.now());
      _conns = const [];
    });
  }

  /// 窄屏没有右栏：详情放进底部弹层，内容随轮询刷新。[closedAt] 不为空 = 已关闭的连接（不刷新、没有关闭按钮）。
  Future<void> _openSheet(TrackerInfo c, {DateTime? closedAt}) async {
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
                  _ConnDetail(c: live, closedAt: closedAt),
                  const SizedBox(height: 14),
                  if (closedAt != null)
                    const _EndedNote()
                  else
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
    final visible = ref.watch(meowTabProvider.select((t) => t == MeowTab.connections));
    final onConns = _seg == _Seg.connections;

    // 分段上带条数：轮询到的条数变了才重建分段
    final segment = _Selected<String>(
      listenable: _polled,
      select: () => running && _loaded ? '连接 · ${_conns.length}' : '连接',
      builder: (context, label) => M3ButtonGroup<_Seg>(
        items: [(_Seg.connections, label), (_Seg.logs, '日志')],
        selected: _seg,
        onChanged: _switchSeg,
        height: twoPane ? 40 : 48,
      ),
    );
    final search = _SearchField(
      controller: _search,
      hint: onConns ? '搜索域名 / 目标 / 规则' : '搜索日志',
      onChanged: (v) => setState(() => _query = v.trim()),
      height: 40,
      fontSize: 13,
      onClear: _clearQuery,
    );
    // 「已关闭」没有可关的，不放「全部关闭」
    final Widget? rowAction = onConns && _closedMode
        ? null
        : onConns
        ? _Selected<bool>(
            listenable: _polled,
            select: () => _conns.isEmpty,
            builder: (context, empty) => _PillButton(label: '全部关闭', color: mm.slow, onTap: empty ? null : _closeAll),
          )
        : _PillButton(label: '清空', color: mm.slow, onTap: () => ref.read(logsProvider.notifier).clearLogs());
    final kindFilter = _KindFilter(value: _kind, compact: twoPane, onChanged: (k) => setState(() => _kind = k));
    final emptyText = _query.isNotEmpty
        ? '无匹配连接'
        : switch (_kind) {
            ActivityKind.all => '暂无活动连接',
            ActivityKind.closed => '暂无已关闭的连接',
            _ => '无匹配连接',
          };
    // 日志不认「已关闭」，按「全部」
    final logKind = _closedMode ? ActivityKind.all : _kind;
    DateTime? closedAtOf(TrackerInfo c) => _closedMode ? _endedAt[c.id] : null;
    // 等第一份快照。本页被别的 Tab 盖着时（IndexedStack 里还挂着）不画转圈：隐藏页里的动画照样逼着整个 App 每个 vsync 出一帧
    final Widget loading = visible ? const _Loading() : const SizedBox.shrink();

    if (!twoPane) {
      // 手机：悬浮底栏盖在内容上，列表底部让出它的高度；平板竖屏 / 窄窗口有侧栏，底边留白在外层
      final bottom = (wide ? 0.0 : 16.0) + MediaQuery.paddingOf(context).bottom;
      final Widget body;
      if (!onConns) {
        body = _LogList(query: _query, kind: logKind, bottomPadding: bottom);
      } else if (!running) {
        body = const _Empty(icon: Icons.power_off_rounded, text: S.tunnelNotConnected);
      } else {
        // 跟着轮询重建的只有这一块（外加标题里的累计、分段上的条数）
        body = ListenableBuilder(
          listenable: _polled,
          builder: (context, _) {
            if (!_loaded) return loading;
            final (:items, sum: _) = _view(true);
            if (items.isEmpty) return _Empty(icon: Icons.inbox_rounded, text: emptyText);
            // 分段清单（画布稿）：一条连接一行，左滑关闭
            return ListView.builder(
              padding: EdgeInsets.only(bottom: bottom),
              itemCount: items.length,
              itemBuilder: (_, i) {
                final closedAt = closedAtOf(items[i]);
                return Padding(
                  padding: EdgeInsets.only(top: i == 0 ? 0 : 3),
                  child: M3SegmentSlot(
                    index: i,
                    count: items.length,
                    child: _ConnRow(
                      key: ValueKey(items[i].id),
                      c: items[i],
                      closedAt: closedAt,
                      failure: _closedMode ? _failureById[items[i].id] : null,
                      onTap: () => unawaited(_openSheet(items[i], closedAt: closedAt)),
                      onClose: () => _close(items[i].id),
                    ),
                  ),
                );
              },
            );
          },
        );
      }
      return Padding(
        padding: wide ? widePagePadding() : const EdgeInsets.symmetric(horizontal: 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            PageTitle(
              MeowTab.connections.label,
              // 标题下面一行：当前列表累计下行 / 上行
              subtitle: running
                  ? ListenableBuilder(
                      listenable: _polled,
                      builder: (context, _) {
                        final sum = _view(onConns).sum;
                        return _Totals(up: sum.up, down: sum.down);
                      },
                    )
                  : null,
            ),
            const SizedBox(height: 14),
            segment,
            // 搜索框常驻，「全部关闭」/「清空」是它旁边的胶囊（同 iOS，2026-11-18；以前搜索收在标题行圆钮后面、全部关闭是标题行的 ✕）
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: _SearchField(
                    controller: _search,
                    hint: onConns ? '搜索域名 / 目标 / 规则' : '搜索日志',
                    onChanged: (v) => setState(() => _query = v.trim()),
                    height: 44,
                    fontSize: 15,
                    onClear: _clearQuery,
                  ),
                ),
                if (rowAction != null) ...[const SizedBox(width: 8), rowAction],
              ],
            ),
            const SizedBox(height: 12),
            kindFilter,
            const SizedBox(height: 14),
            Expanded(child: body),
          ],
        ),
      );
    }

    final Widget body;
    if (!onConns) {
      body = _LogList(query: _query, kind: logKind, bottomPadding: 0);
    } else if (!running) {
      body = const _Empty(icon: Icons.power_off_rounded, text: S.tunnelNotConnected);
    } else {
      body = ListenableBuilder(
        listenable: _polled,
        builder: (context, _) {
          if (!_loaded) return loading;
          final (:items, :sum) = _view(true);
          final selected = (_closedMode ? _closedSource : _conns).firstWhereOrNull((c) => c.id == _selectedId);
          final selectedClosedAt = selected == null ? null : closedAtOf(selected);
          return Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  child: _ConnTable(
                    items: items,
                    selectedId: _selectedId,
                    emptyText: emptyText,
                    closedAtOf: _closedMode ? closedAtOf : null,
                    failureOf: _closedMode ? (c) => _failureById[c.id] : null,
                    // 再点一次选中的行 = 取消选中，右栏回到汇总
                    onSelect: (id) => setState(() => _selectedId = _selectedId == id ? null : id),
                  ),
                ),
                const SizedBox(width: 14),
                SizedBox(
                  width: 268,
                  child: selected == null
                      ? _SummaryPane(
                          label: _closedMode ? '已关闭' : '活动连接',
                          summary: '${items.length} 条 · 代理 ${sum.proxied} · 直连 ${sum.direct}',
                          sum: sum,
                        )
                      : Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Expanded(child: SingleChildScrollView(child: _ConnDetail(c: selected, closedAt: selectedClosedAt))),
                            const SizedBox(height: 10),
                            if (selectedClosedAt != null)
                              const _EndedNote()
                            else
                              _CloseConnButton(onTap: () => _close(selected.id)),
                          ],
                        ),
                ),
              ],
            ),
          );
        },
      );
    }
    return Padding(
      padding: widePagePadding(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // 标题行：标题 + 分段 + 搜索 + 本页操作。Windows 的窗口按钮并在这一行最右边（见 window_controls.dart）：
          // 让出它们的位置、整行可拖动窗口；上边距 8 让 40 高的这一行与窗口按钮居中对齐（同 PageTitle 的第一行）
          WindowDragArea(
            child: Padding(
              padding: EdgeInsets.only(top: 8, right: windowControlsShown ? windowControlsReserve : 0),
              child: Row(
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
                  if (rowAction != null) ...[const SizedBox(width: 8), rowAction],
                ],
              ),
            ),
          ),
          const SizedBox(height: 8),
          kindFilter,
          const SizedBox(height: 4),
          Expanded(child: body),
        ],
      ),
    );
  }
}

/// 只当信号用的 Listenable：数据放在页面的字段里，改完敲一下。
class _Signal extends ChangeNotifier {
  void fire() => notifyListeners();
}

/// 跟着 [listenable] 重新取值，取到的值和上次 build 用的不一样才重建。
/// （轮询每 1.5s 敲一次，分段上的条数、「全部关闭」可不可点多半没变。）
class _Selected<T> extends StatefulWidget {
  const _Selected({required this.listenable, required this.select, required this.builder});
  final Listenable listenable;
  final T Function() select;
  final Widget Function(BuildContext context, T value) builder;

  @override
  State<_Selected<T>> createState() => _SelectedState<T>();
}

class _SelectedState<T> extends State<_Selected<T>> {
  /// 上一次 build 用的值
  late T _built;

  @override
  void initState() {
    super.initState();
    widget.listenable.addListener(_check);
  }

  @override
  void didUpdateWidget(_Selected<T> oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.listenable, widget.listenable)) {
      oldWidget.listenable.removeListener(_check);
      widget.listenable.addListener(_check);
    }
  }

  @override
  void dispose() {
    widget.listenable.removeListener(_check);
    super.dispose();
  }

  void _check() {
    if (widget.select() != _built) setState(() {});
  }

  @override
  Widget build(BuildContext context) => widget.builder(context, _built = widget.select());
}

/// 行首标签与数字列（速率 / 时长）最多跟到 1.2 倍字号：定长的辅助信息，大字号时把宽度让给主机名。
TextScaler _auxScaler(BuildContext context) => MediaQuery.textScalerOf(context).clamp(maxScaleFactor: 1.2);

/// 装这些定长文字的定宽格子跟着同一个缩放比放大。
/// 按 [font] 这一档字号的实际缩放比算（Android 的非线性缩放各字号比例不同）。
double _auxWidth(BuildContext context, double width, {double font = 11}) =>
    width * _auxScaler(context).scale(font) / font;

/// 连接过规则用的域名（有嗅探域名用它，见 [connRuleHost]），没有域名为空
String _ruleHostOf(TrackerInfo c) => connRuleHost(host: c.metadata.host, sniffHost: c.metadata.sniffHost);

String _hostOf(TrackerInfo c) {
  final h = _ruleHostOf(c);
  return h.isNotEmpty ? h : c.metadata.destinationIP;
}
String _targetOf(TrackerInfo c) => c.chains.isEmpty ? '—' : c.chains.first;
String _ruleOf(TrackerInfo c) => ruleDisplay(c.rule, c.rulePayload);   // `GEOSITE,apple`（同 iOS / 配置文件的写法）
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

/// 当前列表累计「↓ 下载 · ↑ 上传」（下载在前，三端统一）（手机在标题下面一行，两栏在汇总栏里）。
class _Totals extends StatelessWidget {
  const _Totals({required this.up, required this.down});
  final int up, down;

  @override
  Widget build(BuildContext context) => Text(
    '↓ ${fmtSize(down)} · ↑ ${fmtSize(up)}',
    maxLines: 1,
    overflow: TextOverflow.ellipsis,
    style: TextStyle(
      fontSize: MeowFont.footnote,
      color: context.cs.onSurfaceVariant,
      fontFeatures: const [FontFeature.tabularFigures()],
    ),
  );
}

/// 搜索框：卡片底胶囊。
class _SearchField extends StatelessWidget {
  const _SearchField({
    required this.controller,
    required this.hint,
    required this.onChanged,
    required this.height,
    required this.fontSize,
    this.onClear,
  });
  final TextEditingController controller;
  final String hint;
  final ValueChanged<String> onChanged;
  final double height, fontSize;

  /// 有搜索词时行尾的清空钮
  final VoidCallback? onClear;

  @override
  Widget build(BuildContext context) {
    final cs = context.cs;
    return Container(
      constraints: BoxConstraints(minHeight: height),
      padding: const EdgeInsets.symmetric(horizontal: 16),
      decoration: BoxDecoration(color: cs.surfaceContainerHigh, borderRadius: BorderRadius.circular(height / 2)),
      child: Row(
        children: [
          Icon(Icons.search_rounded, size: 22, color: cs.onSurfaceVariant),
          const SizedBox(width: 10),
          Expanded(
            child: TextField(
              controller: controller,
              onChanged: onChanged,
              textInputAction: TextInputAction.search,
              cursorColor: cs.primary,
              style: TextStyle(fontSize: fontSize, color: cs.onSurface),
              decoration: InputDecoration(
                isCollapsed: true,
                filled: false,
                border: InputBorder.none,
                enabledBorder: InputBorder.none,
                focusedBorder: InputBorder.none,
                hintText: hint,
                hintMaxLines: 1,
                hintStyle: TextStyle(fontSize: fontSize, color: cs.onSurfaceVariant),
              ),
            ),
          ),
          if (onClear != null && controller.text.isNotEmpty)
            IconButton(
              tooltip: '清空搜索',
              visualDensity: VisualDensity.compact,
              onPressed: onClear,
              icon: Icon(Icons.close_rounded, size: 20, color: cs.onSurfaceVariant),
            ),
        ],
      ),
    );
  }
}

/// 搜索行右侧的胶囊按钮（卡片底 + 彩色字）：全部关闭 / 清空。
class _PillButton extends StatelessWidget {
  const _PillButton({required this.label, required this.color, required this.onTap});
  final String label;
  final Color color;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: onTap == null ? 0.4 : 1,
      child: MeowCardMaterial(
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
    const r = Radius.circular(MeowShape.xl);
    return Container(
      padding: EdgeInsets.fromLTRB(12, first ? edge + 6 : 0, 12, last ? edge + 6 : 0),
      decoration: BoxDecoration(
        color: context.cs.card,
        borderRadius: BorderRadius.vertical(top: first ? r : Radius.zero, bottom: last ? r : Radius.zero),
      ),
      child: child,
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

/// 行首的类型块：推送 / DNS / 拒绝 / 代理 / 直连，各一种色调容器和形状（画布稿 Activity）。
(String, Color, Color, M3TileShape) _kindTile(TrackerInfo c, ColorScheme cs) {
  final kinds = connectionKinds(c);
  final leaf = c.chains.firstOrNull ?? '';
  if (kinds.contains(ActivityKind.push)) return ('推送', cs.surfaceContainerHighest, cs.onSurface, M3TileShape.leafB);
  if (kinds.contains(ActivityKind.dns)) return ('DNS', cs.secondaryContainer, cs.onSecondaryContainer, M3TileShape.leafA);
  if (leaf.startsWith('REJECT')) return ('拒绝', cs.errorContainer, cs.onErrorContainer, M3TileShape.rounded);
  if (kinds.contains(ActivityKind.proxy)) return ('代理', cs.primaryContainer, cs.onPrimaryContainer, M3TileShape.rounded);
  return ('直连', cs.tertiaryContainer, cs.onTertiaryContainer, M3TileShape.circle);
}

/// 窄屏连接行（照 iOS，2026-11-18）：类型块 + 主机:端口 / 出站（叶子节点）· 规则 / 「↓ ↑ 累计 · 时长」，行尾 ✕ 关闭（左滑也能关）；
/// 点了看详情。已关闭的（[closedAt] 不为空）末行写用时与关闭时刻，没有 ✕、不能滑。
class _ConnRow extends StatelessWidget {
  const _ConnRow({super.key, required this.c, required this.onTap, required this.onClose, this.closedAt, this.failure});
  final TrackerInfo c;
  final VoidCallback onTap, onClose;
  final DateTime? closedAt;

  /// 拨号失败的记录：没有流量，末行换成红色「失败：原因 ×N · 时刻」（同 iOS）
  final DialFailure? failure;

  @override
  Widget build(BuildContext context) {
    final cs = context.cs;
    final aux = _auxScaler(context);
    final (label, bg, fg, shape) = _kindTile(c, cs);
    // 下载在前（三端统一）；时长每轮快照（1.5s）跟着重建
    final bytes = '↓ ${fmtSize(c.download)}  ↑ ${fmtSize(c.upload)}';
    final tail = closedAt == null
        ? _age(c.start)
        : '用时 ${fmtClosedDuration(ClosedConnection(c, closedAt!).duration)} · ${fmtClockTime(closedAt!)}';
    final f = failure;
    final footer = f != null
        ? '失败：${f.reason}${f.count > 1 ? ' ×${f.count}' : ''} · ${fmtClockTime(f.at)}'
        : '$bytes · $tail';
    final row = M3ListRow(
      title: '${_hostOf(c)}:${c.metadata.destinationPort}',
      titleSize: 15,
      // mihomo 的 chains 是「叶子 → … → 规则选中的策略」：写叶子节点（实际出去的那个，同 iOS）
      subtitle: '${_targetOf(c)} · ${_subOf(c)}',
      subtitleMaxLines: 1,
      footer: Text(
        footer,
        maxLines: f != null ? 2 : 1,   // 失败原因常常很长：给两行，别把次数和时刻截掉
        overflow: TextOverflow.ellipsis,
        textScaler: aux,
        style: TextStyle(
          fontSize: 11,
          color: f != null ? cs.error : cs.onSurfaceVariant,
          fontWeight: f != null ? FontWeight.w600 : null,
          fontFeatures: const [FontFeature.tabularFigures()],
        ),
      ),
      onTap: onTap,
      padding: EdgeInsets.fromLTRB(14, 12, closedAt == null ? 4 : 14, 12),
      leading: M3IconTile(
        text: label,
        shape: shape,
        bg: bg,
        fg: fg,
        child: Text(
          label,
          maxLines: 1,
          textScaler: aux,
          style: TextStyle(fontSize: 11, fontWeight: FontWeight.w800, color: fg),
        ),
      ),
      trailing: closedAt != null
          ? null
          : IconButton(
              icon: const Icon(Icons.close_rounded, size: 20),
              color: cs.onSurfaceVariant,
              tooltip: '关闭连接',
              onPressed: onClose,
            ),
    );
    if (closedAt != null) return row;
    return Dismissible(
      key: ValueKey('dismiss:${c.id}'),
      direction: DismissDirection.endToStart,
      onDismissed: (_) => onClose(),
      background: Container(
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 24),
        decoration: BoxDecoration(color: cs.errorContainer, borderRadius: BorderRadius.circular(M3ListRow.outer)),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.close_rounded, color: cs.onErrorContainer),
            const SizedBox(width: 6),
            Text('关闭', style: TextStyle(fontWeight: FontWeight.w700, color: cs.onErrorContainer)),
          ],
        ),
      ),
      child: row,
    );
  }
}

/// 类型筛选胶囊（全部 / 推送 / DNS / 直连 / 代理）：选中 = 柔粉底玫红字，其余白底（同 iOS 的 MeowPill .soft / .card）。
/// 液态玻璃主题下是按钮那档静态半透明 + 细亮边（见 button_fill.dart），不是一颗颗磨砂卡片——选中的那颗以前叠的淡粉是不透明的，等于实色块。
class _KindFilter extends StatelessWidget {
  const _KindFilter({required this.value, required this.onChanged, this.compact = false});
  final ActivityKind value;
  final ValueChanged<ActivityKind> onChanged;
  final bool compact;

  @override
  Widget build(BuildContext context) => SingleChildScrollView(
    scrollDirection: Axis.horizontal,
    child: Row(
      children: [
        for (final (i, k) in ActivityKind.values.indexed) ...[
          if (i > 0) const SizedBox(width: 6),
          M3FilterChip(
            label: k.label,
            selected: k == value,
            height: compact ? 32 : 36,
            onTap: k == value ? null : () => onChanged(k),
          ),
        ],
      ],
    ),
  );
}

/// 两栏连接表：一张撑满高度的卡片，表头固定、行懒加载；选中行柔粉底。
/// 「出站」列与「主机」列按 2:3 分剩余宽度（设计稿 1100 宽时出站 ≈ 128），窗口窄 / 字号大时一起收窄。
/// 已关闭的（[closedAtOf] 不为空）后两列换成「关闭于」（HH:mm:ss）与「用时」。
class _ConnTable extends StatelessWidget {
  const _ConnTable({
    required this.items,
    required this.selectedId,
    required this.emptyText,
    required this.onSelect,
    this.closedAtOf,
    this.failureOf,
  });
  final List<TrackerInfo> items;
  final String? selectedId;
  final String emptyText;
  final ValueChanged<String> onSelect;
  final DateTime? Function(TrackerInfo c)? closedAtOf;
  final DialFailure? Function(TrackerInfo c)? failureOf;

  @override
  Widget build(BuildContext context) {
    final mm = context.mm;
    final head = TextStyle(fontSize: MeowFont.caption2, fontWeight: FontWeight.w600, color: mm.t2);
    final tagW = _auxWidth(context, isDesktopUi ? 46 : 34, font: 10);
    final rateW = _auxWidth(context, 70);
    final ageW = _auxWidth(context, 52);
    Widget cell(String s, {TextAlign align = TextAlign.start}) =>
        Text(s, maxLines: 1, overflow: TextOverflow.ellipsis, textAlign: align, style: head);
    return MeowCard(
      padding: const EdgeInsets.fromLTRB(6, 4, 6, 4),
      clipBehavior: Clip.antiAlias,
      radius: BorderRadius.circular(22),
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
                  SizedBox(width: rateW, child: cell(closedAtOf == null ? '↓ 累计' : '关闭于', align: TextAlign.end)),
                  const SizedBox(width: 10),
                  SizedBox(width: ageW, child: cell(closedAtOf == null ? '时长' : '用时', align: TextAlign.end)),
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
                      closedAt: closedAtOf?.call(items[i]),
                      failure: failureOf?.call(items[i]),
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
    this.closedAt,
    this.failure,
  });
  final TrackerInfo c;
  final DateTime? closedAt;
  final DialFailure? failure;
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
                if (failure case final f?) ...[
                  fit(fmtClockTime(f.at), rateWidth),
                  const SizedBox(width: 10),
                  SizedBox(
                    width: ageWidth,
                    child: Tooltip(
                      message: f.reason,
                      child: Text(
                        f.count > 1 ? '失败×${f.count}' : '失败',
                        maxLines: 1,
                        textAlign: TextAlign.end,
                        overflow: TextOverflow.ellipsis,
                        textScaler: aux,
                        style: num.copyWith(color: context.cs.error, fontWeight: FontWeight.w700),
                      ),
                    ),
                  ),
                ] else if (closedAt case final at?) ...[
                  fit(fmtClockTime(at), rateWidth),
                  const SizedBox(width: 10),
                  fit(fmtClosedDuration(ClosedConnection(c, at).duration), ageWidth),
                ] else ...[
                  fit(fmtSize(c.download), rateWidth),   // 累计下载（同 iOS 连接表）
                  const SizedBox(width: 10),
                  fit(_age(c.start), ageWidth),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 详情里的小卡片：小字标题 + 值。[hero] = 樱粉主卡（液态玻璃主题下和其它卡片一样，全部卡片一致）。
class _InfoCard extends StatelessWidget {
  const _InfoCard({required this.label, required this.value, this.hero = false, this.mono = false});
  final String label, value;
  final bool hero, mono;

  @override
  Widget build(BuildContext context) {
    final cs = context.cs;
    final fg = hero ? cs.onPrimaryContainer : cs.onSurface;
    return M3Card(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
      radius: hero ? MeowShape.xl : MeowShape.lInc + 4,
      color: hero ? cs.primaryContainer : null,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: TextStyle(fontSize: MeowFont.caption, fontWeight: FontWeight.w600, color: fg.withValues(alpha: 0.8)),
          ),
          const SizedBox(height: 4),
          Text(
            value,
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            style: mono
                ? MeowFont.mono(size: MeowFont.subheadline, weight: FontWeight.w600, color: fg)
                : TextStyle(fontSize: hero ? 17 : 15, fontWeight: FontWeight.w800, color: fg),
          ),
        ],
      ),
    );
  }
}

/// 下载 / 上传两格（下载在前）：小字标题 + 大数字。
class _StatPair extends StatelessWidget {
  const _StatPair({required this.up, required this.down});
  final int up, down;

  @override
  Widget build(BuildContext context) {
    final cs = context.cs;
    // 上传第三色、下载主色（同首页网速卡）
    Widget cell(String label, int bytes, Color tint, IconData icon) => Expanded(
      child: M3Card(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        radius: MeowShape.lInc + 4,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, size: 16, color: tint),
                const SizedBox(width: 4),
                Text(label, style: TextStyle(fontSize: MeowFont.caption, fontWeight: FontWeight.w600, color: tint)),
              ],
            ),
            const SizedBox(height: 2),
            Text(
              fmtSize(bytes),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.w800,
                color: cs.onSurface,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ],
        ),
      ),
    );
    return Row(
      children: [
        cell(S.download, down, cs.primary, Icons.arrow_downward_rounded),
        const SizedBox(width: 10),
        cell(S.upload, up, cs.tertiary, Icons.arrow_upward_rounded),
      ],
    );
  }
}

/// 连接详情：出站链路（主卡）/ 命中规则 / 上传 · 下载 / 网络 · 入站 · 主机 · 目标 IP · 已持续 / 这个域名走（自定义规则）。
/// 宽屏放右栏，窄屏放底部弹层；「关闭这条连接」由外层另放。已关闭的（[closedAt] 不为空）「已持续」换成用时与关闭时刻。
class _ConnDetail extends StatelessWidget {
  const _ConnDetail({required this.c, this.closedAt});
  final TrackerInfo c;
  final DateTime? closedAt;

  @override
  Widget build(BuildContext context) {
    final mm = context.mm;
    final inbound = _inboundOf(c);
    final facts = <(String, String)>[
      ('网络', c.metadata.network.toUpperCase()),
      if (inbound.isNotEmpty) ('入站', '$inbound${c.metadata.inboundName.isEmpty ? '' : ' · ${c.metadata.inboundName}'}'),
      ('主机', '${_hostOf(c)}:${c.metadata.destinationPort}'),
      // 嗅探到的域名与 DNS 映射的域名不同时两个都列出来：规则按前者（主机）匹配
      if (c.metadata.sniffHost.isNotEmpty && c.metadata.host.isNotEmpty && c.metadata.host != c.metadata.sniffHost)
        ('DNS 映射', c.metadata.host),
      if (c.metadata.destinationIP.isNotEmpty && _ruleHostOf(c).isNotEmpty) ('目标 IP', c.metadata.destinationIP),
      if (closedAt case final at?) ...[
        ('用时', fmtClosedDuration(ClosedConnection(c, at).duration)),
        ('关闭于', fmtClockTime(at)),
      ] else
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
        // 分段清单的样子：各行之间 3 的间隔（页面底色、内角小圆角）
        Material(
          color: context.cs.card,
          borderRadius: BorderRadius.circular(MeowShape.lInc + 4),
          clipBehavior: Clip.antiAlias,
          child: Column(
            children: [
              for (final (i, f) in facts.indexed) ...[
                if (i > 0) const MeSegmentGap(),
                Container(
                  constraints: const BoxConstraints(minHeight: 44),
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  child: Row(
                    children: [
                      Text(f.$1, style: TextStyle(fontSize: MeowFont.footnote, fontWeight: FontWeight.w600, color: mm.t2)),
                      const SizedBox(width: 8),
                      // 值拿键之外的全部宽度、右对齐
                      Expanded(
                        child: Text(
                          f.$2,
                          textAlign: TextAlign.end,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: MeowFont.mono(size: MeowFont.footnote, color: mm.t1),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 10),
        // 按连接区分：换选中的连接时「仅此域名 / 含子域名」重新按那条连接定
        ConnRuleCard(key: ValueKey(c.id), host: _ruleHostOf(c), ip: c.metadata.destinationIP),
      ],
    );
  }
}

class _CloseConnButton extends StatelessWidget {
  const _CloseConnButton({required this.onTap});
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    // 危险操作：error 容器的整颗胶囊
    final cs = context.cs;
    return Material(
      color: cs.errorContainer,
      shape: const StadiumBorder(),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Container(
          constraints: const BoxConstraints(minHeight: 52),
          alignment: Alignment.center,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.close_rounded, size: 20, color: cs.onErrorContainer),
              const SizedBox(width: 6),
              Text('关闭这条连接', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: cs.onErrorContainer)),
            ],
          ),
        ),
      ),
    );
  }
}

/// 已关闭的连接详情下方，代替「关闭这条连接」。
class _EndedNote extends StatelessWidget {
  const _EndedNote();

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(minHeight: 44),
      alignment: Alignment.center,
      child: Text('已结束', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: context.mm.t2)),
    );
  }
}

/// 两栏右栏、没选连接时：当前列表的汇总（条数 / 累计上下行），选一行换成该连接的详情。
class _SummaryPane extends StatelessWidget {
  const _SummaryPane({required this.label, required this.summary, required this.sum});
  final String label, summary;
  final _Sum sum;

  @override
  Widget build(BuildContext context) {
    final mm = context.mm;
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _InfoCard(label: label, value: summary, hero: true),
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

/// 日志：汇总行（状态 + 清空）+ 一张卡片里的日志行（级别点 + 时间 HH:mm:ss + 消息，等宽）；默认关；没被用户翻上去就自动跟到底。
class _LogList extends ConsumerStatefulWidget {
  const _LogList({required this.query, required this.kind, required this.bottomPadding});
  final String query;
  final ActivityKind kind;
  final double bottomPadding;

  @override
  ConsumerState<_LogList> createState() => _LogListState();
}

class _LogListState extends ConsumerState<_LogList> {
  static final _lower = Expando<String>();
  static final _kinds = Expando<Set<ActivityKind>>();

  /// 最多这么久刷新一次列表。日志密的时候（内核日志等级调到 info / debug，每条连接一行）逐条刷新等于每帧把整屏文字重排一遍。
  static const _refreshEvery = Duration(milliseconds: 250);

  /// 翻完停下时离底不到这么多（约一行）算回到了底
  static const _stickSlack = 40.0;

  final _scroll = ScrollController();

  /// 列表上显示的那一份；日志来了不直接重建，经 [_onLogs] 合并着刷
  List<Log> _all = const [];

  /// 来源筛选（全部 / MeowX / 引擎，同 iOS），只作用于日志
  LogSource _source = LogSource.all;

  /// 刚刷过：这段时间里再来的日志等它到点一起刷
  Timer? _cooldown;

  /// 有还没刷到列表上的日志（冷却期间来的，或本页不可见时来的）
  bool _stale = false;

  /// 跟着新日志贴底。只有用户自己翻离底部才置假、翻回底部再置真（见 [_onScroll]）——记成状态，不从滚动位置现推：
  /// 视口变矮（窗口拉矮、弹键盘、转屏）、内容变高也会让位置「离底」，那不是用户翻走的。
  bool _follow = true;

  /// [_toBottom] 正在改位置：这期间的滚动通知不是用户翻的
  bool _sticking = false;

  @override
  void initState() {
    super.initState();
    _all = ref.read(logsProvider).list;
    ref.listenManual(logsProvider, (prev, next) => _onLogs());
    // 本页被别的 Tab 盖着时不刷（见 _onLogs），切回来补上
    ref.listenManual(meowTabProvider, (prev, next) {
      if (next == MeowTab.connections && _stale) _onLogs();
    });
  }

  @override
  void didUpdateWidget(_LogList oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 清掉搜索词：筛出来的那几条翻到哪都不算数，回到日志的尾巴
    if (oldWidget.query.isNotEmpty && widget.query.isEmpty) _follow = true;
  }

  @override
  void dispose() {
    _cooldown?.cancel();
    _scroll.dispose();
    super.dispose();
  }

  void _onLogs() {
    _stale = true;
    // 别的 Tab 盖着（IndexedStack 里本页还挂着）：重建了也没人看
    if (ref.read(meowTabProvider) != MeowTab.connections) return;
    if (_cooldown != null) return;
    _stale = false;
    setState(() => _all = ref.read(logsProvider).list);
    _cooldown = Timer(_refreshEvery, () {
      _cooldown = null;
      if (mounted && _stale) _onLogs();
    });
  }

  /// 用户翻动列表：决定还跟不跟。
  bool _onScroll(ScrollNotification n) {
    if (_sticking) return false;
    if (n is UserScrollNotification) {
      // 手指 / 滚轮往旧日志方向一动就不跟，不等停下：日志密的时候刚拖出一点就会被下一次刷新拽回去
      if (n.direction == ScrollDirection.forward) _follow = false;
    } else if (n is ScrollEndNotification) {
      // 停下来（拖动、惯性、滚轮、拖滚动条、键盘都走到这）：看停在哪
      _follow = n.metrics.pixels >= n.metrics.maxScrollExtent - _stickSlack;
    }
    return false;
  }

  /// 视口尺寸或内容高度变了：还在跟就再对一次底。
  /// 行不等高，没排到末尾之前 maxScrollExtent 是估出来的，跳过去排完版才有准数——估小了、估大了（越界）都从这里对回来。
  bool _onMetrics(ScrollMetricsNotification n) {
    if (_follow && widget.query.isEmpty) _toBottom();
    return false;
  }

  /// 对到底。已经越过了底也直接对回来（jumpTo 会收掉越界回弹，不然要等回弹动画慢慢回来，这期间整屏是空的）。
  void _toBottom() {
    if (!mounted || !_scroll.hasClients) return;
    final pos = _scroll.position;
    if (!pos.hasContentDimensions || pos.pixels == pos.maxScrollExtent) return;
    _sticking = true;
    _scroll.jumpTo(pos.maxScrollExtent);
    _sticking = false;
  }

  static final _time = RegExp(r'\d{2}:\d{2}:\d{2}');

  @override
  Widget build(BuildContext context) {
    final all = _all;
    final q = widget.query.toLowerCase();
    final kind = widget.kind;
    final source = _source;
    // 列表每 250ms 重建一次：小写 payload 与类型按日志对象缓存，每行只算一次（以前每次重建对全部日志跑一遍正则）
    final logs = q.isEmpty && kind == ActivityKind.all && source == LogSource.all
        ? all
        : all
              .where((l) =>
                  logMatchesSource(l, source) &&
                  (q.isEmpty || (_lower[l] ??= l.payload.toLowerCase()).contains(q)) &&
                  (kind == ActivityKind.all || (_kinds[l] ??= logKinds(l.payload)).contains(kind)))
              .toList();
    final filtering = q.isNotEmpty || kind != ActivityKind.all || source != LogSource.all;
    // 「记录日志」关着也照样显示（警告 / 错误与 MeowX 的事件），开关只决定额外记不记分流与 DNS（同 iOS）
    // 列表不在（刚进来、清空了、搜不到）：回到跟随
    if (!_scroll.hasClients) _follow = true;
    // 还在跟才跟到底：往上翻着看旧日志时，不被新来的日志拽回去
    if (!filtering && _follow) WidgetsBinding.instance.addPostFrameCallback((_) => _toBottom());
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            for (final (i, s) in LogSource.values.indexed) ...[
              if (i > 0) const SizedBox(width: 6),
              M3FilterChip(
                label: s.label,
                selected: s == source,
                height: 32,
                onTap: s == source
                    ? null
                    : () => setState(() {
                        _source = s;
                        _follow = true;
                      }),
              ),
            ],
          ],
        ),
        const SizedBox(height: 10),
        Expanded(
          child: logs.isEmpty
              ? _Empty(icon: Icons.notes_rounded, text: filtering ? '无匹配日志' : '暂无日志')
              : NotificationListener<ScrollMetricsNotification>(
                  onNotification: _onMetrics,
                  child: NotificationListener<ScrollNotification>(
                    onNotification: _onScroll,
                    child: ListView.builder(
                      controller: _scroll,
                      padding: EdgeInsets.only(bottom: widget.bottomPadding),
                      itemCount: logs.length,
                      itemBuilder: (_, i) => _CardSlice(
                        first: i == 0,
                        last: i == logs.length - 1,
                        edge: 4,
                        child: _logRow(context, logs[i]),
                      ),
                    ),
                  ),
                ),
        ),
      ],
    );
  }

  Widget _logRow(BuildContext context, Log l) {
    final cs = context.cs, x = context.m3;
    // 级别小块（画布稿）：错误 = error 容器、警告 = warn 容器、DNS 模块的日志 = 次色容器、其余中性
    final (level, bg, fg) = switch (l.logLevel) {
      LogLevel.error => ('ERR', cs.errorContainer, cs.onErrorContainer),
      LogLevel.warning => ('WARN', x.warnContainer, x.onWarnContainer),
      _ when l.payload.contains('[DNS]') => ('DNS', cs.secondaryContainer, cs.onSecondaryContainer),
      LogLevel.debug => ('DBG', cs.surfaceContainerHighest, cs.onSurfaceVariant),
      _ => ('INFO', cs.surfaceContainerHighest, cs.onSurfaceVariant),
    };
    final t = _time.firstMatch(l.dateTime)?.group(0) ?? l.dateTime;
    final mono = MeowFont.mono(size: MeowFont.caption, color: cs.onSurface).copyWith(height: 17 / 12);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 7),
      // 时间、级别块、消息按基线对齐：任意字号下都不错位
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.baseline,
        textBaseline: TextBaseline.alphabetic,
        children: [
          Text(t, style: mono.copyWith(color: cs.onSurfaceVariant)),
          const SizedBox(width: 10),
          Text.rich(
            WidgetSpan(
              alignment: PlaceholderAlignment.middle,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 6),
                decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(MeowShape.xs + 2)),
                child: Text(level, style: mono.copyWith(color: fg, fontWeight: FontWeight.w600)),
              ),
            ),
            style: mono,
          ),
          const SizedBox(width: 10),
          Expanded(child: Text(logMessage(l), style: mono)),
        ],
      ),
    );
  }
}
