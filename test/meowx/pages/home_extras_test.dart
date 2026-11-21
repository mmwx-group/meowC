import 'package:bett_box/meowx/pages/dashboard/memory_report.dart';
import 'package:bett_box/meowx/pages/dashboard/speed_test_card.dart';
import 'package:bett_box/models/models.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('内存构成（同 iOS）：核心状态逐项列出，常驻那一项与首页内存格同口径', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MemoryReport(
            fetch: () async => const CoreStatus(
              physical: 50 * 1024 * 1024,
              inUse: 40 * 1024 * 1024,
              reclaimable: 10 * 1024 * 1024,
              goroutines: 123,
              heapObjects: 45678,
              rules: 3200,
              proxies: 12,
              proxyGroups: 7,
              geodataUse: 'MMDB, Site',
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.text('核心内存构成'), findsOneWidget);
    expect(find.text('协程'), findsOneWidget);
    expect(find.text('123'), findsOneWidget);
    expect(find.text('3200'), findsOneWidget);
    expect(find.text('MMDB, Site'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());   // 收掉 3 秒一次的定时器
  });

  testWidgets('首页「网络测速」卡：没测过时是空状态 + 开始测速 / 记录', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(const MaterialApp(home: Scaffold(body: SingleChildScrollView(child: HomeSpeedTestCard()))));
    await tester.pump();
    expect(find.text('网络测速'), findsOneWidget);
    expect(find.textContaining('还没有测过'), findsOneWidget);
    expect(find.text('开始测速'), findsOneWidget);
    expect(find.text('记录'), findsOneWidget);   // 标题行右侧的轻量按钮（2026-11-22 起从「测速记录」改短）
  });
}
