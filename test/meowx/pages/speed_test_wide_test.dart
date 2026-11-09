import 'dart:async';

import 'package:bett_box/enum/enum.dart';
import 'package:bett_box/meowx/pages/speedtest/speed_test_history_page.dart';
import 'package:bett_box/meowx/pages/speedtest/speed_test_page.dart';
import 'package:bett_box/meowx/pages/speedtest/speed_test_wide.dart';
import 'package:bett_box/meowx/state/connection.dart';
import 'package:bett_box/meowx/state/meow_settings.dart';
import 'package:bett_box/meowx/state/speed_board.dart';
import 'package:bett_box/meowx/state/speed_test.dart';
import 'package:bett_box/meowx/state/status.dart';
import 'package:bett_box/meowx/theme/meow_theme.dart';
import 'package:bett_box/meowx/theme/tokens.dart';
import 'package:bett_box/meowx/theme/widgets.dart';
import 'package:bett_box/models/models.dart';
import 'package:bett_box/providers/providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/haptics.dart';

// 测速页 / 测速记录 / 记录详情的宽版（横着、够放两栏时一屏放下）：桌面窗口与手机横屏用两栏，手机竖屏仍是原来的单列。

const _idle = '{"runID":0,"phase":"idle"}';

const _done = '{"runID":1,"phase":"done","source":"apple","via":"香港 01","server":"mensura.cdn-apple.com","latencyMs":38,'
    '"downloadMbps":486.4,"downloadPeakMbps":533,"uploadMbps":92.7,"uploadPeakMbps":101,'
    '"downloadSamples":[100,480,500,470,490,486],"uploadSamples":[90,92,95,93],"bytesUsed":746586112,"durationMs":20480}';

SpeedTestController _controller({String status = _idle}) => SpeedTestController(
  clientInfo: () => const SpeedBoardClientInfo(platform: 'windows', version: '0.5.1'),
  boardEndpoint: const SpeedBoardEndpoint(),
  networkProbe: () async => null,
  call: (method, data) async => method == ActionMethod.meowSpeedTestStatus ? status : '',
);

SpeedTestRecord _record(String id, {required DateTime date, String outbound = '香港 01', double down = 486.4, String? error}) =>
    SpeedTestRecord(
      id: id,
      date: date,
      source: SpeedTestSource.apple,
      connections: 8,
      outbound: outbound,
      server: 'mensura.cdn-apple.com',
      latencyMs: error == null ? 38 : null,
      downloadMbps: error == null ? down : null,
      downloadPeakMbps: error == null ? down * 1.1 : null,
      uploadMbps: error == null ? 92.7 : null,
      uploadPeakMbps: error == null ? 101 : null,
      downloadSamples: error == null ? const [100, 480, 500, 470, 490, 486] : const [],
      uploadSamples: error == null ? const [90, 92, 95, 93] : const [],
      bytesUsed: 746586112,
      protocol: 'VLESS',
      protocolCode: 'vless',
      error: error,
    );

Widget _app(Widget home) => ProviderScope(
  overrides: [
    isRunningProvider.overrideWithValue(true),
    meowLookProvider.overrideWithValue(MeowLook.classic),
    currentGroupsStateProvider.overrideWithValue(
      GroupsState(
        value: [
          Group(name: '节点选择', type: GroupType.Selector, now: '香港 01', all: const [Proxy(name: '香港 01', type: 'Vless')]),
        ],
      ),
    ),
    currentNodeProvider.overrideWithValue(CurrentNode(group: '节点选择', path: const ['节点选择'], leaf: '香港 01')),
  ],
  child: MaterialApp(debugShowCheckedModeBanner: false, theme: meowThemeData(brightness: Brightness.light), home: home),
);

/// 逻辑尺寸 [width]×[height]，[padding] 是系统栏（逻辑像素）
void _window(WidgetTester tester, double width, double height, {double dpr = 1, EdgeInsets padding = EdgeInsets.zero}) {
  tester.view.devicePixelRatio = dpr;
  tester.view.physicalSize = Size(width * dpr, height * dpr);
  tester.view.padding = FakeViewPadding(
    left: padding.left * dpr,
    top: padding.top * dpr,
    right: padding.right * dpr,
    bottom: padding.bottom * dpr,
  );
  addTearDown(tester.view.reset);
}

Future<SpeedTestController> _pumpPage(WidgetTester tester, {String status = _idle}) async {
  final c = _controller(status: status);
  await tester.pumpWidget(_app(SpeedTestPage(controller: c, boardGrant: (_) async => null)));
  await tester.pumpAndSettle();
  return c;
}

/// 宽版外层滚动区还能滚多少（0 = 一屏放下）
double _maxScroll(WidgetTester tester, Key wide) => tester
    .state<ScrollableState>(find.descendant(of: find.byKey(wide), matching: find.byType(Scrollable)).first)
    .position
    .maxScrollExtent;

Rect _rect(WidgetTester tester, Finder f) => tester.getRect(f);

/// [f] 整个落在窗口里（不用滚就看得见）
void _expectOnScreen(WidgetTester tester, Finder f, Size window) {
  final r = _rect(tester, f);
  expect(r.top, greaterThanOrEqualTo(0), reason: '$f 顶边 ${r.top}');
  expect(r.bottom, lessThanOrEqualTo(window.height + 0.01), reason: '$f 底边 ${r.bottom} > ${window.height}');
  expect(r.left, greaterThanOrEqualTo(0));
  expect(r.right, lessThanOrEqualTo(window.width + 0.01));
}

const _wideKey = ValueKey('speedtest-wide');
final _dialCard = find.byKey(const ValueKey('speedtest-dial-card'));
final _readoutsCard = find.byKey(const ValueKey('speedtest-readouts-card'));
final _settingsCard = find.byKey(const ValueKey('speedtest-settings-card'));

void main() {
  setUp(() {
    // 测速榜已答过「不上传」：不弹同意卡片
    SharedPreferences.setMockInitialValues({'meowx.speedTest.upload': false});
    recordHaptics();
  });

  test('判定：横着且宽 ≥ 680 才用两栏', () {
    expect(speedTestWide(const Size(1280, 800)), isTrue);
    expect(speedTestWide(const Size(910, 620)), isTrue);
    expect(speedTestWide(const Size(914, 411)), isTrue); // 手机横屏
    expect(speedTestWide(const Size(680, 600)), isTrue);
    expect(speedTestWide(const Size(679, 400)), isFalse); // 太窄
    expect(speedTestWide(const Size(800, 1280)), isFalse); // 平板竖屏
    expect(speedTestWide(const Size(400, 860)), isFalse); // 手机竖屏
  });

  group('测速页', () {
    // 后两个是 1100×720 / 910×620 的 Windows / Linux 窗口去掉二级页顶上 40 高的窗口栏（WindowPageFrame，测试里没有）后页面实际拿到的高度
    for (final size in const [Size(1280, 800), Size(1100, 720), Size(910, 620), Size(1100, 680), Size(910, 580)]) {
      testWidgets('桌面窗口 ${size.width.toInt()}×${size.height.toInt()}：两栏一屏放下，不用滚', (tester) async {
        _window(tester, size.width, size.height);
        await _pumpPage(tester);
        expect(find.byKey(_wideKey), findsOneWidget);
        expect(_maxScroll(tester, _wideKey), 0);
        // 左栏码表卡、右栏读数卡并排、顶对齐；设置卡在右栏
        final dial = _rect(tester, _dialCard), readouts = _rect(tester, _readoutsCard), settings = _rect(tester, _settingsCard);
        expect(dial.right, lessThan(readouts.left));
        expect(dial.top, closeTo(readouts.top, 0.01));
        expect(settings.left, closeTo(readouts.left, 0.01));
        expect(settings.top, greaterThan(readouts.bottom));
        for (final f in [
          _dialCard,
          _readoutsCard,
          _settingsCard,
          find.byType(SpeedTestDial),
          find.text('开始测速'),
          find.text('在浏览器打开网页测速'),
          find.text('上传到测速榜'),
          find.text('逐秒速率'),
        ]) {
          _expectOnScreen(tester, f, size);
        }
        // 两栏底边对齐（码表卡、读数卡吃满剩下的高度）
        final leftBottom = _rect(tester, find.text('在浏览器打开网页测速').hitTestable()).bottom;
        expect(settings.bottom, greaterThan(leftBottom));
        // 码表不小于原尺寸的七成
        expect(_rect(tester, find.byType(SpeedTestDial)).height, greaterThan(SpeedTestDial.height * 0.7));
        // 测速源五段排成一行（栏宽够）
        expect(find.byType(MeowSegment<SpeedTestSource>), findsOneWidget);
        // 单列的说明文字收进了「测速源」旁的 ⓘ
        expect(find.textContaining('数据边收边丢'), findsNothing);
      });
    }

    testWidgets('桌面窗口 910×620 测完之后：曲线占位说明撤掉，仍然一屏放下', (tester) async {
      _window(tester, 910, 620);
      final c = await _pumpPage(tester, status: _done);
      unawaited(c.start('香港 01', protocol: 'VLESS', protocolCode: 'vless'));
      await tester.pumpAndSettle();
      expect(find.text('测速完成'), findsOneWidget);
      expect(find.text('逐秒速率'), findsNothing);
      expect(_maxScroll(tester, _wideKey), 0);
      _expectOnScreen(tester, find.text('服务器 mensura.cdn-apple.com · 经由 香港 01'), const Size(910, 620));
      _expectOnScreen(tester, find.textContaining('峰值 ').first, const Size(910, 620));
      _expectOnScreen(tester, find.text('测速完成'), const Size(910, 620));
    });

    testWidgets('手机横屏 914×411：两栏；码表、开始按钮、读数在第一屏，矮的部分可以滚', (tester) async {
      const size = Size(914, 411);
      _window(tester, size.width, size.height, dpr: 2.625, padding: const EdgeInsets.only(top: 24));
      await _pumpPage(tester);
      expect(find.byKey(_wideKey), findsOneWidget);
      for (final f in [_dialCard, find.byType(SpeedTestDial), find.text('开始测速'), find.text('延迟')]) {
        _expectOnScreen(tester, f, size);
      }
      expect(_rect(tester, _dialCard).right, lessThan(_rect(tester, _readoutsCard).left));
      // 设置卡滚下去看得到
      await tester.scrollUntilVisible(find.text('上传到测速榜'), 100,
          scrollable: find.descendant(of: find.byKey(_wideKey), matching: find.byType(Scrollable)).first);
      _expectOnScreen(tester, find.text('上传到测速榜'), size);
    });

    testWidgets('手机竖屏 400×860：仍是原来的单列', (tester) async {
      _window(tester, 400, 860, dpr: 3);
      await _pumpPage(tester);
      expect(find.byKey(_wideKey), findsNothing);
      expect(_dialCard, findsNothing);
      expect(find.byType(ListView), findsOneWidget);
      // 码表、三格、曲线是一整块
      final gauge = tester.widget<SpeedTestGauge>(find.byType(SpeedTestGauge));
      expect(gauge.part, SpeedTestGaugePart.all);
      // 测速源两排、页面底部的说明文字还在
      expect(find.byType(MeowSegment<SpeedTestSource>), findsNWidgets(2));
      await tester.scrollUntilVisible(find.textContaining('数据边收边丢'), 200, scrollable: find.byType(Scrollable).first);
      expect(find.textContaining('数据边收边丢'), findsOneWidget);
    });
  });

  group('测速记录 / 记录详情', () {
    SpeedTestController withRecords() {
      final c = _controller();
      for (var i = 0; i < 12; i++) {
        c.history.add(_record('r$i', date: DateTime(2026, 11, 9 - i ~/ 3, 20, i), outbound: i.isEven ? '香港 01' : '日本 02',
            down: 300 + i * 10.0, error: i == 5 ? '连接超时' : null));
      }
      return c;
    }

    testWidgets('记录列表 1100×720：左边汇总卡 + 筛选、右边记录列表', (tester) async {
      _window(tester, 1100, 720);
      final c = withRecords();
      await tester.pumpWidget(_app(SpeedTestHistoryPage(controller: c)));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('speedtest-history-wide')), findsOneWidget);
      final summary = _rect(tester, find.byType(SpeedTestSummaryCard));
      final firstRow = _rect(tester, find.byType(SpeedTestRecordRow).first);
      expect(summary.right, lessThan(firstRow.left));
      expect(summary.top, closeTo(firstRow.top, 40));
      _expectOnScreen(tester, find.byType(SpeedTestSummaryCard), const Size(1100, 720));
      // 筛选在左栏，三个都看得见（不再横向滚动）
      Finder chip(String t) => find.descendant(of: find.byType(Wrap), matching: find.text(t));
      for (final t in ['全部', '香港 01', '日本 02']) {
        _expectOnScreen(tester, chip(t), const Size(1100, 720));
      }
      // 点「日本 02」筛选右边的列表
      await tester.tap(chip('日本 02'));
      await tester.pumpAndSettle();
      expect(find.byType(SpeedTestRecordRow), findsWidgets);
    });

    testWidgets('记录列表手机竖屏：原来的单列', (tester) async {
      _window(tester, 400, 860, dpr: 3);
      await tester.pumpWidget(_app(SpeedTestHistoryPage(controller: withRecords())));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('speedtest-history-wide')), findsNothing);
      expect(find.byType(ListView), findsOneWidget);
    });

    for (final size in const [Size(1100, 720), Size(910, 620), Size(910, 580)]) {
      testWidgets('记录详情 ${size.width.toInt()}×${size.height.toInt()}：左边摘要与按钮、右边曲线撑满 + 参数表，一屏放下', (tester) async {
        _window(tester, size.width, size.height);
        final c = withRecords();
        await tester.pumpWidget(_app(SpeedTestRecordPage(controller: c, id: 'r0', systemShare: false)));
        await tester.pumpAndSettle();
        const key = ValueKey('speedtest-record-wide');
        expect(find.byKey(key), findsOneWidget);
        expect(_maxScroll(tester, key), 0);
        // 左栏：标题、两个大数、按钮；右栏：曲线（撑满）在上、参数表在下
        final chart = _rect(tester, find.byKey(const ValueKey('speedtest-record-chart')));
        final again = _rect(tester, find.text('用同样设置再测一次'));
        final table = _rect(tester, find.text('测速服务器'));
        expect(again.right, lessThan(chart.left));
        expect(table.left, greaterThan(chart.left));
        expect(table.top, greaterThan(chart.bottom));
        expect(chart.height, greaterThan(150));
        for (final f in [find.text('测速服务器'), find.text('用量'), find.text('用同样设置再测一次'), find.text('保存分享图'), find.text('速率曲线')]) {
          _expectOnScreen(tester, f, size);
        }
      });
    }

    testWidgets('记录详情：失败的记录右边写没有曲线', (tester) async {
      _window(tester, 1100, 720);
      await tester.pumpWidget(_app(SpeedTestRecordPage(controller: withRecords(), id: 'r5', systemShare: false)));
      await tester.pumpAndSettle();
      expect(find.text('测速失败：连接超时'), findsOneWidget);
      expect(find.text('这次测速没有完成，没有速率曲线'), findsOneWidget);
    });

    testWidgets('记录详情手机竖屏：原来的单列', (tester) async {
      _window(tester, 400, 860, dpr: 3);
      await tester.pumpWidget(_app(SpeedTestRecordPage(controller: withRecords(), id: 'r0', systemShare: false)));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('speedtest-record-wide')), findsNothing);
      expect(find.byType(ListView), findsOneWidget);
    });
  });
}
