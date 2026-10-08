import 'package:bett_box/meowx/theme/meow_theme.dart';
import 'package:bett_box/meowx/theme/tokens.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

var _probeBuilds = 0;

/// 用到主题的页面：主题每换一份实例（含插值途中的每一帧）就重建一次。
class _Probe extends StatelessWidget {
  const _Probe();

  @override
  Widget build(BuildContext context) {
    _probeBuilds++;
    return ColoredBox(color: Theme.of(context).colorScheme.surface);
  }
}

void main() {
  test('现建的两份主题彼此不相等（所以 MaterialApp 每次重建都会当成换了主题去做插值）', () {
    expect(meowThemeData(brightness: Brightness.light) == meowThemeData(brightness: Brightness.light), isFalse);
  });

  test('MeowThemes：参数不变给同一对实例，换字体 / clear 之后才重建', () {
    const transitions = PageTransitionsTheme();
    final themes = MeowThemes();
    final a = themes.of(pageTransitionsTheme: transitions);
    expect(a.light.brightness, Brightness.light);
    expect(a.dark.brightness, Brightness.dark);
    expect(a.light.extension<MeowTokens>(), MeowTokens.light);
    expect(a.dark.extension<MeowTokens>(), MeowTokens.dark);

    final b = themes.of(pageTransitionsTheme: const PageTransitionsTheme());
    expect(identical(a.light, b.light), isTrue);
    expect(identical(a.dark, b.dark), isTrue);

    final harmony = themes.of(fontFamily: 'HarmonyOS_Sans', pageTransitionsTheme: transitions);
    expect(identical(harmony.light, a.light), isFalse);
    expect(harmony.light.textTheme.bodyMedium!.fontFamily, 'HarmonyOS_Sans');
    expect(identical(themes.of(fontFamily: 'HarmonyOS_Sans', pageTransitionsTheme: transitions).dark, harmony.dark), isTrue);

    themes.clear();
    expect(identical(themes.of(fontFamily: 'HarmonyOS_Sans', pageTransitionsTheme: transitions).light, harmony.light), isFalse);
  });

  testWidgets('同一对实例：MaterialApp 重建不触发主题插值；切深色照常渐变', (tester) async {
    final themes = MeowThemes();
    Widget app(ThemeMode mode, {required bool cached}) {
      final t = cached
          ? themes.of()
          : (light: meowThemeData(brightness: Brightness.light), dark: meowThemeData(brightness: Brightness.dark));
      return MaterialApp(themeMode: mode, theme: t.light, darkTheme: t.dark, home: const _Probe());
    }

    _probeBuilds = 0;
    await tester.pumpWidget(app(ThemeMode.light, cached: true));
    expect(_probeBuilds, 1);
    // 无关的重建（切语言、改别的主题设置）：什么都不发生
    await tester.pumpWidget(app(ThemeMode.light, cached: true));
    expect(tester.binding.hasScheduledFrame, isFalse);
    expect(_probeBuilds, 1);

    // 对照：现建的主题，同样的重建会起 200ms 插值，期间用到主题的页面逐帧重建
    await tester.pumpWidget(app(ThemeMode.light, cached: false));
    expect(tester.binding.hasScheduledFrame, isTrue);
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump(const Duration(milliseconds: 50));
    expect(_probeBuilds, greaterThan(2));
    await tester.pumpAndSettle();

    // 回到缓存的那一对后切深色：渐变还在
    await tester.pumpWidget(app(ThemeMode.light, cached: true));
    await tester.pumpAndSettle();
    final before = _probeBuilds;
    await tester.pumpWidget(app(ThemeMode.dark, cached: true));
    expect(tester.binding.hasScheduledFrame, isTrue);
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump(const Duration(milliseconds: 50));
    expect(_probeBuilds, greaterThan(before + 1));
    await tester.pumpAndSettle();
    expect(Theme.of(tester.element(find.byType(_Probe))).brightness, Brightness.dark);
  });
}
