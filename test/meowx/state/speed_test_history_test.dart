import 'package:bett_box/enum/enum.dart';
import 'package:bett_box/meowx/pages/speedtest/speed_test_history_page.dart';
import 'package:bett_box/meowx/state/speed_test.dart';
import 'package:bett_box/meowx/theme/meow_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 测速记录（对齐 iOS 的 SpeedTestHistoryTests）：只记测完 / 失败的、上限 100 条、采样压到 40 点；汇总、筛选胶囊、按日分组。
void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  final now = DateTime(2026, 10, 18, 15, 30); // 固定时刻，按日分组不随跑的时间变

  SpeedTestRecord record(
    double hoursAgo,
    String outbound, {
    double? down,
    double? up,
    int? latency,
    String? error,
  }) => SpeedTestRecord(
    id: SpeedTestRecord.newId(),
    date: now.subtract(Duration(minutes: (hoursAgo * 60).round())),
    source: SpeedTestSource.cloudflare,
    connections: 8,
    outbound: outbound,
    latencyMs: latency,
    downloadMbps: down,
    uploadMbps: up,
    error: error,
  );

  SpeedTestRecord? fromPhase(SpeedTestProgress p) =>
      SpeedTestRecord.fromProgress(p, source: SpeedTestSource.google, connections: 1, outbound: kSpeedTestDirect);

  test('只有测完和失败生成记录；直连显示「直连」', () {
    expect(fromPhase(const SpeedTestProgress(phase: 'download')), isNull);
    expect(fromPhase(const SpeedTestProgress(phase: 'cancelled')), isNull);
    final done = fromPhase(SpeedTestProgress(phase: 'done', downloadMbps: 300, downloadSamples: List.filled(200, 300)))!;
    expect(done.isDirect, isTrue);
    expect(done.displayName, '直连');
    expect(done.failed, isFalse);
    expect(done.downloadSamples.length, SpeedTestHistory.maxSamples);
    expect(fromPhase(const SpeedTestProgress(phase: 'failed'))!.error, '未知原因');
    expect(speedTestDisplayName('香港 01'), '香港 01');
  });

  test('超过上限删最旧的，新的在前', () {
    final history = SpeedTestHistory(persist: false);
    for (var i = 0; i < SpeedTestHistory.limit + 5; i++) {
      history.add(record(-i.toDouble(), 'n$i'));
    }
    expect(history.records.length, SpeedTestHistory.limit);
    expect(history.records.first.outbound, 'n${SpeedTestHistory.limit + 4}');
    expect(history.records.last.outbound, 'n5');
    final id = history.records.first.id;
    history.delete(id);
    expect(history.records.any((r) => r.id == id), isFalse);
    history.clear();
    expect(history.records, isEmpty);
  });

  test('落盘后重新读出来一样（字段往返）', () async {
    final history = SpeedTestHistory();
    history.add(record(2, 'a', down: 10));
    final full = SpeedTestRecord(
      id: 'x1',
      date: now,
      source: SpeedTestSource.speedtest,
      connections: 8,
      outbound: kSpeedTestDirect,
      via: 'DIRECT',
      server: 'Hong Kong · 1010',
      latencyMs: 9,
      downloadMbps: 257.4,
      uploadMbps: 41.5,
      downloadPeakMbps: 286,
      uploadPeakMbps: 50,
      downloadSamples: const [1, 2.5],
      uploadSamples: const [3],
      bytesUsed: 123456,
    );
    history.add(full);
    await history.flush();
    final reloaded = SpeedTestHistory();
    await reloaded.load();
    expect(reloaded.records.map((r) => r.outbound), [kSpeedTestDirect, 'a']);
    final r = reloaded.records.first;
    expect(r.toJson(), full.toJson());
    expect(r.date, now);
    expect(r.error, isNull);
    // 坏数据不让整份读不出来：缺字段的条目跳过
    expect(SpeedTestRecord.fromJson(const {'id': 'y'}), isNull);
  });

  test('采样压缩：短的原样，长的分段取平均', () {
    expect(SpeedTestHistory.downsample([1, 2, 3]), [1, 2, 3]);
    expect(SpeedTestHistory.downsample([1, 3, 5, 7], 2), [2, 6]);
    final small = SpeedTestHistory.downsample([for (var i = 0; i < 123; i++) i.toDouble()]);
    expect(small.length, 40);
    expect(small.first, lessThan(small.last));
  });

  test('汇总：30 天内、失败不算最好成绩，走势按时间先后', () {
    final records = [
      record(1, 'a', down: 100, up: 10, latency: 50),
      record(2, kSpeedTestDirect, down: 300, up: 5, latency: 9),
      record(3, 'b', error: '超时'),
      record(4, 'b', down: 50, up: 30, latency: 80),
      record(24 * 40, 'old', down: 999, up: 999, latency: 1),
    ];
    final s = SpeedTestHistory.summary(records, now: now);
    expect(s.count, 4);
    expect(s.fastestDownload?.isDirect, isTrue);
    expect(s.fastestUpload?.outbound, 'b');
    expect(s.lowestLatency?.latencyMs, 9);
    expect(s.trend, [50, 300, 100]);
    expect(SpeedTestHistory.fastest(records), records[4].id);
  });

  test('筛选胶囊：直连在前（有才出现），节点按最近一次的先后、去重', () {
    final records = [record(1, 'b'), record(2, 'a'), record(3, 'b'), record(4, kSpeedTestDirect)];
    expect(SpeedTestHistory.filterOptions(records), [kSpeedTestDirect, 'b', 'a']);
    expect(SpeedTestHistory.filterOptions(records.take(3).toList()), ['b', 'a']);
    expect(SpeedTestHistory.filtered(records, 'b').length, 2);
    expect(SpeedTestHistory.filtered(records, null).length, 4);
  });

  test('按日分组：今天 / 昨天 / 月日 / 跨年带年份', () {
    final records = [
      record(0.1, 'a'),
      record(15.5 + 1, 'b'), // 昨天 23:00
      record(15.5 + 25, 'c'), // 前天
      record(24 * 400, 'd'), // 去年
    ];
    final groups = SpeedTestHistory.groupedByDay(records, now: now);
    expect(groups.map((g) => g.$1).take(2), ['今天', '昨天']);
    expect(groups.length, 4);
    expect(groups[2].$1, '10月16日');
    expect(groups[3].$1, contains('年'));
    expect(record(0, 'x').timeTitle, '15:30');
    expect(fmtRecordMbps(257.4), '257');
    expect(fmtRecordMbps(41.56), '41.6');
    expect(fmtRecordMbps(null), '–');
  });

  test('控制器：测完记一条，出站 / 线程数 / 测速源用发起时的参数；停止的不记', () async {
    final statuses = [
      '{"runID":1,"phase":"download","currentMbps":100}',
      '{"runID":1,"phase":"done","downloadMbps":120,"via":"DIRECT","downloadSamples":[1,2,3]}',
    ];
    final c = SpeedTestController(call: (method, data) async {
      if (method == ActionMethod.meowSpeedTestStatus) return statuses.removeAt(0);
      return '';
    });
    c.setSource(SpeedTestSource.apple);
    c.setMultiThread(true);
    await c.start(kSpeedTestDirect);
    expect(c.history.records.length, 1);
    final r = c.history.records.first;
    expect(r.outbound, kSpeedTestDirect);
    expect(r.connections, SpeedTestController.multiConnections);
    expect(r.source, SpeedTestSource.apple);
    expect(r.downloadMbps, 120);
    expect(r.error, isNull);

    // 「用同样设置再测一次」照记录填回
    c.setSource(SpeedTestSource.google);
    c.setMultiThread(false);
    c.setNode('香港 01');
    c.prefill(r);
    expect((c.source, c.multiThread, c.node), (SpeedTestSource.apple, true, kSpeedTestDirect));

    late SpeedTestController stopped;
    stopped = SpeedTestController(call: (method, data) async {
      if (method == ActionMethod.meowSpeedTestStatus) {
        stopped.stop();
        return '{"runID":1,"phase":"done","downloadMbps":1}';
      }
      return '';
    });
    await stopped.start('n');
    expect(stopped.history.records, isEmpty);

    final failed = SpeedTestController(call: (method, data) async {
      if (method == ActionMethod.meowSpeedTestStatus) return '{"runID":1,"phase":"failed","error":"连不上"}';
      return '';
    });
    await failed.start('n');
    expect(failed.history.records.single.error, '连不上');
    expect(failed.history.records.single.connections, 1);
  });

  test('控制器：测速页页头「分享」取这次刚测完的那条；开测即清，失败 / 停掉 / 没能开始都没有，记录删了也取不到', () async {
    var status = '{"runID":1,"phase":"done","downloadMbps":120}';
    String? startReply = '';
    var stopMidway = false;
    SpeedTestRecord? atStart;
    late SpeedTestController c;
    c = SpeedTestController(call: (method, data) async {
      switch (method) {
        case ActionMethod.meowSpeedTestStart:
          atStart = c.shareableRecord;
          return startReply;
        case ActionMethod.meowSpeedTestStatus:
          if (stopMidway) c.stop();
          return status;
        default:
          return '';
      }
    });
    expect(c.shareableRecord, isNull); // 还没测过

    await c.start('n');
    final first = c.history.records.single;
    expect(c.shareableRecord?.id, first.id);

    // 再测一次：开测那一刻就没了；这次失败 → 也没有（上一次测完的那条还在记录里也不给）
    status = '{"runID":2,"phase":"failed","error":"连不上"}';
    await c.start('n');
    expect(atStart, isNull);
    expect(c.history.records.length, 2);
    expect(c.history.byId(first.id), isNotNull);
    expect(c.shareableRecord, isNull);

    // 测完之后又测了一次、中途停掉（停掉的不记）：没有
    status = '{"runID":3,"phase":"done","downloadMbps":90}';
    await c.start('n');
    expect(c.shareableRecord?.id, c.history.records.first.id);
    stopMidway = true;
    await c.start('n');
    stopMidway = false;
    expect(c.progress.phase, 'cancelled');
    expect(c.history.records.length, 3);
    expect(c.shareableRecord, isNull);

    // 核心不让开始：没有
    await c.start('n');
    expect(c.shareableRecord, isNotNull);
    startReply = '找不到节点 n';
    await c.start('n');
    expect(c.message, '找不到节点 n');
    expect(c.shareableRecord, isNull);
    startReply = '';

    // 那条记录被删了 / 记录清空了：取不到
    await c.start('n');
    final last = c.shareableRecord!;
    expect(last.downloadMbps, 90);
    c.history.delete(last.id);
    expect(c.shareableRecord, isNull);
    await c.start('n');
    expect(c.shareableRecord, isNotNull);
    c.history.clear();
    expect(c.shareableRecord, isNull);
  });

  Widget app(Widget home) => MaterialApp(theme: meowThemeData(brightness: Brightness.light), home: home);

  testWidgets('记录页：汇总卡、筛选胶囊、最快角标；左滑删除；清空要确认', (tester) async {
    final c = SpeedTestController(call: (_, _) async => '');
    c.history
      ..add(record(3, '香港 01', down: 80, up: 20, latency: 40))
      ..add(record(2, '日本 02', error: '超时'))
      ..add(record(1, kSpeedTestDirect, down: 300, up: 50, latency: 9));
    await tester.pumpWidget(app(SpeedTestHistoryPage(controller: c)));
    expect(find.text('最近 30 天 · 3 次'), findsOneWidget);
    expect(find.text('全部节点'), findsOneWidget);
    expect(find.text('最快'), findsOneWidget);
    expect(find.text('本机网络'), findsOneWidget);
    expect(find.text('失败'), findsOneWidget);
    expect(find.text('下载速率走势（按时间）'), findsOneWidget);

    // 筛到「日本 02」：汇总卡右上角换名字，只剩一条
    await tester.tap(find.widgetWithText(AnimatedContainer, '日本 02'));
    await tester.pumpAndSettle();
    expect(find.text('最近 30 天 · 1 次'), findsOneWidget);

    await tester.tap(find.widgetWithText(AnimatedContainer, '全部'));
    await tester.pumpAndSettle();
    await tester.drag(find.text('本机网络'), const Offset(-500, 0));
    await tester.pumpAndSettle();
    expect(c.history.records.length, 2);

    await tester.tap(find.text('清空'));
    await tester.pumpAndSettle();
    expect(find.text('清空全部 2 条测速记录？'), findsOneWidget);
    await tester.tap(find.text('清空').last);
    await tester.pumpAndSettle();
    expect(c.history.records, isEmpty);
    expect(find.text('还没有测速记录，测完一次会出现在这里'), findsOneWidget);
  });

  testWidgets('详情页：大数 / 参数；桌面上是「保存分享图」；「用同样设置再测一次」预填并带 true 退出', (tester) async {
    final c = SpeedTestController(call: (_, _) async => '');
    final r = SpeedTestRecord(
      id: 'r1',
      date: now,
      source: SpeedTestSource.google,
      connections: 1,
      outbound: kSpeedTestDirect,
      latencyMs: 12,
      downloadMbps: 88.25,
      downloadPeakMbps: 101,
      downloadSamples: const [10, 80, 90],
      bytesUsed: 5 * 1024 * 1024,
    );
    c.history.add(r);
    bool? popped;
    await tester.pumpWidget(app(Builder(
      builder: (context) => TextButton(
        onPressed: () async => popped = await Navigator.of(context).push<bool>(
          MaterialPageRoute(builder: (_) => SpeedTestRecordPage(controller: c, id: 'r1')),
        ),
        child: const Text('go'),
      ),
    )));
    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();
    expect(find.text('直连 · 本机网络'), findsOneWidget);
    expect(find.text('88.3'), findsOneWidget);
    expect(find.text('峰值 101 Mbps'), findsOneWidget);
    expect(find.text('未测'), findsOneWidget);
    expect(find.text('直连（DIRECT）'), findsOneWidget);
    expect(find.text('5.0 MB'), findsOneWidget);
    // 测试窗口 800×600，按钮在列表底部：先滚出来
    await tester.scrollUntilVisible(find.text('用同样设置再测一次'), 200);
    // 不指定时按平台：只有安卓是「分享」，测试跑在桌面上 = 存文件
    expect(find.text('保存分享图'), findsOneWidget);
    expect(find.text('分享'), findsNothing);
    await tester.tap(find.text('用同样设置再测一次'));
    await tester.pumpAndSettle();
    expect(popped, isTrue);
    expect((c.source, c.multiThread, c.node), (SpeedTestSource.google, false, kSpeedTestDirect));
  });
}
