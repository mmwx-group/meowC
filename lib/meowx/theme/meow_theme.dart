import 'dart:io';

import 'package:flutter/material.dart';

import 'tokens.dart';

/// MeowX 主题：Material 3 骨架 + MM token（奶白 / 樱粉 / 墨色，与 iOS 改版一致），不用动态取色。
ThemeData meowThemeData({
  required Brightness brightness,
  String? fontFamily,
  PageTransitionsTheme? pageTransitionsTheme,
}) {
  final tokens = brightness == Brightness.dark ? MeowTokens.dark : MeowTokens.light;
  final scheme = ColorScheme.fromSeed(
    seedColor: tokens.accent,
    brightness: brightness,
  ).copyWith(
    primary: tokens.accent,
    onPrimary: tokens.onAccent,
    secondary: tokens.accent,
    surface: tokens.bg,
    surfaceContainerHigh: tokens.elev,
    surfaceContainerHighest: tokens.card2,
    onSurfaceVariant: tokens.t2,
    outlineVariant: tokens.line,
    surfaceContainerLowest: tokens.elev,
    surfaceContainerLow: tokens.elev,
    surfaceContainer: tokens.elev,
    onSurface: tokens.t1,
    error: tokens.slow,
  );
  final base = ThemeData(
    useMaterial3: true,
    brightness: brightness,
    colorScheme: scheme,
    fontFamily: fontFamily,
    // Windows 自带字体没有国旗 emoji（显示成 CN / US 字母），回落到随包的 Twemoji
    fontFamilyFallback: Platform.isWindows ? const ['Twemoji'] : null,
    pageTransitionsTheme: pageTransitionsTheme,
    scaffoldBackgroundColor: tokens.bg,
    canvasColor: tokens.bg,
    cardColor: tokens.elev,
    dialogTheme: DialogThemeData(
      backgroundColor: tokens.elev,
      surfaceTintColor: Colors.transparent,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(24))),
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: tokens.elev,
      surfaceTintColor: Colors.transparent,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
    ),
    // 开关：打开 = 樱粉轨 + 白钮；关闭 = 次级底轨 + 白钮（设计稿的胶囊开关，两态的钮一样大）。
    // M3 的 Switch 关闭态钮只有 16；给一个透明的 thumbIcon 它就两态都画 24 的钮。
    switchTheme: SwitchThemeData(
      thumbIcon: const WidgetStatePropertyAll(Icon(Icons.circle, color: Colors.transparent)),
      thumbColor: const WidgetStatePropertyAll(Colors.white),
      trackColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.selected) ? tokens.btnOn : tokens.card2,
      ),
      trackOutlineColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.selected) ? Colors.transparent : tokens.line,
      ),
    ),
    // 实心主按钮：墨色底配页面底色的字（强调色只用于选中态的字和描边）
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: tokens.t1,
        foregroundColor: tokens.bg,
        shape: const RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(16))),
        minimumSize: const Size(44, 44),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: tokens.t1,
        side: BorderSide(color: tokens.line),
        shape: const RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(16))),
        minimumSize: const Size(44, 44),
      ),
    ),
    textButtonTheme: TextButtonThemeData(style: TextButton.styleFrom(foregroundColor: tokens.accent)),
    checkboxTheme: CheckboxThemeData(
      fillColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.selected) ? tokens.accent : Colors.transparent,
      ),
      checkColor: WidgetStatePropertyAll(tokens.onAccent),
      side: BorderSide(color: tokens.t2, width: 2),
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(7))),
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(color: tokens.accent, linearTrackColor: tokens.card2),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: tokens.t1,
      contentTextStyle: TextStyle(color: tokens.bg),
      behavior: SnackBarBehavior.floating,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(16))),
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: tokens.elev,
      surfaceTintColor: Colors.transparent,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(18))),
    ),
    dividerTheme: DividerThemeData(color: tokens.line, space: 1, thickness: 1),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: tokens.elev,
      indicatorColor: tokens.accent.withValues(alpha: 0.14),
      labelTextStyle: WidgetStatePropertyAll(
        TextStyle(fontSize: MeowFont.caption2, fontWeight: FontWeight.w500, color: tokens.t1),
      ),
    ),
    appBarTheme: AppBarTheme(
      backgroundColor: tokens.bg,
      surfaceTintColor: Colors.transparent,
      foregroundColor: tokens.t1,
    ),
    listTileTheme: ListTileThemeData(tileColor: tokens.elev),
    extensions: [tokens],
  );
  return base.copyWith(
    textTheme: base.textTheme.apply(bodyColor: tokens.t1, displayColor: tokens.t1),
  );
}
