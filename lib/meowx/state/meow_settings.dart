import 'package:bett_box/common/common.dart';
import 'package:bett_box/models/models.dart';
import 'package:bett_box/state.dart';
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

/// 外观（主题风格 / 玻璃样式 / 卡片颜色）：两份主题按它推 token（application.dart），玻璃宿主按它开关（glass_host.dart）。
/// 只在这三项变了才通知，改别的设置不会让整棵树换主题。
final meowLookProvider = Provider.autoDispose<MeowLook>((ref) => ref.watch(meowSettingProvider.select(MeowLook.of)));
