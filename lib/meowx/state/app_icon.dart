import 'package:bett_box/common/common.dart';
import 'package:bett_box/providers/providers.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// 桌面 App 图标（「我的 › 外观 › App 图标」，只 Android）。
///
/// 原生那头是 Bettbox 的 `app` 通道（AppPlugin 的 getAppIcon / setAppIcon）：每个图标一个 LAUNCHER 组件，同一时间只开一个，
/// 当前值以 PackageManager 查到的为准、这里不另存。默认（猫娘）仍是 MainActivity 自己的入口，升级不换组件；
/// 猫娘的深 / 浅两张沿用 Bettbox 原有的「深色图标」开关（高级 › 主题），这里选「默认」时照它决定开哪个。
enum MeowAppIcon {
  catgirl('默认', 'assets/images/icon_light_256.png'),
  mDark('M · 深色', 'assets/images/app_icon_m_dark_256.png'),
  mLight('M · 浅色', 'assets/images/app_icon_m_light_256.png');

  const MeowAppIcon(this.label, this.preview);
  final String label;

  /// 设置页的预览缩略图（256px、圆角已画进图里），由 scripts/make-brand-assets.py 生成
  final String preview;

  /// 原生回的组件名 → 选项：Bettbox 的 default / light / dark 都是猫娘
  static MeowAppIcon fromNative(String? name) => switch (name) {
    'm_dark' => mDark,
    'm_light' => mLight,
    _ => catgirl,
  };

  /// 选项 → 交给原生的组件名；猫娘按 Bettbox「深色图标」开关取深 / 浅
  String nativeName({required bool legacyDark}) => switch (this) {
    catgirl => legacyDark ? 'dark' : 'default',
    mDark => 'm_dark',
    mLight => 'm_light',
  };
}

/// 原生调用，测试里换成替身。
class AppIconBridge {
  const AppIconBridge();

  static const _channel = MethodChannel('app');

  Future<String?> current() => _channel.invokeMethod<String>('getAppIcon');

  Future<bool> set(String name) async => await _channel.invokeMethod<bool>('setAppIcon', {'name': name}) ?? false;
}

final appIconBridgeProvider = Provider<AppIconBridge>((ref) => const AppIconBridge());

/// 只有 Android 能换桌面图标（Windows 的 exe 图标不动），测试里改成 true。
final appIconSupportedProvider = Provider<bool>((ref) => system.isAndroid);

/// 当前图标。autoDispose：每次打开外观都重新问一遍 PackageManager（Bettbox 的「深色图标」开关在别处也能改它）。
final appIconProvider = AsyncNotifierProvider.autoDispose<AppIconController, MeowAppIcon>(AppIconController.new);

class AppIconController extends AutoDisposeAsyncNotifier<MeowAppIcon> {
  @override
  Future<MeowAppIcon> build() async => MeowAppIcon.fromNative(await ref.read(appIconBridgeProvider).current());

  /// 先把选中态切过去，原生失败再退回
  Future<void> select(MeowAppIcon icon) async {
    final prev = state;
    if (prev.valueOrNull == icon) return;
    state = AsyncData(icon);
    final legacyDark = ref.read(themeSettingProvider).useDarkIcon;
    try {
      if (!await ref.read(appIconBridgeProvider).set(icon.nativeName(legacyDark: legacyDark))) state = prev;
    } catch (_) {
      state = prev;
    }
  }
}
