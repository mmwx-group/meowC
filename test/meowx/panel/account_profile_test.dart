import 'dart:async';

import 'package:bett_box/meowx/panel/account.dart';
import 'package:bett_box/meowx/panel/client.dart';
import 'package:bett_box/meowx/state/meow_settings.dart';
import 'package:bett_box/models/models.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

// `AccountActions.refreshProfile`：用户点刷新时向主控重取昵称与头像。
// 拿到了且有变化才写；主控回出错应答 / 断网、没登录、等答复期间退出或换了账号，都不动现有的。

class _Meow extends MeowSetting {
  _Meow(this.initial);
  final MeowSettings initial;

  @override
  MeowSettings build() => initial;

  @override
  void onUpdate(MeowSettings value) {}
}

class _Client extends PanelClient {
  _Client(this.answer) : super('https://panel.example.com');
  final Future<AccountProfile> Function(String token) answer;
  final tokens = <String>[];

  @override
  Future<AccountProfile> profile(String token) {
    tokens.add(token);
    return answer(token);
  }
}

const _host = 'https://panel.example.com';
const _old = MeowAccount(host: _host, token: 't1', nickname: '旧昵称', avatarUrl: 'https://img.example.org/old.webp');

ProviderContainer _container(MeowAccount account, _Client client) {
  final c = ProviderContainer(
    overrides: [
      meowSettingProvider.overrideWith(() => _Meow(MeowSettings(account: account))),
      panelClientProvider.overrideWithValue(client),
    ],
  );
  addTearDown(c.dispose);
  return c;
}

MeowAccount _account(ProviderContainer c) => c.read(meowSettingProvider).account;

void main() {
  test('主控上的昵称 / 头像变了：跟着换，其余（主控地址、令牌）不动', () async {
    final client = _Client((_) async => const AccountProfile(nickname: '新昵称', avatarUrl: '/api/user/avatar/ab?v=2'));
    final c = _container(_old, client);
    await c.read(accountActionsProvider).refreshProfile();
    expect(client.tokens, ['t1']);
    expect(_account(c).nickname, '新昵称');
    expect(_account(c).avatarUrl, '/api/user/avatar/ab?v=2');
    expect(_account(c).host, _host);
    expect(_account(c).token, 't1');
  });

  test('用户在主控上把头像删了：客户端清空，回到品牌头像', () async {
    final c = _container(_old, _Client((_) async => const AccountProfile(nickname: '旧昵称', avatarUrl: '')));
    await c.read(accountActionsProvider).refreshProfile();
    expect(_account(c).avatarUrl, '');
    expect(_account(c).nickname, '旧昵称');
  });

  test('主控回出错应答 / 请求失败：昵称和头像都不动，也不往外抛', () async {
    final c = _container(_old, _Client((_) async => throw const PanelException('unauthorized')));
    await c.read(accountActionsProvider).refreshProfile();
    expect(_account(c), _old);
  });

  test('没登录：不发请求', () async {
    final client = _Client((_) async => const AccountProfile(nickname: 'x', avatarUrl: 'y'));
    final c = _container(const MeowAccount(host: _host), client);
    await c.read(accountActionsProvider).refreshProfile();
    expect(client.tokens, isEmpty);
    expect(_account(c), const MeowAccount(host: _host));
  });

  test('等答复期间退出 / 换了账号：这份答复作废', () async {
    final gate = Completer<AccountProfile>();
    final c = _container(_old, _Client((_) => gate.future));
    final pending = c.read(accountActionsProvider).refreshProfile();
    final other = _old.copyWith(token: 't2', nickname: '另一个账号', avatarUrl: '');
    c.read(meowSettingProvider.notifier).updateState((s) => s.copyWith(account: other));
    gate.complete(const AccountProfile(nickname: '新昵称', avatarUrl: '/api/user/avatar/ab'));
    await pending;
    expect(_account(c), other);
  });
}
