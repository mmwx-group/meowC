import 'package:flutter/material.dart';

import 'tokens.dart';

/// 按钮底的种类（同 iOS 的 meowButtonFill）。经典主题下分别是：
/// [prominent] 墨色实心（主操作，配页面底色的字）/ [accent] 淡粉（玫红字）/ [plain] 卡片底 / [secondary] 卡片里的次级底 /
/// [danger] 淡红 / [selected] 选中的筛选胶囊、分段（墨色实心，配页面底色的字）。
enum MeowButtonFill { prominent, accent, plain, secondary, danger, selected }

/// 液态玻璃主题下按钮不再是实色块（用户 2026-10-28：「启动按钮和切换订阅的按钮，还有其他地方的按钮，还是纯色」）：
/// 静态半透明 = 卡片次级块那档白（[MeowTokens.card2]）+ 一点主题色 + 0.8 的细亮边，不做实时模糊——
/// iOS 真机实测卡片里的玻璃按钮一多就掉帧，最后定的就是这种静态画法。浮在页面上的那几块真玻璃（页头圆钮、电源键、首页模式分段的滑块）不走这里。
/// 经典主题：各调用点原来的实色，一个像素不变（没有描边）。
extension MeowButtonColors on MeowTokens {
  /// 按钮底色。[classic] = 这个调用点在经典主题下原来的颜色和缺省的那一档不一样时传（如深色下叠到卡片底上的淡粉）
  Color buttonFill(MeowButtonFill kind, {Color? classic}) {
    if (!glass) {
      return classic ??
          switch (kind) {
            MeowButtonFill.prominent || MeowButtonFill.selected => t1,
            MeowButtonFill.accent => soft,
            MeowButtonFill.plain => elev,
            MeowButtonFill.secondary => card2,
            MeowButtonFill.danger => slow.withValues(alpha: 0.10),
          };
    }
    final tint = switch (kind) {
      MeowButtonFill.prominent => t1.withValues(alpha: 0.18),
      MeowButtonFill.accent => accent.withValues(alpha: 0.14),
      MeowButtonFill.selected => accent.withValues(alpha: 0.22),
      MeowButtonFill.danger => slow.withValues(alpha: 0.14),
      MeowButtonFill.plain || MeowButtonFill.secondary => null,
    };
    // 两层叠成一个颜色（alphaBlend 对半透明的底也按「叠上去」算），画一次就够
    return tint == null ? card2 : Color.alphaBlend(tint, card2);
  }

  bool get _darkBg => ThemeData.estimateBrightnessForColor(bg) == Brightness.dark;

  /// 玻璃下按钮的细亮边（浅 白 70% / 深 白 16%）；经典 = 没有（[BorderSide.none]，形状照旧）
  BorderSide get buttonSide =>
      glass ? BorderSide(color: Colors.white.withValues(alpha: _darkBg ? 0.16 : 0.7), width: 0.8) : BorderSide.none;

  /// 分段滑块（没有真玻璃透镜时）：中性、比槽（次级块那档白）亮的一块白，配墨色字，同 iOS 分段的玻璃滑块；
  /// 强调色那档（[MeowButtonFill.selected]）留给选中的筛选胶囊。经典 = 墨色实心
  Color get segmentThumb => glass ? Colors.white.withValues(alpha: _darkBg ? 0.16 : 0.72) : t1;

  /// [buttonSide] 给 [BoxDecoration] 用；经典 = null
  Border? get buttonBorder => glass ? Border.fromBorderSide(buttonSide) : null;

  /// 主操作上的字色：经典 = 墨色实底上的页面底色；玻璃 = 墨色
  Color get onProminent => glass ? t1 : bg;

  /// 选中的胶囊 / 分段上的字色：经典 = 页面底色；玻璃 = 强调色
  Color get onSelected => glass ? accent : bg;
}
