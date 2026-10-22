import 'package:bett_box/meowx/panel/account.dart';
import 'package:bett_box/meowx/state/meow_settings.dart';
import 'package:bett_box/meowx/state/status.dart';
import 'package:bett_box/models/models.dart';
import 'package:bett_box/providers/providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

// `AccountActions.logout` 清账户会话与跟着账号走的数据，并删掉从这个主控导入的订阅档（删档走 appController，
// 这里不覆盖，只测别家订阅不动）；登录过期只清会话、不删订阅档、留着昵称头像（账户卡显示「登录已过期」）。

class _Meow extends MeowSetting {
  _Meow(this.initial);
  final MeowSettings initial;

  @override
  MeowSettings build() => initial;

  @override
  void onUpdate(MeowSettings value) {}
}

class _Profiles extends Profiles {
  _Profiles(this.initial);
  final List<Profile> initial;

  @override
  List<Profile> build() => initial;

  @override
  void onUpdate(List<Profile> value) {}
}

class _CurrentId extends CurrentProfileId {
  _CurrentId(this.initial);
  final String? initial;

  @override
  String? build() => initial;

  @override
  void onUpdate(String? value) {}
}

const _host = 'https://panel.example.com';
const _account = MeowAccount(host: _host, token: 't1', nickname: '昵称', avatarUrl: 'https://img.example.org/a.webp');

Profile _profile(String id, String url) => Profile(id: id, label: id, url: url, autoUpdateDuration: const Duration(days: 1));

void main() {
  test('退出登录：清 token / 昵称 / 头像与账户数据，保留主控地址；别家机场的订阅档与当前档不动', () async {
    final profiles = [_profile('other', 'https://airport.example.org/sub')];
    final c = ProviderContainer(
      overrides: [
        meowSettingProvider.overrideWith(() => _Meow(const MeowSettings(account: _account))),
        profilesProvider.overrideWith(() => _Profiles(profiles)),
        currentProfileIdProvider.overrideWith(() => _CurrentId('other')),
        isRunningProvider.overrideWithValue(false),
      ],
    );
    addTearDown(c.dispose);
    c.read(remoteSubsProvider.notifier).state = const AsyncValue.data([
      RemoteSubscription(name: 'A', filename: 'a.yaml', subscriptionPath: '/x/abc'),
    ]);
    c.read(panelFeaturesProvider.notifier).state = const PanelFeatures(returnRoutes: true, unlockCheck: true);

    await c.read(accountActionsProvider).logout();

    expect(c.read(meowSettingProvider).account, const MeowAccount(host: _host));
    expect(c.read(isLoggedInProvider), isFalse);
    expect(c.read(isSessionExpiredProvider), isFalse);
    expect(c.read(remoteSubsProvider).value, isEmpty);
    expect(c.read(panelFeaturesProvider), const PanelFeatures());
    expect(c.read(profilesProvider), profiles);
    expect(c.read(currentProfileIdProvider), 'other');
  });

  test('登录过期：不删订阅档，但留着昵称头像', () {
    final profiles = [_profile('mine', '$_host/x/abc')];
    final c = ProviderContainer(
      overrides: [
        meowSettingProvider.overrideWith(() => _Meow(const MeowSettings(account: _account))),
        profilesProvider.overrideWith(() => _Profiles(profiles)),
        currentProfileIdProvider.overrideWith(() => _CurrentId('mine')),
        isRunningProvider.overrideWithValue(false),
      ],
    );
    addTearDown(c.dispose);

    c.read(accountActionsProvider).sessionExpired();

    expect(c.read(meowSettingProvider).account, _account.copyWith(token: ''));
    expect(c.read(isSessionExpiredProvider), isTrue);
    expect(c.read(profilesProvider), profiles);
    expect(c.read(currentProfileIdProvider), 'mine');
  });
}
