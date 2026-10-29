import 'dart:async';
import 'dart:convert';

import 'package:bett_box/enum/enum.dart';
import 'package:bett_box/meowx/pages/speedtest/speed_test_page.dart';
import 'package:bett_box/meowx/state/connection.dart';
import 'package:bett_box/meowx/state/speed_test.dart';
import 'package:bett_box/meowx/state/status.dart';
import 'package:bett_box/meowx/theme/meow_theme.dart';
import 'package:bett_box/models/models.dart';
import 'package:bett_box/providers/providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/haptics.dart';

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

  group('震动', () {
    /// 核心依次回 [statuses] 里的进度（最后一个一直回）；[start] = 开始的回包（空串 = 开始了）
    SpeedTestController fake(List<String> statuses, {String? start = ''}) => SpeedTestController(
      call: (method, data) async => switch (method) {
        ActionMethod.meowSpeedTestStart => start,
        ActionMethod.meowSpeedTestStatus => statuses.length > 1 ? statuses.removeAt(0) : statuses.first,
        _ => '',
      },
    );

    test('自己测完：开始轻震、测完成功震，一次测速只震这两下', () async {
      final haptics = recordHaptics();
      final c = fake(['{"runID":1,"phase":"download"}', '{"runID":1,"phase":"done","downloadMbps":120}']);
      await c.start('n');
      expect(haptics, [kLight, kSuccess]);
      // 再测一次：又是一对
      await c.start('n');
      expect(haptics, [kLight, kSuccess, kLight, kSuccess]);
    });

    test('测速失败、核心不让开始（原因 / 旧核心回 null）：失败震', () async {
      final haptics = recordHaptics();
      await fake(['{"runID":1,"phase":"failed","error":"连不上"}']).start('n');
      expect(haptics, [kLight, kError]);
      haptics.clear();
      await fake(const [], start: '找不到节点 n').start('n');
      expect(haptics, [kLight, kError]);
      haptics.clear();
      await fake(const [], start: null).start('n');
      expect(haptics, [kLight, kError]);
    });

    test('中途停掉：只有开始那一下，没有成功 / 失败（停止的震动在按钮上）', () async {
      final haptics = recordHaptics();
      late SpeedTestController c;
      c = SpeedTestController(call: (method, data) async {
        if (method != ActionMethod.meowSpeedTestStatus) return '';
        c.stop();
        return '{"runID":1,"phase":"done","downloadMbps":1}';
      });
      await c.start('n');
      expect(c.progress.phase, 'cancelled');
      expect(haptics, [kLight]);
    });

    testWidgets('测速页：点「停止」轻震；打开页面看见上次的结果、离开页面自动停都不震', (tester) async {
      tester.view.physicalSize = const Size(400, 1400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final haptics = recordHaptics();
      final c = fake(['{"runID":1,"phase":"download","currentMbps":20}']);
      c.progress = const SpeedTestProgress(phase: 'done', downloadMbps: 120);   // 上一次的结果
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            isRunningProvider.overrideWithValue(true),
            currentGroupsStateProvider.overrideWithValue(
              GroupsState(value: [Group(name: '节点选择', type: GroupType.Selector, now: 'n', all: const [Proxy(name: 'n', type: 'Vless')])]),
            ),
            currentNodeProvider.overrideWithValue(const CurrentNode(group: '节点选择', path: ['节点选择'], leaf: 'n')),
          ],
          child: MaterialApp(theme: meowThemeData(brightness: Brightness.light), home: SpeedTestPage(controller: c)),
        ),
      );
      await tester.pump();
      expect(find.text('测速完成'), findsOneWidget);
      expect(haptics, isEmpty);

      // 开始按钮先查网络类型（测试里没有那个插件），这里直接调 start（按钮最后也是调它）
      unawaited(c.start('n'));
      await tester.pump();
      expect(find.text('停止'), findsOneWidget);
      await tester.tap(find.text('停止'));
      await tester.pump();
      expect(c.progress.phase, 'cancelled');
      expect(haptics, [kLight, kLight]);
      await tester.pump(const Duration(milliseconds: 300));

      // 再测一次，测到一半离开页面：dispose 里的 stop 不震
      unawaited(c.start('n'));
      await tester.pump();
      await tester.pumpWidget(const SizedBox.shrink());
      expect(c.isRunning, isFalse);
      await tester.pump(const Duration(milliseconds: 300));
      expect(haptics, [kLight, kLight, kLight]);
    });
  });
}
