import 'package:flutter/material.dart';

import 'tokens.dart';

/// 按钮底的种类（旧页面用；M3 改版后新代码直接用 FilledButton / FilledButton.tonal / OutlinedButton）：
/// [prominent] 主操作（primary）/ [accent] 色调（secondaryContainer）/ [plain] 卡片底 / [secondary] 卡片里的次级底 /
/// [danger] 淡红 / [selected] 选中的筛选胶囊、分段（primary）。
enum MeowButtonFill { prominent, accent, plain, secondary, danger, selected }

extension MeowButtonColors on MeowTokens {
  /// 按钮底色。[classic] = 调用点自己指定的颜色（优先）
  Color buttonFill(MeowButtonFill kind, {Color? classic}) =>
      classic ??
      switch (kind) {
        MeowButtonFill.prominent || MeowButtonFill.selected => btnOn,
        MeowButtonFill.accent => soft,
        MeowButtonFill.plain => elev,
        MeowButtonFill.secondary => card2,
        MeowButtonFill.danger => slow.withValues(alpha: 0.12),
      };

  /// 按钮描边：没有
  BorderSide get buttonSide => BorderSide.none;

  /// 分段选中块
  Color get segmentThumb => btnOn;

  /// [buttonSide] 给 [BoxDecoration] 用：没有
  Border? get buttonBorder => null;

  /// 主操作上的字色
  Color get onProminent => onBtn;

  /// 选中的胶囊 / 分段上的字色
  Color get onSelected => onBtn;
}
