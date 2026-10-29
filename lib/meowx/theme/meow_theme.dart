import 'dart:io';

import 'package:flutter/material.dart';

import 'button_fill.dart';
import 'tokens.dart';

/// MeowX 主题：Material 3 骨架 + MM token（奶白 / 樱粉 / 墨色，与 iOS 改版一致），不用动态取色。
/// [look] = 「我的 › 外观」里的主题风格 / 玻璃样式 / 卡片颜色（见 [MeowTokens.resolve]）。
ThemeData meowThemeData({
  required Brightness brightness,
  String? fontFamily,
  PageTransitionsTheme? pageTransitionsTheme,
  MeowLook look = MeowLook.classic,
}) {
  final tokens = MeowTokens.resolve(brightness, look);
  // 浮层与 Bettbox 原页面的 Material 用不透明的卡片底：液态玻璃下 elev / card2 是半透明的（内容卡片的玻璃），
  // 对话框、弹出菜单这些叠在半透明上会发灰。经典主题下这两个就是 elev / card2 本身
  final solid = tokens.elevSolid;
  final solid2 = Color.alphaBlend(tokens.card2, solid);
  final scheme = ColorScheme.fromSeed(
    seedColor: tokens.accent,
    brightness: brightness,
  ).copyWith(
    primary: tokens.accent,
    onPrimary: tokens.onAccent,
    secondary: tokens.accent,
    surface: tokens.bg,
    surfaceContainerHigh: solid,
    surfaceContainerHighest: solid2,
    onSurfaceVariant: tokens.t2,
    outlineVariant: tokens.line,
    surfaceContainerLowest: solid,
    surfaceContainerLow: solid,
    surfaceContainer: solid,
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
    // Android 上 M3 默认的点按水波是 InkSparkle：点一下要在整块可点区域里逐像素跑约 0.6 秒的噪声着色器，
    // Android 8–9（Skia）首次点按还要现场编译它。换成普通的圆形水波（其它平台本来就是它）。
    splashFactory: InkRipple.splashFactory,
    scaffoldBackgroundColor: tokens.bg,
    canvasColor: tokens.bg,
    cardColor: solid,
    dialogTheme: DialogThemeData(
      backgroundColor: solid,
      surfaceTintColor: Colors.transparent,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(24))),
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: solid,
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
    // 实心主按钮：墨色底配页面底色的字（强调色只用于选中态的字和描边）；
    // 液态玻璃主题下是按钮那档静态半透明 + 细亮边、墨色字（见 button_fill.dart）
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: tokens.buttonFill(MeowButtonFill.prominent),
        foregroundColor: tokens.onProminent,
        side: tokens.glass ? tokens.buttonSide : null,
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
      color: solid,
      surfaceTintColor: Colors.transparent,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(18))),
    ),
    dividerTheme: DividerThemeData(color: tokens.line, space: 1, thickness: 1),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: solid,
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
    listTileTheme: ListTileThemeData(tileColor: solid),
    extensions: [tokens],
  );
  return base.copyWith(
    textTheme: base.textTheme.apply(bodyColor: tokens.t1, displayColor: tokens.t1),
  );
}

/// 亮 / 暗两份主题，记住上一次的结果：参数没变就还是同一对实例。
///
/// [meowThemeData] 每次现建的主题彼此不相等（里面有 WidgetStateProperty.resolveWith 的闭包）。MaterialApp 一重建——
/// 切语言、改任何一项主题设置——AnimatedTheme 就认为主题变了，在两份看起来一样的主题之间做 200ms 插值，
/// 这期间每一帧所有用到主题的 widget（常驻的四个 Tab 页都是）全部重建。拿到的是同一份实例它就直接跳过。
/// 切浅色 / 深色只是在这两份之间换，渐变照旧。改外观（[MeowLook]）才换一对新的。
class MeowThemes {
  String? _fontFamily;
  PageTransitionsTheme? _transitions;
  MeowLook _look = MeowLook.classic;
  ThemeData? _light, _dark;

  ({ThemeData light, ThemeData dark}) of({
    String? fontFamily,
    PageTransitionsTheme? pageTransitionsTheme,
    MeowLook look = MeowLook.classic,
  }) {
    if (_light == null || _fontFamily != fontFamily || _transitions != pageTransitionsTheme || _look != look) {
      _fontFamily = fontFamily;
      _transitions = pageTransitionsTheme;
      _look = look;
      _light = meowThemeData(
        brightness: Brightness.light,
        fontFamily: fontFamily,
        pageTransitionsTheme: pageTransitionsTheme,
        look: look,
      );
      _dark = meowThemeData(
        brightness: Brightness.dark,
        fontFamily: fontFamily,
        pageTransitionsTheme: pageTransitionsTheme,
        look: look,
      );
    }
    return (light: _light!, dark: _dark!);
  }

  /// 丢掉记住的那一对，下次重新建（热重载后用：改了 token / 主题代码要立刻看到）。
  void clear() => _light = _dark = null;
}
