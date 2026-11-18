import 'package:bett_box/common/common.dart';
import 'package:bett_box/models/models.dart';
import 'package:bett_box/state.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../theme/tokens.dart';

/// MeowX 设置的 Notifier：与 Bettbox 的 AppSetting 同款双写（state ↔ globalState.config），
/// 变更经 configState → savePreferencesDebounce 落盘。
class MeowSetting extends AutoDisposeNotifier<MeowSettings> with AutoDisposeNotifierMixin<MeowSettings> {
  @override
  MeowSettings build() => globalState.config.meow;

  @override
  void onUpdate(MeowSettings value) {
    globalState.config = globalState.config.copyWith(meow: value);
  }

  void updateState(MeowSettings Function(MeowSettings state) builder) {
    state = builder(state);
  }
}

final meowSettingProvider = AutoDisposeNotifierProvider<MeowSetting, MeowSettings>(MeowSetting.new);

/// 外观（主题色 / 跟随系统取色）：两份主题按它定种子色（application.dart）。只在这两项变了才通知，改别的设置不会让整棵树换主题。
final meowLookProvider = Provider.autoDispose<MeowLook>((ref) => ref.watch(meowSettingProvider.select(MeowLook.of)));

/// 主题的种子色：跟随系统时安卓 12+ 用桌布生成的色板（主色 40 档）、Windows / 其它用系统强调色，取不到就用设置里的主题色。
Color meowSeedOf(MeowLook look) {
  if (look.followSystem) {
    final palette = globalState.corePalette;
    if (palette != null) return Color(palette.primary.get(40));
    try {
      return globalState.accentColor;
    } catch (_) {
      // 系统取色没成（late 字段没赋值）
    }
  }
  return Color(look.seed);
}

