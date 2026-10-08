import 'package:bett_box/meowx/theme/meow_theme.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('点按水波用普通的圆形扩散：Android 上也不用 M3 默认的噪声着色器（InkSparkle）', () {
    for (final platform in const [TargetPlatform.android, TargetPlatform.windows]) {
      debugDefaultTargetPlatformOverride = platform;
      try {
        for (final brightness in Brightness.values) {
          expect(meowThemeData(brightness: brightness).splashFactory, InkRipple.splashFactory, reason: '$platform $brightness');
        }
        // 没指定时 Android 上是 InkSparkle——这条断言要是哪天不成立了，上面那行覆盖也就可以拿掉
        if (platform == TargetPlatform.android) {
          expect(ThemeData(useMaterial3: true).splashFactory, InkSparkle.splashFactory);
        }
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    }
  });
}
