import 'dart:io';

import 'package:flutter/material.dart';

import '../state/ui_prefs.dart';
import 'm3.dart';
import 'tokens.dart';

/// MeowX 主题：Material 3 Expressive。色板由种子色 + 视觉预设生成（[MeowColors.scheme]），
/// 各组件按 M3E 的形状与字重调过；旧页面用的 `context.mm` 由同一份色板推出（[MeowTokens.fromScheme]）。
ThemeData meowThemeData({
  required Brightness brightness,
  String? fontFamily,
  PageTransitionsTheme? pageTransitionsTheme,
  Color seed = MeowColors.brandSeed,
  MeowVisualPreset preset = MeowVisualPreset.crispMist,
}) {
  final cs = MeowColors.scheme(seed, brightness, preset: preset);
  final x = MeowM3.from(cs);
  const stadium = StadiumBorder();
  RoundedRectangleBorder rounded(double r) => RoundedRectangleBorder(borderRadius: BorderRadius.circular(r));

  final base = ThemeData(
    useMaterial3: true,
    brightness: brightness,
    colorScheme: cs,
    fontFamily: fontFamily,
    // Windows 自带字体没有国旗 emoji（显示成 CN / US 字母），回落到随包的 Twemoji；Linux 另加中文回落（[linuxTextFallback]）
    fontFamilyFallback: Platform.isWindows ? const ['Twemoji'] : linuxTextFallback,
    pageTransitionsTheme: pageTransitionsTheme,
    // Android 上 M3 默认的点按水波是 InkSparkle：点一下要在整块可点区域里逐像素跑约 0.6 秒的噪声着色器，
    // Android 8–9（Skia）首次点按还要现场编译它。换成普通的圆形水波（其它平台本来就是它）。
    splashFactory: InkRipple.splashFactory,
    scaffoldBackgroundColor: cs.surface,
    canvasColor: cs.surface,
    cardTheme: CardThemeData(
      color: cs.card,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: rounded(MeowShape.xl),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: cs.surfaceContainerHigh,
      surfaceTintColor: Colors.transparent,
      shape: rounded(MeowShape.xl),
      // M3 对话框标题 = headline small；Expressive 用粗字重
      titleTextStyle: TextStyle(fontSize: 24, height: 32 / 24, fontWeight: FontWeight.w800, color: cs.onSurface),
      contentTextStyle: TextStyle(fontSize: 14, height: 20 / 14, color: cs.onSurfaceVariant),
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: cs.surfaceContainerLow,
      surfaceTintColor: Colors.transparent,
      showDragHandle: true,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(MeowShape.xl))),
    ),
    // 按钮一律胶囊（M3E 的圆形按钮），最小 48 高保证点按面积
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        shape: stadium,
        minimumSize: const Size(48, 48),
        padding: const EdgeInsets.symmetric(horizontal: 24),
        textStyle: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        shape: stadium,
        minimumSize: const Size(48, 48),
        padding: const EdgeInsets.symmetric(horizontal: 24),
        side: BorderSide(color: cs.outlineVariant),
        textStyle: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(shape: stadium, textStyle: const TextStyle(fontWeight: FontWeight.w700)),
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(shape: stadium, minimumSize: const Size(48, 48)),
    ),
    segmentedButtonTheme: SegmentedButtonThemeData(style: SegmentedButton.styleFrom(shape: stadium)),
    floatingActionButtonTheme: FloatingActionButtonThemeData(
      backgroundColor: cs.primaryContainer,
      foregroundColor: cs.onPrimaryContainer,
      elevation: 2,
      shape: rounded(MeowShape.l),
      extendedTextStyle: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15),
    ),
    chipTheme: ChipThemeData(
      shape: rounded(MeowShape.s),
      side: BorderSide(color: cs.outlineVariant),
      labelStyle: const TextStyle(fontWeight: FontWeight.w600),
    ),
    checkboxTheme: CheckboxThemeData(shape: rounded(MeowShape.xs)),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: cs.surfaceContainerHighest,
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(MeowShape.l), borderSide: BorderSide.none),
      enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(MeowShape.l), borderSide: BorderSide.none),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(MeowShape.l),
        borderSide: BorderSide(color: cs.primary, width: 2),
      ),
      errorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(MeowShape.l),
        borderSide: BorderSide(color: cs.error, width: 1.5),
      ),
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(
      color: cs.primary,
      linearTrackColor: cs.secondaryContainer,
      circularTrackColor: cs.secondaryContainer,
    ),
    snackBarTheme: SnackBarThemeData(behavior: SnackBarBehavior.floating, shape: rounded(MeowShape.m)),
    popupMenuTheme: PopupMenuThemeData(
      color: cs.surfaceContainer,
      surfaceTintColor: Colors.transparent,
      shape: rounded(MeowShape.l),
    ),
    menuTheme: MenuThemeData(
      style: MenuStyle(
        backgroundColor: WidgetStatePropertyAll(cs.surfaceContainer),
        surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
        shape: WidgetStatePropertyAll(rounded(MeowShape.l)),
      ),
    ),
    dividerTheme: DividerThemeData(color: cs.outlineVariant, space: 1, thickness: 1),
    appBarTheme: AppBarTheme(
      backgroundColor: cs.surface,
      surfaceTintColor: Colors.transparent,
      scrolledUnderElevation: 0,
      foregroundColor: cs.onSurface,
    ),
    tooltipTheme: TooltipThemeData(
      decoration: BoxDecoration(color: cs.inverseSurface, borderRadius: BorderRadius.circular(MeowShape.xs)),
      textStyle: TextStyle(color: cs.onInverseSurface, fontSize: MeowFont.caption),
    ),
    extensions: [MeowTokens.fromScheme(cs), x],
  );
  // Expressive 的字：标题 / 大数字用粗字重（不打包新字体）
  final t = base.textTheme;
  TextStyle? w(TextStyle? s, FontWeight weight, [double? spacing]) =>
      s?.copyWith(fontWeight: weight, letterSpacing: spacing);
  return base.copyWith(
    textTheme: t
        .copyWith(
          displayLarge: w(t.displayLarge, FontWeight.w800, -1),
          displayMedium: w(t.displayMedium, FontWeight.w800, -0.8),
          displaySmall: w(t.displaySmall, FontWeight.w800, -0.5),
          headlineLarge: w(t.headlineLarge, FontWeight.w800, -0.5),
          headlineMedium: w(t.headlineMedium, FontWeight.w800, -0.3),
          headlineSmall: w(t.headlineSmall, FontWeight.w700),
          titleLarge: w(t.titleLarge, FontWeight.w700),
          titleMedium: w(t.titleMedium, FontWeight.w600),
          titleSmall: w(t.titleSmall, FontWeight.w600),
          labelLarge: w(t.labelLarge, FontWeight.w700),
        )
        .apply(bodyColor: cs.onSurface, displayColor: cs.onSurface),
  );
}

/// 亮 / 暗两份主题，记住上一次的结果：参数没变就还是同一对实例。
///
/// [meowThemeData] 每次现建的主题彼此不相等（里面有 WidgetStateProperty 的闭包）。MaterialApp 一重建——
/// 切语言、改任何一项主题设置——AnimatedTheme 就认为主题变了，在两份看起来一样的主题之间做 200ms 插值，
/// 这期间每一帧所有用到主题的 widget（常驻的四个 Tab 页都是）全部重建。拿到的是同一份实例它就直接跳过。
/// 切浅色 / 深色只是在这两份之间换，渐变照旧。换主题色（[seed]）才换一对新的。
class MeowThemes {
  String? _fontFamily;
  PageTransitionsTheme? _transitions;
  Color _seed = MeowColors.brandSeed;
  MeowVisualPreset _preset = MeowVisualPreset.crispMist;
  ThemeData? _light, _dark;

  ({ThemeData light, ThemeData dark}) of({
    String? fontFamily,
    PageTransitionsTheme? pageTransitionsTheme,
    Color seed = MeowColors.brandSeed,
    MeowVisualPreset preset = MeowVisualPreset.crispMist,
  }) {
    if (_light == null ||
        _fontFamily != fontFamily ||
        _transitions != pageTransitionsTheme ||
        _seed != seed ||
        _preset != preset) {
      _fontFamily = fontFamily;
      _transitions = pageTransitionsTheme;
      _seed = seed;
      _preset = preset;
      _light = meowThemeData(
        brightness: Brightness.light,
        fontFamily: fontFamily,
        pageTransitionsTheme: pageTransitionsTheme,
        seed: seed,
        preset: preset,
      );
      _dark = meowThemeData(
        brightness: Brightness.dark,
        fontFamily: fontFamily,
        pageTransitionsTheme: pageTransitionsTheme,
        seed: seed,
        preset: preset,
      );
    }
    return (light: _light!, dark: _dark!);
  }

  /// 丢掉记住的那一对，下次重新建（热重载后用：改了 token / 主题代码要立刻看到）。
  void clear() => _light = _dark = null;
}
