import 'package:bett_box/meowx/theme/haptics.dart';
import 'package:bett_box/meowx/theme/widgets.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/haptics.dart';

Widget _app(Widget child) => MaterialApp(home: Scaffold(body: Center(child: child)));

void main() {
  tearDown(() => MeowHaptics.androidSdk = 0);

  group('MeowHaptics', () {
    testWidgets('五种各对应一种系统震动（与 iOS 同一套）', (tester) async {
      final haptics = recordHaptics();
      MeowHaptics.tap();
      MeowHaptics.toggle();
      MeowHaptics.select();
      MeowHaptics.success();
      MeowHaptics.error();
      await tester.pump();
      expect(haptics, [kLight, kMedium, kSelection, kSuccess, kError]);
    });

    testWidgets('Android 11 以下没有成功 / 失败那两种：退回中 / 重', (tester) async {
      final haptics = recordHaptics();
      MeowHaptics.androidSdk = 29;
      MeowHaptics.success();
      MeowHaptics.error();
      MeowHaptics.androidSdk = 30;
      MeowHaptics.success();
      await tester.pump();
      expect(haptics, [kMedium, kHeavy, kSuccess]);
    });

    testWidgets('Windows 不调（引擎不认这个调用）', (tester) async {
      final haptics = recordHaptics();
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      MeowHaptics.tap();
      MeowHaptics.toggle();
      MeowHaptics.success();
      debugDefaultTargetPlatformOverride = null;
      await tester.pump();
      expect(haptics, isEmpty);
    });
  });

  group('电源键', () {
    testWidgets('点一下中震一次；不可用时点了不震', (tester) async {
      final haptics = recordHaptics();
      var taps = 0;
      await tester.pumpWidget(_app(MeowPowerButton(on: false, onTap: () => taps++)));
      await tester.tap(find.byType(MeowPowerButton));
      await tester.pump();
      expect(taps, 1);
      expect(haptics, [kMedium]);

      haptics.clear();
      await tester.pumpWidget(_app(MeowPowerButton(on: false, enabled: false, onTap: () => taps++)));
      await tester.tap(find.byType(MeowPowerButton), warnIfMissed: false);
      await tester.pump();
      expect(taps, 1);
      expect(haptics, isEmpty);
    });

    testWidgets('核心那边起停（状态变了、没人点）不震', (tester) async {
      final haptics = recordHaptics();
      Widget button(bool on, bool busy) => _app(MeowPowerButton(on: on, busy: busy, onTap: () {}));
      await tester.pumpWidget(button(false, false));
      await tester.pumpWidget(button(false, true));
      await tester.pumpWidget(button(true, false));
      await tester.pumpWidget(button(false, false));
      await tester.pumpAndSettle();
      expect(haptics, isEmpty);
    });
  });
}
