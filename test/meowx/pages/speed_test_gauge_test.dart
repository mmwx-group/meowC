import 'dart:convert';

import 'package:bett_box/meowx/pages/speedtest/speed_test_history_page.dart';
import 'package:bett_box/meowx/pages/speedtest/speed_test_page.dart';
import 'package:bett_box/meowx/state/speed_test.dart';
import 'package:bett_box/meowx/theme/meow_theme.dart';
import 'package:bett_box/meowx/theme/tokens.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

// 主题只建一份：每次 pumpWidget 都新建的话 AnimatedTheme 会做一次 200ms 渐变，测「不要帧」时会被它干扰
final _theme = meowThemeData(brightness: Brightness.light);

Widget _app(Widget child) => MaterialApp(
  theme: _theme,
  home: Scaffold(body: SingleChildScrollView(child: child)),
);

const _kddi = SpeedTestExit(ip: '203.0.113.8', asn: 2516, org: 'KDDI', country: 'JP');

/// [finder]（一个 RepaintBoundary）自己画的那张图
PictureLayer? _picture(WidgetTester tester, Finder finder) {
  final boundary = tester.renderObject(finder) as RenderRepaintBoundary;
  Layer? layer = boundary.debugLayer!.firstChild;
  while (layer != null && layer is! PictureLayer) {
    layer = layer.nextSibling;
  }
  return layer as PictureLayer?;
}

SpeedTestDialState _dial(WidgetTester tester) => tester.state<SpeedTestDialState>(find.byType(SpeedTestDial));

double _needle(WidgetTester tester) => _dial(tester).motion.position;

Color? _colorOf(WidgetTester tester, String text) => tester.widget<Text>(find.text(text)).style?.color;

void main() {
  test('刻度：0·5·10·50·100·250·500·1000 等距分段线性，超出 1000 停在满格', () {
    expect(speedGaugePosition(0), 0);
    expect(speedGaugePosition(-3), 0);
    expect(speedGaugePosition(double.nan), 0);
    expect(speedGaugePosition(5), closeTo(1 / 7, 1e-12));
    expect(speedGaugePosition(7.5), closeTo(1.5 / 7, 1e-12));
    expect(speedGaugePosition(100), closeTo(4 / 7, 1e-12));
    expect(speedGaugePosition(375), closeTo(5.5 / 7, 1e-12));
    expect(speedGaugePosition(1000), 1);
    expect(speedGaugePosition(2500), 1);
  });

  test('指针弹簧：追得上目标、过冲不超过几个百分点；低速样本之间也在动', () {
    final m = SpeedGaugeMotion();
    final target = speedGaugePosition(640);
    var peak = 0.0;
    for (var i = 0; i < 120; i++) {
      m.advance(target, 1 / 60);
      if (m.position > peak) peak = m.position;
    }
    expect(m.settledAt(target), isTrue);
    expect(m.position, target);
    expect(peak, greaterThan(target), reason: '带一点弹簧感');
    expect(peak - target, lessThan(0.05));

    // 进度 300ms 才来一个值：1 → 2 Mbps 在刻度上只差 1/35，指针也要在这 300ms 里明显挪过去
    final low = SpeedGaugeMotion()..jump(speedGaugePosition(1));
    final from = low.position;
    for (var i = 0; i < 6; i++) {
      low.advance(speedGaugePosition(2), 1 / 60);
    }
    expect(low.position, greaterThan(from));
    for (var i = 0; i < 12; i++) {
      low.advance(speedGaugePosition(2), 1 / 60);
    }
    expect(low.position - from, greaterThan((speedGaugePosition(2) - from) * 0.6));

    // 掉帧时一大步也不发散
    final big = SpeedGaugeMotion()..advance(1, 0.5);
    expect(big.position, inInclusiveRange(0, 1));
  });

  group('码表各阶段', () {
    Future<void> pump(WidgetTester tester, SpeedTestProgress p) async {
      await tester.pumpWidget(_app(SpeedTestGauge(progress: p)));
    }

    testWidgets('准备：数字是浅色 0、阶段字次级色；指针在 0、不要帧', (tester) async {
      await pump(tester, const SpeedTestProgress(phase: 'preparing', source: SpeedTestSource.cloudflare));
      expect(find.text('0'), findsOneWidget);
      expect(find.text('Mbps'), findsOneWidget);
      expect(find.text('连接测速服务器…'), findsOneWidget);
      expect(_colorOf(tester, '连接测速服务器…'), MeowTokens.light.t2);
      expect(_needle(tester), 0);
      expect(_dial(tester).animating, isFalse, reason: '指针在 0、目标也是 0：码表不要帧（曲线在测速中自己按帧走）');
      await pump(tester, const SpeedTestProgress(phase: 'preparing', source: SpeedTestSource.speedtest));
      expect(find.text('挑选测速服务器…'), findsOneWidget);
    });

    testWidgets('下载：大数字是当前速度、阶段字紫；指针追到当前速度后停帧', (tester) async {
      await pump(tester, const SpeedTestProgress(phase: 'latency', latencyMs: 38));
      expect(find.text('测延迟…'), findsOneWidget);
      await pump(tester, const SpeedTestProgress(phase: 'download', latencyMs: 38, currentMbps: 41.5));
      expect(find.text('41.5'), findsOneWidget);
      expect(find.text('下载中'), findsOneWidget);
      expect(_colorOf(tester, '下载中'), MeowTokens.light.down);
      expect(find.text('38 ms', findRichText: true), findsOneWidget);
      expect(_needle(tester), 0, reason: '弹簧从 0 起步');
      await tester.pump(const Duration(milliseconds: 100));
      final mid = _needle(tester);
      expect(mid, greaterThan(0));
      expect(mid, lessThan(speedGaugePosition(41.5) + 0.05));
      await tester.pump(const Duration(seconds: 3));
      expect(_needle(tester), speedGaugePosition(41.5));
      // 追上了：定时器停掉（曲线在测速中还在走，所以这里只看码表自己）
      expect(_dial(tester).animating, isFalse);
    });

    testWidgets('上传：阶段字玫红；测完：数字是下载平均、阶段字绿，指针回到 0', (tester) async {
      await pump(
        tester,
        const SpeedTestProgress(phase: 'upload', source: SpeedTestSource.apple, downloadMbps: 257.4, currentMbps: 120),
      );
      expect(find.text('120'), findsOneWidget);
      expect(find.text('上传中'), findsOneWidget);
      expect(_colorOf(tester, '上传中'), MeowTokens.light.accent);
      await tester.pump(const Duration(seconds: 3));
      expect(_needle(tester), speedGaugePosition(120));

      await pump(
        tester,
        const SpeedTestProgress(
          phase: 'done',
          source: SpeedTestSource.apple,
          downloadMbps: 257.4,
          downloadPeakMbps: 286,
          uploadMbps: 88.25,
          uploadPeakMbps: 95,
        ),
      );
      expect(find.text('257'), findsOneWidget);
      expect(find.text('测速完成'), findsOneWidget);
      expect(_colorOf(tester, '测速完成'), MeowTokens.light.good);
      expect(find.text('峰值 286'), findsOneWidget);
      expect(find.text('88.3 Mbps', findRichText: true), findsOneWidget);
      await tester.pump(const Duration(seconds: 3));
      expect(_needle(tester), 0);
      expect(tester.binding.hasScheduledFrame, isFalse);
    });

    testWidgets('失败 / 停止：阶段字', (tester) async {
      await pump(tester, const SpeedTestProgress(phase: 'failed', error: 'x'));
      expect(find.text('测速失败'), findsOneWidget);
      expect(_colorOf(tester, '测速失败'), MeowTokens.light.slow);
      await pump(tester, const SpeedTestProgress(phase: 'cancelled', downloadMbps: 12.345));
      expect(find.text('已停止'), findsOneWidget);
      expect(find.text('12.3'), findsOneWidget);
      await tester.pump(const Duration(seconds: 3));
    });
  });

  testWidgets('指针动的时候只重画指针那一层：码表外面（数字、三格）不重画', (tester) async {
    const outer = ValueKey('outer');
    Widget build(double mbps) => _app(
      RepaintBoundary(
        key: outer,
        child: SpeedTestDial(mbps: mbps, color: Colors.purple, value: '1', phase: '下载中', phaseColor: Colors.purple),
      ),
    );
    await tester.pumpWidget(build(0));
    await tester.pumpWidget(build(500));
    await tester.pump(const Duration(milliseconds: 16));
    final picture = _picture(tester, find.byKey(outer));
    final before = _needle(tester);
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(_needle(tester), isNot(before), reason: '这几帧指针在动');
    expect(_picture(tester, find.byKey(outer)), same(picture));
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('页面被盖住（TickerMode 关）或系统关了动画：不要帧，指针直接落到位', (tester) async {
    Widget build(double mbps, {bool ticker = true, bool reduce = false}) => MaterialApp(
      theme: _theme,
      home: MediaQuery(
        data: MediaQueryData(disableAnimations: reduce),
        child: TickerMode(
          enabled: ticker,
          child: SpeedTestDial(mbps: mbps, color: Colors.purple, value: '1', phase: '下载中', phaseColor: Colors.purple),
        ),
      ),
    );
    await tester.pumpWidget(build(0, ticker: false));
    await tester.pumpWidget(build(300, ticker: false));
    expect(_needle(tester), speedGaugePosition(300));
    await tester.pump(const Duration(milliseconds: 100));
    expect(tester.binding.hasScheduledFrame, isFalse);

    await tester.pumpWidget(build(50, reduce: true));
    expect(_needle(tester), speedGaugePosition(50));
    await tester.pump(const Duration(milliseconds: 100));
    expect(tester.binding.hasScheduledFrame, isFalse);
  });

  group('出口 ASN', () {
    test('进度 JSON 带出口；旧核心没有这两个字段 → 不显示', () {
      final p = SpeedTestProgress.fromJson(json.decode('''
        {"runID":1,"phase":"latency","exitPending":false,
         "exit":{"ip":"203.0.113.8","asn":2516,"org":"KDDI","country":"JP"}}''')
          as Map<String, Object?>);
      expect(p.exit?.ip, '203.0.113.8');
      expect(p.exit?.asnTag, 'AS2516');
      expect(p.exit?.label, 'KDDI · 203.0.113.8');
      expect(p.exit?.country, 'JP');
      expect(p.exitPending, isFalse);
      final pending = SpeedTestProgress.fromJson(const {'phase': 'preparing', 'exitPending': true});
      expect((pending.exit, pending.exitPending), (null, true));
      final old = SpeedTestProgress.fromJson(const {'phase': 'download'});
      expect((old.exit, old.exitPending), (null, false));
      // 没有 ip 的出口不算
      expect(SpeedTestExit.fromJson(const {'asn': 13335}), isNull);
      // 没有运营商名就只有 IP；没有 ASN 就没有标签
      expect(const SpeedTestExit(ip: '198.51.100.1').label, '198.51.100.1');
      expect(const SpeedTestExit(ip: '198.51.100.1').asnTag, isNull);
    });

    test('测速记录存出口；旧记录没有就是 null', () {
      final r = SpeedTestRecord.fromProgress(
        const SpeedTestProgress(phase: 'done', downloadMbps: 10, exit: _kddi),
        source: SpeedTestSource.cloudflare,
        connections: 1,
        outbound: '东京 02',
      )!;
      expect(r.exit?.asn, 2516);
      final back = SpeedTestRecord.fromJson(json.decode(json.encode(r.toJson())) as Map<String, Object?>)!;
      expect(back.exit?.ip, '203.0.113.8');
      expect(back.exit?.org, 'KDDI');
      expect(back.exit?.country, 'JP');
      final noExit = SpeedTestRecord.fromProgress(
        const SpeedTestProgress(phase: 'done', downloadMbps: 10),
        source: SpeedTestSource.cloudflare,
        connections: 1,
        outbound: '东京 02',
      )!;
      expect(noExit.toJson().containsKey('exit'), isFalse);
      final old = SpeedTestRecord.fromJson(const {'id': 'a', 'date': 1700000000, 'outbound': 'x'})!;
      expect(old.exit, isNull);
    });

    testWidgets('出口一行：ASN 小标签 + 运营商 · IP；查询中「查询出口…」；查不到不显示', (tester) async {
      await tester.pumpWidget(_app(const SpeedTestExitLine(exit: _kddi)));
      expect(find.text('AS2516'), findsOneWidget);
      expect(find.text('KDDI · 203.0.113.8'), findsOneWidget);

      await tester.pumpWidget(_app(const SpeedTestExitLine(exit: null, pending: true)));
      expect(find.text('查询出口…'), findsOneWidget);

      await tester.pumpWidget(_app(const SpeedTestExitLine(exit: null)));
      expect(find.text('查询出口…'), findsNothing);
      expect(find.textContaining('AS'), findsNothing);
      expect(SpeedTestExitLine.visible(null), isFalse);
      expect(SpeedTestExitLine.visible(null, pending: true), isTrue);
      expect(SpeedTestExitLine.visible(_kddi), isTrue);
    });

    testWidgets('记录详情：有出口显示这一行，旧记录不显示', (tester) async {
      SpeedTestRecord record({SpeedTestExit? exit}) => SpeedTestRecord(
        id: 'r',
        date: DateTime(2026, 10, 20, 21, 42),
        source: SpeedTestSource.cloudflare,
        connections: 1,
        outbound: '东京 02',
        downloadMbps: 88,
        exit: exit,
      );
      await tester.pumpWidget(_app(SpeedTestRecordDetail(record: record(exit: _kddi))));
      expect(find.text('AS2516'), findsOneWidget);
      expect(find.text('KDDI · 203.0.113.8'), findsOneWidget);
      await tester.pumpWidget(_app(SpeedTestRecordDetail(record: record())));
      expect(find.text('AS2516'), findsNothing);
      expect(find.byType(SpeedTestExitLine), findsNothing);
    });
  });
}
