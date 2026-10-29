import 'dart:async';
import 'dart:convert';

import 'package:bett_box/enum/enum.dart';
import 'package:bett_box/meowx/pages/speedtest/speed_test_history_page.dart';
import 'package:bett_box/meowx/pages/speedtest/speed_test_page.dart';
import 'package:bett_box/meowx/state/connection.dart';
import 'package:bett_box/meowx/state/speed_test.dart';
import 'package:bett_box/meowx/state/speed_test_network.dart';
import 'package:bett_box/meowx/state/status.dart';
import 'package:bett_box/meowx/theme/meow_theme.dart';
import 'package:bett_box/models/models.dart';
import 'package:bett_box/providers/providers.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wifi_ssid/wifi_ssid.dart';

/// 测速记录里的「网络」（Wi-Fi / 5G / 4G / 3G / 2G / 移动数据 / 有线网络，与 iOS / macOS 同一组文字）：
/// 制式码 → 代、connectivity 结果 → 物理网络、记录读写、控制器在开始时取、详情页与测速页的显示。
void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('取值', () {
    test('制式码（TelephonyManager.NETWORK_TYPE_*）→ 代：NR = 5G、LTE / LTE_CA = 4G、HSPA 一族 = 3G、EDGE 一族 = 2G，其余 null', () {
      expect(cellularGeneration(20), '5G'); // NR
      expect(cellularGeneration(13), '4G'); // LTE
      expect(cellularGeneration(19), '4G'); // LTE_CA
      for (final code in [3, 5, 6, 8, 9, 10, 12, 14, 15, 17]) {
        expect(cellularGeneration(code), '3G', reason: '$code'); // UMTS / EVDO / HSxPA / EHRPD / TD_SCDMA
      }
      for (final code in [1, 2, 4, 7, 11, 16]) {
        expect(cellularGeneration(code), '2G', reason: '$code'); // GPRS / EDGE / CDMA / 1xRTT / IDEN / GSM
      }
      // 未知、IWLAN（Wi-Fi 通话）、以后新加的码、取不到
      for (final code in [0, 18, 21, 99, -1, null]) {
        expect(cellularGeneration(code), isNull, reason: '$code');
      }
    });

    test('connectivity 结果 → 本机物理网络：VPN 不算；Wi-Fi > 有线 > 蜂窝；别的都取不到', () {
      const vpn = ConnectivityResult.vpn, wifi = ConnectivityResult.wifi, mobile = ConnectivityResult.mobile;
      const ethernet = ConnectivityResult.ethernet;
      // 开着 MeowX 自己的 VPN：安卓回 VPN 网络带着的底层类型
      expect(physicalNetworkOf([vpn, wifi]), wifi);
      expect(physicalNetworkOf([wifi, vpn]), wifi);
      expect(physicalNetworkOf([vpn, mobile]), mobile);
      expect(physicalNetworkOf([vpn, ethernet]), ethernet);
      // 没开 VPN
      expect(physicalNetworkOf([wifi]), wifi);
      expect(physicalNetworkOf([mobile]), mobile);
      // 几种同时在（Windows 的虚拟网卡也报成有线）
      expect(physicalNetworkOf([ethernet, wifi]), wifi);
      expect(physicalNetworkOf([mobile, wifi]), wifi);
      expect(physicalNetworkOf([mobile, ethernet]), ethernet);
      // 取不到
      for (final r in [
        <ConnectivityResult>[],
        [vpn],
        [ConnectivityResult.none],
        [ConnectivityResult.other],
        [ConnectivityResult.bluetooth],
        [ConnectivityResult.satellite],
      ]) {
        expect(physicalNetworkOf(r), isNull, reason: '$r');
      }
    });

    test('显示文字：蜂窝按制式分代，分不出写「移动数据」；Wi-Fi、有线网络；取不到 null', () {
      String? label(List<ConnectivityResult> r, [int? subtype]) =>
          speedTestNetworkLabel(physicalNetworkOf(r), cellularSubtype: subtype);
      expect(label([ConnectivityResult.vpn, ConnectivityResult.wifi], 20), 'Wi-Fi'); // 制式只给蜂窝用
      expect(label([ConnectivityResult.vpn, ConnectivityResult.mobile], 20), '5G');
      expect(label([ConnectivityResult.vpn, ConnectivityResult.mobile], 13), '4G');
      expect(label([ConnectivityResult.mobile], 10), '3G');
      expect(label([ConnectivityResult.mobile], 2), '2G');
      expect(label([ConnectivityResult.mobile], 18), '移动数据');
      expect(label([ConnectivityResult.mobile]), '移动数据'); // Windows / 原生取不到
      expect(label([ConnectivityResult.ethernet]), '有线网络');
      expect(label([ConnectivityResult.vpn]), isNull);
      expect(label([ConnectivityResult.none]), isNull);
    });

    test('wifi_ssid 的 getNetworkState 多带蜂窝制式；没有这个字段（旧原生 / 没有蜂窝）是 null', () {
      expect(WifiNetworkState.fromMap(const {'cellular': true, 'cellularSubtype': 20}).cellularSubtype, 20);
      expect(WifiNetworkState.fromMap(const {'cellular': true, 'cellularSubtype': null}).cellularSubtype, isNull);
      expect(WifiNetworkState.fromMap(const {'wifi': true}).cellularSubtype, isNull);
      expect(WifiNetworkState.fromMap(const {'cellularSubtype': '20'}).cellularSubtype, isNull);
    });
  });

  group('测速记录', () {
    test('JSON：记了就存「network」，读回来一样；没取到不写这个字段；旧记录没有就是 null', () {
      SpeedTestRecord made(String? network) => SpeedTestRecord.fromProgress(
        const SpeedTestProgress(phase: 'done', downloadMbps: 10),
        source: SpeedTestSource.apple,
        connections: 1,
        outbound: '东京 02',
        network: network,
      )!;
      final r = made('5G');
      expect(r.network, '5G');
      expect(r.toJson()['network'], '5G');
      final back = SpeedTestRecord.fromJson(json.decode(json.encode(r.toJson())) as Map<String, Object?>)!;
      expect(back.network, '5G');
      expect(back.toJson(), r.toJson());

      final none = made(null);
      expect(none.toJson().containsKey('network'), isFalse);
      expect(SpeedTestRecord.fromJson(json.decode(json.encode(none.toJson())) as Map<String, Object?>)!.network, isNull);
      final old = SpeedTestRecord.fromJson(const {'id': 'a', 'date': 1700000000, 'outbound': 'x'})!;
      expect(old.network, isNull);
      // 失败的也记
      final failed = SpeedTestRecord.fromProgress(
        const SpeedTestProgress(phase: 'failed', error: '连不上'),
        source: SpeedTestSource.apple,
        connections: 1,
        outbound: 'x',
        network: 'Wi-Fi',
      )!;
      expect((failed.failed, failed.network), (true, 'Wi-Fi'));
    });

    test('落盘再读出来带着网络', () async {
      final history = SpeedTestHistory();
      history.add(SpeedTestRecord(
        id: 'n1',
        date: DateTime(2026, 10, 29, 14, 32),
        source: SpeedTestSource.google,
        connections: 1,
        outbound: kSpeedTestDirect,
        downloadMbps: 88,
        network: '有线网络',
      ));
      await history.flush();
      final reloaded = SpeedTestHistory();
      await reloaded.load();
      expect(reloaded.records.single.network, '有线网络');
    });

    test('控制器：点开始时取一次本机网络，记进这次的记录；取不到不记；再开测先清掉上一次的', () async {
      var probes = 0;
      String? next = 'Wi-Fi';
      final c = SpeedTestController(
        call: (method, data) async =>
            method == ActionMethod.meowSpeedTestStatus ? '{"runID":1,"phase":"done","downloadMbps":120}' : '',
        networkProbe: () async {
          probes++;
          return next;
        },
      );
      expect(c.network, isNull);
      await c.start('香港 01');
      expect(probes, 1);
      expect(c.network, 'Wi-Fi');
      expect(c.history.records.single.network, 'Wi-Fi');

      next = null;
      await c.start('香港 01');
      expect(probes, 2);
      expect(c.network, isNull);
      expect(c.history.records.first.network, isNull);
      expect(c.history.records.last.network, 'Wi-Fi');
    });

    test('控制器：取网络不拖住开测（取到之前核心已经在测）', () async {
      final probe = Completer<String?>();
      final calls = <ActionMethod>[];
      final c = SpeedTestController(
        call: (method, data) async {
          calls.add(method);
          return method == ActionMethod.meowSpeedTestStatus ? '{"runID":1,"phase":"download","currentMbps":10}' : '';
        },
        networkProbe: () => probe.future,
      );
      unawaited(c.start('香港 01'));
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(calls, contains(ActionMethod.meowSpeedTestStart));
      expect(c.network, isNull);
      probe.complete('4G');
      await Future<void>.delayed(Duration.zero);
      expect(c.network, '4G');
      c.stop();
    });
  });

  group('显示', () {
    final theme = meowThemeData(brightness: Brightness.light);

    SpeedTestRecord record({String? network}) => SpeedTestRecord(
      id: 'r',
      date: DateTime(2026, 10, 29, 14, 32),
      source: SpeedTestSource.apple,
      connections: 8,
      outbound: '东京 02',
      downloadMbps: 88,
      bytesUsed: 5 * 1024 * 1024,
      network: network,
    );

    testWidgets('记录详情：参数表在「测速源 · 线程」之后多一行「网络」；旧记录 / 没取到没有这一行', (tester) async {
      Widget app(SpeedTestRecord r) => MaterialApp(
        theme: theme,
        home: Scaffold(body: SingleChildScrollView(child: SpeedTestRecordDetail(record: r))),
      );
      await tester.pumpWidget(app(record(network: '5G')));
      expect(find.text('网络'), findsOneWidget);
      expect(find.text('5G'), findsOneWidget);
      final source = tester.getTopLeft(find.text('测速源 · 线程')).dy;
      final net = tester.getTopLeft(find.text('网络')).dy;
      final used = tester.getTopLeft(find.text('用量')).dy;
      expect(source < net && net < used, isTrue, reason: '$source / $net / $used');

      await tester.pumpWidget(app(record()));
      expect(find.text('网络'), findsNothing);
      expect(find.text('测速源 · 线程'), findsOneWidget);
    });

    group('测速页「已用」那一行', () {
      const used = 110.5 * 1024 * 1024;
      final downloading = '{"runID":1,"phase":"download","via":"香港 01","server":"s1","currentMbps":200,'
          '"bytesUsed":${used.round()}}';
      final done = '{"runID":1,"phase":"done","via":"香港 01","server":"s1","downloadMbps":486,"bytesUsed":${used.round()}}';

      Future<SpeedTestController> pump(WidgetTester tester, String? network) async {
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
                      all: const [Proxy(name: '香港 01', type: 'Vless')],
                    ),
                  ],
                ),
              ),
              currentNodeProvider.overrideWithValue(CurrentNode(group: '节点选择', path: const ['节点选择'], leaf: '香港 01')),
            ],
            child: MaterialApp(theme: theme, home: SpeedTestPage(controller: c)),
          ),
        );
        await tester.pump();
        return c;
      }

      testWidgets('取到网络：测的时候与测完都写成「Wi-Fi · 已用 110.5 MB」（同一行，不加新行）', (tester) async {
        final c = await pump(tester, 'Wi-Fi');
        unawaited(c.start('香港 01'));
        await tester.pump();
        expect(c.progress.phase, 'download');
        expect(find.text('Wi-Fi · 已用 110.5 MB'), findsOneWidget);
        expect(find.text('已用 110.5 MB'), findsNothing);
        await tester.pump(const Duration(milliseconds: 300));
        await tester.pump();
        expect(c.progress.phase, 'done');
        expect(find.text('Wi-Fi · 已用 110.5 MB'), findsOneWidget);
        expect(c.history.records.single.network, 'Wi-Fi');
        await tester.pump(const Duration(seconds: 1));
      });

      testWidgets('取不到网络：保持原样「已用 110.5 MB」', (tester) async {
        final c = await pump(tester, null);
        unawaited(c.start('香港 01'));
        await tester.pump();
        expect(find.text('已用 110.5 MB'), findsOneWidget);
        expect(find.textContaining(' · 已用'), findsNothing);
        await tester.pump(const Duration(milliseconds: 300));
        await tester.pump();
        expect(c.progress.phase, 'done');
        expect(find.text('已用 110.5 MB'), findsOneWidget);
        await tester.pump(const Duration(seconds: 1));
      });
    });
  });
}
