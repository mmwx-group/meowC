import 'package:bett_box/meowx/state/meow_settings.dart';
import 'package:bett_box/models/models.dart';
import 'package:bett_box/providers/providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

// 安卓 VPN 的系统代理排除清单来自 coreStateProvider（变化时 ClashManager 把它交给核心）：以前没传 bypassDomain，
// 一变化就用空列表盖掉 getCoreState 设好的那份，实际一条都不排除。

class _Meow extends MeowSetting {
  _Meow(this.initial);
  final MeowSettings initial;

  @override
  MeowSettings build() => initial;

  @override
  void onUpdate(MeowSettings value) {}
}

class _Network extends NetworkSetting {
  _Network(this.initial);
  final NetworkProps initial;

  @override
  NetworkProps build() => initial;

  @override
  void onUpdate(NetworkProps value) {}
}

class _Vpn extends VpnSetting {
  @override
  VpnProps build() => const VpnProps();

  @override
  void onUpdate(VpnProps value) {}
}

class _App extends AppSetting {
  @override
  AppSettingProps build() => const AppSettingProps();

  @override
  void onUpdate(AppSettingProps value) {}
}

class _Profiles extends Profiles {
  @override
  List<Profile> build() => const [];

  @override
  void onUpdate(List<Profile> value) {}
}

class _CurrentId extends CurrentProfileId {
  @override
  String? build() => null;

  @override
  void onUpdate(String? value) {}
}

List<String> _bypass(MeowSettings meow, NetworkProps network) {
  final c = ProviderContainer(
    overrides: [
      meowSettingProvider.overrideWith(() => _Meow(meow)),
      networkSettingProvider.overrideWith(() => _Network(network)),
      vpnSettingProvider.overrideWith(_Vpn.new),
      appSettingProvider.overrideWith(_App.new),
      profilesProvider.overrideWith(_Profiles.new),
      currentProfileIdProvider.overrideWith(_CurrentId.new),
    ],
  );
  addTearDown(c.dispose);
  return c.read(coreStateProvider).bypassDomain;
}

void main() {
  test('喵窝关着：排除清单就是用户存着的那份（缺省清单 / 改过的都原样）', () {
    expect(_bypass(const MeowSettings(), const NetworkProps()), defaultBypassDomain);
    expect(_bypass(const MeowSettings(), const NetworkProps(bypassDomain: ['*.example.com', '10.*'])), ['*.example.com', '10.*']);
  });

  test('喵窝开着：盖住站点网段的条目收窄，别的原样', () {
    const meow = MeowSettings(mesh: MeowMesh(enabled: true, controlUrl: 'https://x', routes: ['192.168.1.0/24']));
    final list = _bypass(meow, const NetworkProps());
    expect(list, isNot(contains('192.168.*')));
    expect(list, containsAll(['localhost', '127.*', '10.*', '172.16.*', '192.168.0.*', '192.168.2*']));
    expect(list.where((e) => e.startsWith('192.168.1.')), isEmpty);
  });
}
