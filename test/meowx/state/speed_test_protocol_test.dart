import 'dart:convert';

import 'package:bett_box/enum/enum.dart';
import 'package:bett_box/meowx/pages/speedtest/speed_test_history_page.dart';
import 'package:bett_box/meowx/pages/speedtest/speed_test_page.dart';
import 'package:bett_box/meowx/state/connection.dart';
import 'package:bett_box/meowx/state/speed_test.dart';
import 'package:bett_box/meowx/state/status.dart';
import 'package:bett_box/meowx/theme/meow_theme.dart';
import 'package:bett_box/models/models.dart';
import 'package:bett_box/providers/providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 测速记录里的「协议」（节点协议只到顶层，与 iOS / macOS 同一张表）：type → 显示名、记录读写、控制器在开始时记、
/// 详情页与测速页的显示。
void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('显示名', () {
    test('配置里的小写 type 与核心 proxies 里的写法都认，映射成固定的显示名', () {
      const table = {
        'ss': 'Shadowsocks',
        'shadowsocks': 'Shadowsocks',
        'vmess': 'VMess',
        'vless': 'VLESS',
        'trojan': 'Trojan',
        'hysteria2': 'Hysteria2',
        'hysteria': 'Hysteria',
        'tuic': 'TUIC',
        'socks5': 'SOCKS5',
        'http': 'HTTP',
        'anytls': 'AnyTLS',
        'mieru': 'Mieru',
        'wireguard': 'WireGuard',
        'miu': 'Miu',
        'snell': 'Snell',
        'ssh': 'SSH',
      };
      for (final MapEntry(key: type, value: title) in table.entries) {
        expect(speedTestProtocolTitle(type), title, reason: type);
        expect(speedTestProtocolTitle(type.toUpperCase()), title, reason: type.toUpperCase());
      }
      // 核心（mihomo）的 AdapterType.String() 写法
      for (final (type, title) in const [
        ('Shadowsocks', 'Shadowsocks'),
        ('Vmess', 'VMess'),
        ('Vless', 'VLESS'),
        ('Trojan', 'Trojan'),
        ('Hysteria2', 'Hysteria2'),
        ('Tuic', 'TUIC'),
        ('Socks5', 'SOCKS5'),
        ('Http', 'HTTP'),
        ('AnyTLS', 'AnyTLS'),
        ('WireGuard', 'WireGuard'),
        ('Ssh', 'SSH'),
        ('Miu', 'Miu'),
        ('Snell', 'Snell'),
      ]) {
        expect(speedTestProtocolTitle(type), title, reason: type);
      }
    });

    test('表里没有的原样显示（去掉首尾空白）；空 / null 没有协议', () {
      expect(speedTestProtocolTitle('ShadowsocksR'), 'ShadowsocksR');
      expect(speedTestProtocolTitle('Sudoku'), 'Sudoku');
      expect(speedTestProtocolTitle(' Masque '), 'Masque');
      expect(speedTestProtocolTitle(''), isNull);
      expect(speedTestProtocolTitle('  '), isNull);
      expect(speedTestProtocolTitle(null), isNull);
    });
  });

  group('测速记录', () {
    SpeedTestRecord made({String? protocol, String outbound = '东京 02', String phase = 'done'}) => SpeedTestRecord.fromProgress(
      SpeedTestProgress(phase: phase, downloadMbps: 10, error: phase == 'failed' ? '连不上' : null),
      source: SpeedTestSource.apple,
      connections: 1,
      outbound: outbound,
      protocol: protocol,
    )!;

    test('JSON：记了就存「protocol」，读回来一样；没有不写这个字段；旧记录没有就是 null', () {
      final r = made(protocol: 'VLESS');
      expect(r.protocol, 'VLESS');
      expect(r.toJson()['protocol'], 'VLESS');
      final back = SpeedTestRecord.fromJson(json.decode(json.encode(r.toJson())) as Map<String, Object?>)!;
      expect(back.protocol, 'VLESS');
      expect(back.toJson(), r.toJson());

      final none = made();
      expect(none.toJson().containsKey('protocol'), isFalse);
      expect(SpeedTestRecord.fromJson(json.decode(json.encode(none.toJson())) as Map<String, Object?>)!.protocol, isNull);
      final old = SpeedTestRecord.fromJson(const {'id': 'a', 'date': 1700000000, 'outbound': 'x'})!;
      expect(old.protocol, isNull);
      // 失败的也记
      expect(made(protocol: 'Hysteria2', phase: 'failed').protocol, 'Hysteria2');
    });

    test('落盘再读出来带着协议', () async {
      final history = SpeedTestHistory();
      history.add(SpeedTestRecord(
        id: 'p1',
        date: DateTime(2026, 10, 29, 14, 32),
        source: SpeedTestSource.google,
        connections: 1,
        outbound: '东京 02',
        downloadMbps: 88,
        protocol: 'Shadowsocks',
      ));
      await history.flush();
      final reloaded = SpeedTestHistory();
      await reloaded.load();
      expect(reloaded.records.single.protocol, 'Shadowsocks');
    });

    test('控制器：开始时传进来的协议记进这次的记录；直连不记；再开测换成新的', () async {
      final c = SpeedTestController(
        call: (method, data) async =>
            method == ActionMethod.meowSpeedTestStatus ? '{"runID":1,"phase":"done","downloadMbps":120}' : '',
        networkProbe: () async => null,
      );
      expect(c.protocol, isNull);
      await c.start('香港 01', protocol: 'VLESS');
      expect(c.protocol, 'VLESS');
      expect(c.history.records.single.protocol, 'VLESS');

      // 直连：哪怕传了也不记
      await c.start(kSpeedTestDirect, protocol: 'VLESS');
      expect(c.protocol, isNull);
      expect(c.history.records.first.protocol, isNull);

      // 没传（查不到 type）
      await c.start('香港 01');
      expect(c.protocol, isNull);
      expect(c.history.records.first.protocol, isNull);
      expect(c.history.records.last.protocol, 'VLESS');
    });
  });

  group('显示', () {
    final theme = meowThemeData(brightness: Brightness.light);

    SpeedTestRecord record({String? protocol}) => SpeedTestRecord(
      id: 'r',
      date: DateTime(2026, 10, 29, 14, 32),
      source: SpeedTestSource.apple,
      connections: 8,
      outbound: '东京 02',
      downloadMbps: 88,
      bytesUsed: 5 * 1024 * 1024,
      network: '5G',
      protocol: protocol,
    );

    testWidgets('记录详情：参数表在「经由」之后多一行「协议」；没有就没有这一行', (tester) async {
      Widget app(SpeedTestRecord r) => MaterialApp(
        theme: theme,
        home: Scaffold(body: SingleChildScrollView(child: SpeedTestRecordDetail(record: r))),
      );
      await tester.pumpWidget(app(record(protocol: 'VLESS')));
      expect(find.text('协议'), findsOneWidget);
      expect(find.text('VLESS'), findsOneWidget);
      final via = tester.getTopLeft(find.text('经由')).dy;
      final protocol = tester.getTopLeft(find.text('协议')).dy;
      final server = tester.getTopLeft(find.text('测速服务器')).dy;
      expect(via < protocol && protocol < server, isTrue, reason: '$via / $protocol / $server');

      await tester.pumpWidget(app(record()));
      expect(find.text('协议'), findsNothing);
      expect(find.text('经由'), findsOneWidget);
    });

    group('测速页「已用」那一行', () {
      const used = 110.5 * 1024 * 1024;
      final downloading = '{"runID":1,"phase":"download","via":"香港 01","server":"s1","currentMbps":200,'
          '"bytesUsed":${used.round()}}';
      final done = '{"runID":1,"phase":"done","via":"香港 01","server":"s1","downloadMbps":486,"bytesUsed":${used.round()}}';

      /// 节点选择组里「香港 01」的 type 是 [type]；[network] 是本机网络。
      /// 点「开始测速」前页面会用 connectivity_plus 查一次是不是移动数据（蜂窝要先确认）：测试里把它的 method channel 换成 Wi-Fi
      Future<SpeedTestController> pump(WidgetTester tester, {required String type, String? network}) async {
        tester.view.devicePixelRatio = 3;
        tester.view.physicalSize = const Size(360 * 3, 1000 * 3);
        addTearDown(tester.view.reset);
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          const MethodChannel('dev.fluttercommunity.plus/connectivity'),
          (call) async => call.method == 'check' ? ['wifi'] : null,
        );
        final statuses = [downloading, done];
        final c = SpeedTestController(
          call: (method, data) async => switch (method) {
            ActionMethod.meowSpeedTestStatus => statuses.length > 1 ? statuses.removeAt(0) : statuses.first,
            _ => '',
          },
          networkProbe: () async => network,
        );
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              isRunningProvider.overrideWithValue(true),
              currentGroupsStateProvider.overrideWithValue(
                GroupsState(
                  value: [
                    Group(
                      name: '节点选择',
                      type: GroupType.Selector,
                      now: '香港 01',
                      all: [Proxy(name: '香港 01', type: type), const Proxy(name: 'DIRECT', type: 'Direct')],
                    ),
                  ],
                ),
              ),
              currentNodeProvider.overrideWithValue(CurrentNode(group: '节点选择', path: const ['节点选择'], leaf: '香港 01')),
            ],
            // 同一个测试里再 pump 一次时换新的 State（否则页面还抓着上一个控制器）
            child: MaterialApp(theme: theme, home: SpeedTestPage(key: UniqueKey(), controller: c)),
          ),
        );
        await tester.pump();
        return c;
      }

      /// 点「开始测速」：先滚到看得见，点了之后等页面查完 connectivity（假回包）、控制器开测
      Future<void> tapStart(WidgetTester tester) async {
        await tester.ensureVisible(find.text('开始测速'));
        await tester.tap(find.text('开始测速'));
        await tester.pump();
        await tester.pump();
      }

      testWidgets('点开始按选的节点查到协议：测的时候与测完都写成「VLESS · Wi-Fi · 已用 110.5 MB」，记进记录', (tester) async {
        final c = await pump(tester, type: 'Vless', network: 'Wi-Fi');
        await tapStart(tester);
        expect(c.progress.phase, 'download');
        expect(find.text('VLESS · Wi-Fi · 已用 110.5 MB'), findsOneWidget);
        await tester.pump(const Duration(milliseconds: 300));
        await tester.pump();
        expect(c.progress.phase, 'done');
        expect(find.text('VLESS · Wi-Fi · 已用 110.5 MB'), findsOneWidget);
        expect(c.history.records.single.protocol, 'VLESS');
        expect(c.history.records.single.network, 'Wi-Fi');
        await tester.pump(const Duration(seconds: 1));
      });

      testWidgets('没取到网络：「Shadowsocks · 已用 110.5 MB」；两样都没有保持原样「已用 110.5 MB」', (tester) async {
        var c = await pump(tester, type: 'ss');
        await tapStart(tester);
        expect(find.text('Shadowsocks · 已用 110.5 MB'), findsOneWidget);
        await tester.pump(const Duration(milliseconds: 300));
        await tester.pump();
        expect(c.history.records.single.protocol, 'Shadowsocks');

        // 查不到 type（核心给了空的）
        c = await pump(tester, type: '');
        await tapStart(tester);
        expect(find.text('已用 110.5 MB'), findsOneWidget);
        expect(find.textContaining(' · 已用'), findsNothing);
        await tester.pump(const Duration(milliseconds: 300));
        await tester.pump();
        // 新控制器从本机记录里读回了上一条，这次的在最前
        expect(c.history.records.length, 2);
        expect(c.history.records.first.protocol, isNull);
        expect(c.history.records.last.protocol, 'Shadowsocks');
        await tester.pump(const Duration(seconds: 1));
      });

      testWidgets('直连测速没有协议', (tester) async {
        final c = await pump(tester, type: 'Vless', network: 'Wi-Fi');
        c.setNode(kSpeedTestDirect);
        await tester.pump();
        await tapStart(tester);
        expect(c.protocol, isNull);
        expect(find.text('Wi-Fi · 已用 110.5 MB'), findsOneWidget);
        await tester.pump(const Duration(milliseconds: 300));
        await tester.pump();
        expect(c.history.records.single.protocol, isNull);
        expect(c.history.records.single.isDirect, isTrue);
        await tester.pump(const Duration(seconds: 1));
      });
    });
  });
}
