import 'package:bett_box/models/models.dart';

/// 一条已关闭的连接：关闭前最后一次看到的那份快照 + 关闭时刻。
class ClosedConnection {
  const ClosedConnection(this.info, this.closedAt);
  final TrackerInfo info;
  final DateTime closedAt;

  /// 用时 = 关闭时刻 − 开始时间（时钟往回拨时记 0）
  Duration get duration {
    final d = closedAt.difference(info.start);
    return d.isNegative ? Duration.zero : d;
  }
}

/// 动态页「已关闭」：最近关闭的 [capacity] 条连接，新的在前。内核只给活动连接，关没关由客户端比两轮快照得出。
class ClosedConnections {
  static const capacity = 50;

  List<ClosedConnection> _items = const [];
  List<TrackerInfo> _infos = const [];

  /// 新的在前。每次有变化都换一份新列表（页面按 identical 判断要不要重算筛选）。
  List<ClosedConnection> get items => _items;

  /// 同 [items] 的连接本身，给沿用 TrackerInfo 的列表 / 筛选用
  List<TrackerInfo> get connections => _infos;

  ClosedConnection? byId(String id) {
    for (final c in _items) {
      if (c.info.id == id) return c;
    }
    return null;
  }

  /// 上一轮有、这一轮没有的就是关闭了：按上一轮看到的那份记下，关闭时刻 = [now]。返回新记进来的条数。
  int recordDiff(List<TrackerInfo> previous, List<TrackerInfo> current, DateTime now) {
    if (previous.isEmpty) return 0;
    final alive = {for (final c in current) c.id};
    return add(previous.where((c) => !alive.contains(c.id)), now);
  }

  /// 直接记一批关闭的连接（用户点「关闭」/「全部关闭」）。同一批里开始得晚的排前面；已记过的 id 不重复记。
  int add(Iterable<TrackerInfo> closed, DateTime now) {
    final known = {for (final c in _items) c.info.id};
    final fresh = <TrackerInfo>[];
    for (final c in closed) {
      if (known.add(c.id)) fresh.add(c);
    }
    if (fresh.isEmpty) return 0;
    fresh.sort((a, b) => b.start.compareTo(a.start));
    final next = [for (final c in fresh) ClosedConnection(c, now), ..._items];
    _set(next.length > capacity ? next.sublist(0, capacity) : next);
    return fresh.length;
  }

  void clear() {
    if (_items.isEmpty) return;
    _set(const []);
  }

  void _set(List<ClosedConnection> items) {
    _items = List.unmodifiable(items);
    _infos = List.unmodifiable([for (final c in items) c.info]);
  }
}

/// 已关闭连接的用时：不到 1 分钟按秒，不到 1 小时「m 分 s 秒」，再长「h 小时 m 分」。
String fmtClosedDuration(Duration d) {
  final s = d.isNegative ? 0 : d.inSeconds;
  if (s < 60) return '$s 秒';
  if (s < 3600) return '${s ~/ 60} 分 ${s % 60} 秒';
  return '${s ~/ 3600} 小时 ${s % 3600 ~/ 60} 分';
}

/// 关闭时刻 HH:mm:ss
String fmtClockTime(DateTime t) {
  String two(int n) => n.toString().padLeft(2, '0');
  return '${two(t.hour)}:${two(t.minute)}:${two(t.second)}';
}
