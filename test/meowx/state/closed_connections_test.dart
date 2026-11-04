import 'package:bett_box/meowx/state/closed_connections.dart';
import 'package:bett_box/models/models.dart';
import 'package:flutter_test/flutter_test.dart';

final _t0 = DateTime(2026, 11, 3, 14, 0, 0);

TrackerInfo _conn(String id, {int startSec = 0, String host = 'example.com', int up = 0}) => TrackerInfo(
  id: id,
  upload: up,
  download: 0,
  start: _t0.add(Duration(seconds: startSec)),
  metadata: Metadata(network: 'tcp', host: host, destinationIP: '198.51.100.1', destinationPort: '443'),
  chains: const ['DIRECT'],
  rule: 'Match',
  rulePayload: '',
);

List<String> _ids(ClosedConnections c) => [for (final x in c.items) x.info.id];

void main() {
  test('上一轮有、这一轮没有的入环，用上一轮那份数据，关闭时刻取这一轮', () {
    final closed = ClosedConnections();
    final prev = [_conn('a', up: 100), _conn('b'), _conn('c')];
    final now = _t0.add(const Duration(seconds: 30));
    expect(closed.recordDiff(prev, [_conn('b'), _conn('d')], now), 2);
    expect(_ids(closed).toSet(), {'a', 'c'});
    final a = closed.byId('a')!;
    expect(a.info.upload, 100);
    expect(a.closedAt, now);
    expect(a.duration, const Duration(seconds: 30));
    expect(closed.connections.map((c) => c.id).toSet(), {'a', 'c'});
    // 第一轮（没有上一轮）什么都不记
    expect(ClosedConnections().recordDiff(const [], [_conn('x')], now), 0);
  });

  test('新的在前；同一批里开始得晚的在前', () {
    final closed = ClosedConnections();
    closed.recordDiff([_conn('old')], const [], _t0.add(const Duration(seconds: 5)));
    closed.recordDiff([_conn('early', startSec: 1), _conn('late', startSec: 9)], const [], _t0.add(const Duration(seconds: 10)));
    expect(_ids(closed), ['late', 'early', 'old']);
  });

  test('最多保留 50 条，挤掉最旧的', () {
    final closed = ClosedConnections();
    for (var i = 0; i < 60; i++) {
      closed.add([_conn('$i')], _t0.add(Duration(seconds: i)));
    }
    expect(closed.items.length, ClosedConnections.capacity);
    expect(closed.items.first.info.id, '59');
    expect(closed.items.last.info.id, '10');
    // 一批就超过上限也只留 50 条
    final bulk = ClosedConnections()..add([for (var i = 0; i < 70; i++) _conn('b$i', startSec: i)], _t0);
    expect(bulk.items.length, 50);
    expect(bulk.items.first.info.id, 'b69');
  });

  test('同一 id 不重复记（手动关了之后下一轮又比出来）', () {
    final closed = ClosedConnections();
    final first = _t0.add(const Duration(seconds: 3));
    expect(closed.add([_conn('a')], first), 1);
    expect(closed.recordDiff([_conn('a'), _conn('b')], const [], _t0.add(const Duration(seconds: 6))), 1);
    expect(closed.add([_conn('a'), _conn('a')], _t0.add(const Duration(seconds: 9))), 0);
    expect(_ids(closed), ['b', 'a']);
    expect(closed.byId('a')!.closedAt, first);
  });

  test('有变化才换一份新列表；清空', () {
    final closed = ClosedConnections();
    final empty = closed.items;
    closed.recordDiff([_conn('a')], [_conn('a')], _t0);
    expect(closed.items, same(empty));
    closed.add([_conn('a')], _t0);
    final one = closed.items;
    expect(one, isNot(same(empty)));
    expect(() => one.add(ClosedConnection(_conn('z'), _t0)), throwsUnsupportedError);
    closed.clear();
    expect(closed.items, isEmpty);
    expect(closed.connections, isEmpty);
    expect(closed.byId('a'), isNull);
  });

  test('用时与关闭时刻的写法', () {
    expect(fmtClosedDuration(const Duration(seconds: 42)), '42 秒');
    expect(fmtClosedDuration(Duration.zero), '0 秒');
    expect(fmtClosedDuration(const Duration(seconds: -5)), '0 秒');
    expect(fmtClosedDuration(const Duration(minutes: 3, seconds: 5)), '3 分 5 秒');
    expect(fmtClosedDuration(const Duration(minutes: 59, seconds: 59)), '59 分 59 秒');
    expect(fmtClosedDuration(const Duration(hours: 1)), '1 小时 0 分');
    expect(fmtClosedDuration(const Duration(hours: 26, minutes: 7, seconds: 30)), '26 小时 7 分');
    expect(fmtClockTime(DateTime(2026, 11, 3, 9, 5, 7)), '09:05:07');
    // 关闭时刻早于开始（时钟回拨）记 0
    expect(ClosedConnection(_conn('a', startSec: 10), _t0).duration, Duration.zero);
  });
}
