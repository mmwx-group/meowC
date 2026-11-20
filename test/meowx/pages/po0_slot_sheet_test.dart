import 'package:bett_box/meowx/pages/settings/whitelist_widgets.dart';
import 'package:bett_box/meowx/panel/po0.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

// po0 槽位气泡的内容（规格：MeowX 仓库 Design/po0-ggy-results.md §2、§1.1「缺字段时信 200」）。

Future<void> _pump(WidgetTester tester, Po0Result? r, DateTime now) => tester.pumpWidget(
  MaterialApp(
    home: Scaffold(body: SingleChildScrollView(child: Po0SlotSheet(result: r, now: now))),
  ),
);

void main() {
  final now = DateTime(2026, 11, 20, 14, 30);
  final at = now.subtract(const Duration(minutes: 2));

  testWidgets('完整应答：概况、名单（槽位 / 本机）、空位、底部三行', (tester) async {
    final r = Po0Result.judge(
      const Po0ReportResult(
        url: 'https://203.0.113.9/api/firewall/pgnfw_FAKEtoken00001234/add',
        status: 200,
        body: '{"enabled":true,"whitelist":[{"ip":"5.6.7.8","slot":1},"1.2.3.77"],"limit":4,"currentIp":"1.2.3.0/24"}',
      ),
      at: at,
    );
    await _pump(tester, r, now);
    expect(find.text('防火墙已开启 · 名单 2/4'), findsOneWidget);
    expect(find.text('槽位 1'), findsOneWidget);
    expect(find.text('本机'), findsOneWidget);
    expect(find.text('空位'), findsNWidgets(2));
    expect(find.text('本机出口 1.2.3.0/24'), findsOneWidget);
    expect(find.text('本机未固定槽位，名单满时最久没上报的会被挤掉'), findsOneWidget);
    expect(find.text('上次上报 2 分钟前'), findsOneWidget);
  });

  testWidgets('老版 po0 只回确认（{}）：不画名单、不标本机、不补空位', (tester) async {
    final r = Po0Result.judge(
      const Po0ReportResult(url: 'https://203.0.113.9/api/firewall/pgnfw_FAKEtoken00001234/add?slot=3', status: 200, body: '{}'),
      at: at,
    );
    await _pump(tester, r, now);
    expect(find.text('防火墙已开启'), findsOneWidget);
    expect(find.text('本机'), findsNothing);
    expect(find.text('空位'), findsNothing);
    expect(find.textContaining('本机出口'), findsNothing);
    expect(find.text('本机使用槽位 3'), findsOneWidget);
    expect(find.text('上次上报 2 分钟前'), findsOneWidget);
  });

  testWidgets('没有 200 结果：只写那句结果与时间；还没报过写「还没上报」', (tester) async {
    final r = Po0Result.judge(
      const Po0ReportResult(url: 'https://203.0.113.9/api/firewall/pgnfw_FAKEtoken00001234/add', status: 403),
      at: at,
    );
    await _pump(tester, r, now);
    expect(find.text('token 无效'), findsOneWidget);
    expect(find.text('上次上报 2 分钟前'), findsOneWidget);
    expect(find.textContaining('防火墙'), findsNothing);
    await _pump(tester, null, now);
    expect(find.text('还没上报'), findsOneWidget);
  });
}
