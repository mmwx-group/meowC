import 'dart:convert';

import 'package:bett_box/enum/enum.dart';
import 'package:bett_box/meowx/pages/speedtest/speed_test_page.dart';
import 'package:bett_box/meowx/state/speed_test.dart';
import 'package:bett_box/meowx/theme/meow_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('进度 JSON：核心回的字段都认得，缺的给缺省值', () {
    final p = SpeedTestProgress.fromJson(json.decode('''
      {"runID":3,"phase":"upload","source":"speedtest","via":"香港 01","server":"Hong Kong · 1010","latencyMs":38,
       "downloadMbps":257.4,"downloadPeakMbps":286,"currentMbps":41.5,"downloadSamples":[1,2.5],"uploadSamples":[3],
       "phaseProgress":0.5,"bytesUsed":123456,"error":""}''') as Map<String, Object?>);
    expect(p.runID, 3);
    expect(p.phase, 'upload');
    expect(p.isRunning, isTrue);
    expect(p.source, SpeedTestSource.speedtest);
    expect(p.latencyMs, 38);
    expect(p.downloadMbps, 257.4);
    expect(p.downloadPeakMbps, 286.0);
    expect(p.uploadMbps, isNull);
    expect(p.downloadSamples, [1.0, 2.5]);
    expect(p.error, isNull);   // 空串当作没有错误
    final idle = SpeedTestProgress.fromJson(const {});
    expect(idle.phase, 'idle');
    expect(idle.isRunning, isFalse);
    expect(SpeedTestSource.google.hasUpload, isFalse);
  });

  test('控制器：开始后轮询到完成为止；请求带上测速源 / 节点 / 线程数', () async {
    final calls = <(ActionMethod, String)>[];
    final statuses = [
      '{"runID":1,"phase":"download","currentMbps":100}',
      '{"runID":1,"phase":"done","downloadMbps":120}',
    ];
    final c = SpeedTestController(call: (method, data) async {
      calls.add((method, data));
      if (method == ActionMethod.meowSpeedTestStart) return '';
      if (method == ActionMethod.meowSpeedTestStatus) return statuses.removeAt(0);
      return '';
    });
    c.setSource(SpeedTestSource.cloudflare);
    c.setMultiThread(true);
    await c.start('香港 01');
    expect(c.progress.phase, 'done');
    expect(c.progress.downloadMbps, 120);
    expect(c.isRunning, isFalse);
    final start = json.decode(calls.first.$2) as Map<String, Object?>;
    expect(start, {'source': 'cloudflare', 'proxy': '香港 01', 'connections': SpeedTestController.multiConnections});
    expect(calls.where((c) => c.$1 == ActionMethod.meowSpeedTestStatus).length, 2);
  });

  test('控制器：核心回原因 → 不开始、显示原因；旧核心回 null → 提示核心过旧', () async {
    final c = SpeedTestController(call: (method, data) async => '找不到节点 x');
    await c.start('x');
    expect(c.message, '找不到节点 x');
    expect(c.isRunning, isFalse);
    final old = SpeedTestController(call: (method, data) async => null);
    await old.start('x');
    expect(old.message, contains('核心版本过旧'));
  });

  test('控制器：停止后不再轮询，状态改成已停止并通知核心', () async {
    final calls = <ActionMethod>[];
    late SpeedTestController c;
    c = SpeedTestController(call: (method, data) async {
      calls.add(method);
      if (method == ActionMethod.meowSpeedTestStatus) {
        c.stop();   // 第一次拉进度时用户点了停止
        return '{"runID":1,"phase":"download"}';
      }
      return '';
    });
    await c.start('n');
    expect(c.progress.phase, 'cancelled');
    expect(calls.where((m) => m == ActionMethod.meowSpeedTestStatus).length, 1);
    expect(calls.last, ActionMethod.meowSpeedTestStop);
  });

  test('曲线线头：速度与落后的格数成正比、不越过最新样本；样本变少（新的一次）从头开始', () {
    var head = 0.0;
    head = SpeedTestChartMotion.step(head, 5, 0.1);   // 落后 4 格：一帧走 4×4×0.1 = 1.6
    expect(head, closeTo(1.6, 1e-9));
    for (var i = 0; i < 100; i++) {
      head = SpeedTestChartMotion.step(head, 5, 0.1);
    }
    expect(head, lessThanOrEqualTo(4));
    expect(head, greaterThan(3.99));
    expect(SpeedTestChartMotion.step(head, 2, 0.1), 0);
    final m = SpeedTestChartMotion()..advance(download: 10, upload: 3, targetMax: 50, dt: 0, live: false);
    expect((m.downloadHead, m.uploadHead, m.shownMax), (9.0, 2.0, 50.0));
  });

  testWidgets('读数区：测完显示延迟 / 下载 / 峰值；Google 的上传格写「不支持」', (tester) async {
    await tester.pumpWidget(MaterialApp(
      theme: meowThemeData(brightness: Brightness.light),
      home: const Scaffold(
        body: SpeedTestGauge(
          progress: SpeedTestProgress(
            phase: 'done',
            source: SpeedTestSource.google,
            latencyMs: 38,
            downloadMbps: 257.4,
            downloadPeakMbps: 286,
            downloadSamples: [10, 200, 250],
          ),
        ),
      ),
    ));
    expect(find.text('测速完成'), findsOneWidget);
    // 三格的数字与单位是同一段富文本（固定字号、不再套 FittedBox）
    expect(find.text('38 ms', findRichText: true), findsOneWidget);
    expect(find.text('257'), findsOneWidget);   // 大数字
    expect(find.text('257 Mbps', findRichText: true), findsOneWidget);   // 下载格
    expect(find.text('峰值 286'), findsOneWidget);
    expect(find.text('不支持'), findsOneWidget);
  });
}
