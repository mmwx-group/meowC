import 'dart:async';
import 'dart:convert';

import 'package:bett_box/enum/enum.dart';
import 'package:bett_box/meowx/pages/speedtest/speed_board_views.dart';
import 'package:bett_box/meowx/pages/speedtest/speed_test_history_page.dart';
import 'package:bett_box/meowx/pages/speedtest/speed_test_page.dart';
import 'package:bett_box/meowx/state/connection.dart';
import 'package:bett_box/meowx/state/meow_settings.dart';
import 'package:bett_box/meowx/state/speed_board.dart';
import 'package:bett_box/meowx/state/speed_test.dart';
import 'package:bett_box/meowx/state/status.dart';
import 'package:bett_box/meowx/theme/meow_theme.dart';
import 'package:bett_box/meowx/theme/tokens.dart';
import 'package:bett_box/models/models.dart';
import 'package:bett_box/providers/providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/haptics.dart';

// 测速榜的界面（设计稿 speedtest-board-preview.html「客户端」：① 同意卡片 ② 测完后的「超越了 x%」条与分享菜单 ③ 记录详情「测速榜」一组）。

const _done = '{"runID":1,"phase":"done","source":"apple","via":"香港 01","server":"mensura.cdn-apple.com","latencyMs":38,'
    '"downloadMbps":486.4,"downloadPeakMbps":533,"uploadMbps":92.7,"uploadPeakMbps":101,"downloadSamples":[100,480],'
    '"uploadSamples":[90,92],"bytesUsed":746586112,"durationMs":20480}';

const _okBody = '{"id":"No63xGk","url":"https://speed.meowx.net/r/No63xGk","delete_token":"tok",'
    '"percentile":{"value":82,"scope":"近 30 天 · 经节点 · 多线程","samples":2431},"provider":{"id":1,"name":"咕咕云"}}';

String _resp(int status, [String body = '']) => json.encode({'status': status, if (body.isNotEmpty) 'body': body});

const _uploaded = SpeedBoardEntry(
  status: SpeedBoardStatus.uploaded,
  id: 'No63xGk',
  url: 'https://speed.meowx.net/r/No63xGk',
  deleteToken: 'tok',
  percentile: SpeedBoardPercentile(value: 82, scope: '近 30 天 · 经节点 · 多线程', samples: 2431),
  provider: '咕咕云',
);

SpeedTestRecord _record({SpeedBoardEntry? board}) => SpeedTestRecord(
  id: 'r1',
  date: DateTime(2026, 10, 29, 23, 42),
  source: SpeedTestSource.apple,
  connections: 8,
  outbound: '香港 01',
  server: 'mensura.cdn-apple.com',
  latencyMs: 38,
  downloadMbps: 486.4,
  downloadPeakMbps: 533,
  uploadMbps: 92.7,
  uploadPeakMbps: 101,
  downloadSamples: const [100, 480],
  uploadSamples: const [90, 92],
  bytesUsed: 746586112,
  protocol: 'VLESS',
  protocolCode: 'vless',
  board: board,
);

/// 假核心：测速进度一律回测完（[_done]）；测速榜请求记进 [sent]、按顺序回 [responses]（没了回 null = 旧核心）
class _FakeCore {
  _FakeCore({List<String?> responses = const []}) : responses = [...responses];
  final String status = _done;
  final List<String?> responses;
  final sent = <Map<String, Object?>>[];
  Completer<void>? hold;

  SpeedTestController controller() => SpeedTestController(
    clientInfo: () => const SpeedBoardClientInfo(platform: 'android', version: '0.4.5'),
    boardEndpoint: const SpeedBoardEndpoint(),
    networkProbe: () async => null,
    call: (method, data) async {
      switch (method) {
        case ActionMethod.meowSpeedTestStatus:
          return status;
        case ActionMethod.meowSpeedTestBoard:
          sent.add(json.decode(data) as Map<String, Object?>);
          await hold?.future;
          return responses.isEmpty ? null : responses.removeAt(0);
        default:
          return '';
      }
    },
  );
}

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

void _phone(WidgetTester tester, {double height = 1000}) {
  tester.view.devicePixelRatio = 3;
  tester.view.physicalSize = Size(360 * 3, height * 3);
  addTearDown(tester.view.reset);
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    recordHaptics();
  });

  group('① 同意卡片', () {
    testWidgets('第一次进测速页弹一次：同意 → 存下 true，关掉卡片；再进不问', (tester) async {
      _phone(tester);
      final core = _FakeCore();
      final c = core.controller();
      await tester.pumpWidget(_app(SpeedTestPage(controller: c, boardGrant: (_) async => null)));
      await tester.pumpAndSettle();
      expect(find.text('参与 MeowX 测速榜？'), findsOneWidget);
      expect(find.textContaining('不传节点名、订阅、主控地址和账号'), findsOneWidget);
      await tester.tap(find.text('同意并上传'));
      await tester.pumpAndSettle();
      expect(find.text('参与 MeowX 测速榜？'), findsNothing);
      expect(c.boardConsent, isTrue);
      expect((await SharedPreferences.getInstance()).getBool('meowx.speedTest.upload'), isTrue);

      // 同一个控制器、页面重进：不再问
      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(_app(SpeedTestPage(controller: c, boardGrant: (_) async => null)));
      await tester.pumpAndSettle();
      expect(find.text('参与 MeowX 测速榜？'), findsNothing);
      // 设置卡片里的开关是开着的
      final sw = tester.widget<Switch>(find.descendant(of: find.byType(SpeedBoardSettingRow), matching: find.byType(Switch)));
      expect(sw.value, isTrue);
    });

    testWidgets('不上传 → 存下 false；设置那一行点字看完整说明，里面能重置身份', (tester) async {
      _phone(tester);
      final c = _FakeCore().controller();
      await tester.pumpWidget(_app(SpeedTestPage(controller: c, boardGrant: (_) async => null)));
      await tester.pumpAndSettle();
      await tester.tap(find.text('不上传'));
      await tester.pumpAndSettle();
      expect(c.boardConsent, isFalse);
      expect(find.text('超越了'), findsNothing);

      await tester.ensureVisible(find.text('上传到测速榜'));
      await tester.tap(find.text('上传到测速榜'));
      await tester.pumpAndSettle();
      expect(find.text('MeowX 测速榜'), findsOneWidget);
      expect(find.text('重置测速榜身份'), findsOneWidget);
      await tester.tap(find.text('重置测速榜身份'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('重置'));
      await tester.pumpAndSettle();
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('meowx.speedTest.installId'), isNotNull);
      // 卡片里选「同意并上传」打开开关
      await tester.tap(find.text('同意并上传'));
      await tester.pumpAndSettle();
      expect(c.boardConsent, isTrue);
    });
  });

  group('② 测完后的超越比例与分享菜单', () {
    Future<SpeedTestController> runOnce(WidgetTester tester, _FakeCore core,
        {bool systemShare = true, SpeedTestShareText? shareText, SpeedTestCopyText? copyText, ValueChanged<String>? open}) async {
      SharedPreferences.setMockInitialValues({'meowx.speedTest.upload': true});
      _phone(tester);
      final c = core.controller();
      await tester.pumpWidget(_app(SpeedTestPage(
        controller: c,
        systemShare: systemShare,
        shareText: shareText,
        copyText: copyText,
        openUrl: open,
        boardGrant: (_) async => null,
        saveFile: (_, _) async => null,
        shareFile: (_, _) async {},
      )));
      await tester.pumpAndSettle();
      unawaited(c.start('香港 01', protocol: 'VLESS', protocolCode: 'vless'));
      await tester.pump();
      await tester.pump();
      return c;
    }

    testWidgets('上传中 → 超越了 82% 的测速 + 范围与样本数；点了打开测速榜', (tester) async {
      final core = _FakeCore(responses: [_resp(200, _okBody)])..hold = Completer<void>();
      final opened = <String>[];
      await runOnce(tester, core, open: opened.add);
      expect(find.text('正在上传到测速榜…'), findsOneWidget);
      core.hold!.complete();
      await tester.pumpAndSettle();
      expect(find.text('超越了 82% 的测速'), findsOneWidget);
      expect(find.text('近 30 天 · 经节点 · 多线程 · 2,431 次'), findsOneWidget);
      expect(find.byType(SpeedBoardRing), findsOneWidget);
      await tester.tap(find.text('超越了 82% 的测速'));
      expect(opened, [kSpeedBoardPage]);
      expect(core.sent.single['proxy'], '香港 01');
    });

    testWidgets('样本还少：已上传、不给比例', (tester) async {
      final core = _FakeCore(responses: [_resp(200, '{"id":"a","url":"https://speed.meowx.net/r/a","delete_token":"t","percentile":null}')]);
      await runOnce(tester, core);
      await tester.pumpAndSettle();
      expect(find.text('已上传到测速榜'), findsOneWidget);
      expect(find.text('同组样本还少，暂不给超越比例'), findsOneWidget);
    });

    testWidgets('失败：「上传失败，点此重试」，点了重传；400 写不收、不给重试；429 写几分钟后再试', (tester) async {
      final core = _FakeCore(responses: [_resp(503), _resp(200, _okBody)]);
      await runOnce(tester, core);
      await tester.pumpAndSettle();
      expect(find.text('上传失败，点此重试'), findsOneWidget);
      await tester.tap(find.text('上传失败，点此重试'));
      await tester.pumpAndSettle();
      expect(find.text('超越了 82% 的测速'), findsOneWidget);
      expect(core.sent, hasLength(2));

      await tester.pumpWidget(const SizedBox());
      final rejected = _FakeCore(responses: [_resp(400, '{"code":"bad_request"}')]);
      await runOnce(tester, rejected);
      await tester.pumpAndSettle();
      expect(find.text('测速榜没有收下这条结果'), findsOneWidget);
      await tester.tap(find.text('测速榜没有收下这条结果'));
      await tester.pumpAndSettle();
      expect(rejected.sent, hasLength(1));

      await tester.pumpWidget(const SizedBox());
      final limited = _FakeCore(responses: [json.encode({'status': 429, 'retryAfter': '600', 'body': '{"code":"rate_limited"}'})]);
      await runOnce(tester, limited);
      await tester.pumpAndSettle();
      expect(find.textContaining('10 分钟后可重试'), findsOneWidget);
    });

    testWidgets('旧核心（不认识 meowSpeedTestBoard）：上传失败「内核版本过旧」', (tester) async {
      final core = _FakeCore(responses: const []);
      await runOnce(tester, core);
      await tester.pumpAndSettle();
      expect(find.text('上传失败，点此重试'), findsOneWidget);
      expect(find.textContaining('内核版本过旧'), findsOneWidget);
    });

    testWidgets('安卓：上传了的分享按钮弹菜单「分享链接 / 分享图片 / 复制链接」，分享链接把网址交给系统分享', (tester) async {
      final shared = <String>[], copied = <String>[];
      final core = _FakeCore(responses: [_resp(200, _okBody)]);
      await runOnce(tester, core, shareText: (t) async => shared.add(t), copyText: (t) async => copied.add(t));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('分享'));
      await tester.pumpAndSettle();
      expect(find.text('分享链接'), findsOneWidget);
      expect(find.text('分享图片'), findsOneWidget);
      expect(find.text('复制链接'), findsOneWidget);
      await tester.tap(find.text('分享链接'));
      await tester.pumpAndSettle();
      expect(shared, ['https://speed.meowx.net/r/No63xGk']);

      await tester.tap(find.byTooltip('分享'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('复制链接'));
      await tester.pumpAndSettle();
      expect(copied, ['https://speed.meowx.net/r/No63xGk']);
    });

    testWidgets('Windows：菜单是「保存分享图 / 复制链接」，没有分享链接', (tester) async {
      final core = _FakeCore(responses: [_resp(200, _okBody)]);
      await runOnce(tester, core, systemShare: false);
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('分享'));
      await tester.pumpAndSettle();
      expect(find.text('保存分享图'), findsOneWidget);
      expect(find.text('复制链接'), findsOneWidget);
      expect(find.text('分享链接'), findsNothing);
    });

    testWidgets('没同意：测完没有超越比例那条，分享按钮直接出图（没有菜单）', (tester) async {
      SharedPreferences.setMockInitialValues({'meowx.speedTest.upload': false});
      _phone(tester);
      final core = _FakeCore();
      final c = core.controller();
      var shares = 0;
      await tester.pumpWidget(_app(SpeedTestPage(
        controller: c,
        systemShare: true,
        boardGrant: (_) async => null,
        shareFile: (_, _) async => shares++,
      )));
      await tester.pumpAndSettle();
      unawaited(c.start('香港 01'));
      await tester.pumpAndSettle();
      expect(core.sent, isEmpty);
      expect(find.byType(SpeedBoardStrip), findsNothing);
      expect(find.byTooltip('分享'), findsOneWidget);
    });
  });

  group('③ 记录详情的「测速榜」一组', () {
    Future<SpeedTestController> pumpRecord(WidgetTester tester, SpeedTestRecord record, _FakeCore core,
        {bool consent = true, List<String>? opened, List<String>? copied}) async {
      SharedPreferences.setMockInitialValues({'meowx.speedTest.upload': consent});
      _phone(tester, height: 1400);
      final c = core.controller();
      await c.load();
      c.history.add(record);
      await tester.pumpWidget(_app(SpeedTestRecordPage(
        controller: c,
        id: record.id,
        openUrl: (u) => opened?.add(u),
        copyText: (t) async => copied?.add(t),
      )));
      await tester.pumpAndSettle();
      return c;
    }

    testWidgets('已上传：超越比例、服务商、网页卡片链接（打开 / 复制）；删除二次确认后清掉远端字段、记录还在', (tester) async {
      final opened = <String>[], copied = <String>[];
      final core = _FakeCore(responses: [_resp(200, '{"success":true}')]);
      final c = await pumpRecord(tester, _record(board: _uploaded), core, opened: opened, copied: copied);
      expect(find.text('超越 82% ›'), findsOneWidget);
      expect(find.text('咕咕云'), findsOneWidget);
      expect(find.text('speed.meowx.net/r/No63xGk'), findsOneWidget);
      await tester.tap(find.text('超越 82% ›'));
      await tester.tap(find.text('speed.meowx.net/r/No63xGk'));
      expect(opened, [kSpeedBoardPage, 'https://speed.meowx.net/r/No63xGk']);
      await tester.tap(find.byTooltip('复制链接'));
      await tester.pump();
      expect(copied, ['https://speed.meowx.net/r/No63xGk']);

      await tester.ensureVisible(find.text('从测速榜删除'));
      await tester.tap(find.text('从测速榜删除'));
      await tester.pumpAndSettle();
      expect(find.text('从测速榜删除？'), findsOneWidget);
      await tester.tap(find.widgetWithText(TextButton, '删除'));
      await tester.pumpAndSettle();
      expect(core.sent.single['method'], 'DELETE');
      expect(c.history.byId('r1')!.board, isNull);
      expect(find.text('超越 82% ›'), findsNothing);
      expect(find.text('上传这条'), findsOneWidget); // 开着上传：删掉之后可以再传
    });

    testWidgets('没传过：开着上传给「上传这条」，点了上传；关着不显示这一组', (tester) async {
      final core = _FakeCore(responses: [_resp(200, _okBody)]);
      final c = await pumpRecord(tester, _record(), core);
      await tester.ensureVisible(find.text('上传这条'));
      await tester.tap(find.text('上传这条'));
      await tester.pumpAndSettle();
      expect(c.history.byId('r1')!.board!.isUploaded, isTrue);
      expect(find.text('超越 82% ›'), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
      await pumpRecord(tester, _record(), _FakeCore(), consent: false);
      expect(find.text('上传这条'), findsNothing);
      expect(find.byType(SpeedBoardRecordSection), findsOneWidget);
      expect(find.text('测速榜'), findsNothing);
    });

    testWidgets('失败的：原因 + 重试', (tester) async {
      final core = _FakeCore(responses: [_resp(200, _okBody)]);
      final c = await pumpRecord(tester, _record(board: SpeedBoardEntry.failure('连不上测速榜')), core);
      expect(find.text('连不上测速榜'), findsOneWidget);
      await tester.ensureVisible(find.text('重试'));
      await tester.tap(find.text('重试'));
      await tester.pumpAndSettle();
      expect(c.history.byId('r1')!.board!.isUploaded, isTrue);
    });

    testWidgets('删本机记录：上传过的先问一句', (tester) async {
      final c = await pumpRecord(tester, _record(board: _uploaded), _FakeCore());
      await tester.ensureVisible(find.widgetWithText(InkWell, '删除').last);
      await tester.tap(find.widgetWithText(InkWell, '删除').last);
      await tester.pumpAndSettle();
      expect(find.text('删除这条记录？'), findsOneWidget);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(c.history.byId('r1'), isNotNull);
    });
  });

  test('还要等多久的写法：不足一分钟按一分钟，超过一小时按小时', () {
    expect(speedBoardWaitText(const Duration(seconds: 20)), '1 分钟后可重试');
    expect(speedBoardWaitText(const Duration(minutes: 10)), '10 分钟后可重试');
    expect(speedBoardWaitText(const Duration(minutes: 90)), '2 小时后可重试');
    expect(MeowTokens.light.accent, isNotNull);
  });
}
