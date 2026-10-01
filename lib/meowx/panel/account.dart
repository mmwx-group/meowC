import 'dart:async';

import 'package:bett_box/common/common.dart';
import 'package:bett_box/models/models.dart';
import 'package:bett_box/providers/providers.dart';
import 'package:bett_box/state.dart';
import 'package:collection/collection.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../config/direct_profile.dart';
import '../state/meow_settings.dart';
import '../state/po0_reporter.dart';
import 'client.dart';
import 'models.dart';
import 'unlock_catalog.dart';

export 'models.dart';

/// 当前账户绑定的主控客户端（按 host 缓存一个实例，证书缓存跟着实例走）。
final panelClientProvider = Provider<PanelClient?>((ref) {
  final host = ref.watch(meowSettingProvider.select((s) => s.account.host));
  return host.isEmpty ? null : PanelClient(host);
});

final isLoggedInProvider = Provider<bool>((ref) => ref.watch(meowSettingProvider.select((s) => s.account.token.isNotEmpty)));

/// 「我的订阅」列表。
final remoteSubsProvider = StateProvider<AsyncValue<List<RemoteSubscription>>>((ref) => const AsyncValue.data([]));

/// 主控功能开关：未开启的功能不调接口、不显示图标。
final panelFeaturesProvider = StateProvider<PanelFeatures>((ref) => const PanelFeatures());

/// 节点奖牌（服务端判定）。
final medalsProvider = StateProvider<Map<String, NodeMedal>>((ref) => const {});

/// 节点解锁结论（服务端判定）。
final unlocksProvider = StateProvider<Map<String, NodeUnlocks>>((ref) => const {});

/// 正在导入的远端订阅（按名字）。
final importingSubProvider = StateProvider<String?>((ref) => null);

/// 账户动作：登录 / 二步验证 / 扫码 / 登出 / 拉订阅 / 导入并切换 / 奖牌。
class AccountActions {
  AccountActions(this.ref);
  final Ref ref;

  MeowAccount get _account => ref.read(meowSettingProvider).account;

  void _update(MeowAccount Function(MeowAccount) f) {
    ref.read(meowSettingProvider.notifier).updateState((s) => s.copyWith(account: f(s.account)));
  }

  PanelClient _client([String? host]) {
    final h = host ?? _account.host;
    if (h.isEmpty) throw const PanelException('尚未设置主控地址');
    return h == _account.host ? (ref.read(panelClientProvider) ?? PanelClient(h)) : PanelClient(h);
  }

  Future<LoginResult> login({required String host, required String username, required String password}) async {
    final client = _client(host);
    final r = await client.login(username: username, password: password);
    if (r is LoginSuccess) await _store(client.base, r);
    if (r is LoginNeeds2FA) _update((a) => a.copyWith(host: client.base));
    return r;
  }

  Future<LoginResult> complete2fa({required String twoFactorToken, required String code, bool recovery = false}) async {
    final client = _client();
    final r = recovery
        ? await client.loginRecovery(twoFactorToken: twoFactorToken, recoveryCode: code)
        : await client.login2fa(twoFactorToken: twoFactorToken, code: code);
    if (r is LoginSuccess) await _store(client.base, r);
    return r;
  }

  /// 扫码 / 深链登录：一次性码，成功后立即拉订阅。
  Future<void> loginWithCode({required String host, required String code}) async {
    final client = _client(host);
    final r = await client.loginQr(code);
    if (r is! LoginSuccess) throw const PanelException('登录失败');
    await _store(client.base, r);
    await refreshSubscriptions();
  }

  Future<void> _store(String base, LoginSuccess ok) async {
    _update((a) => a.copyWith(host: base, token: ok.token, nickname: ok.nickname, avatarUrl: ok.avatarUrl));
  }

  /// 登出：先删掉从这个主控导入的订阅档（用户的配置不该留在设备上），再清 token / 昵称 / 头像（保留主控地址）。
  /// 删档抛错就原样抛给界面提示，此时仍是登录态、可重试。当前档在其中时先切到剩下的第一份自有订阅，
  /// 没有才落到内置直连档（deleteProfile 自己会切到内部顺序的第一份，通常正是直连档）。
  Future<void> logout() async {
    final host = Uri.tryParse(_account.host)?.host ?? '';
    if (host.isNotEmpty) {
      final profiles = ref.read(profilesProvider);
      final mine = profiles.where((p) => p.url.isNotEmpty && Uri.tryParse(p.url)?.host == host).toList();
      final mineIds = mine.map((p) => p.id).toSet();
      if (mineIds.contains(ref.read(currentProfileIdProvider))) {
        final next = profiles.firstWhereOrNull((p) => !mineIds.contains(p.id) && !isDirectProfile(p.id));
        ref.read(currentProfileIdProvider.notifier).value = next?.id ?? directProfileId;
      }
      for (final p in mine) {
        await globalState.appController.deleteProfile(p.id);
      }
    }
    _update((a) => a.copyWith(token: '', nickname: '', avatarUrl: ''));
    ref.read(remoteSubsProvider.notifier).state = const AsyncValue.data([]);
    ref.read(medalsProvider.notifier).state = const {};
    ref.read(unlocksProvider.notifier).state = const {};
    ref.read(panelFeaturesProvider.notifier).state = const PanelFeatures();
    ref.read(po0ReporterProvider).stop();
    _extrasAt = null;
  }

  Future<void> refreshSubscriptions() async {
    final token = _account.token;
    if (token.isEmpty) return;
    ref.read(remoteSubsProvider.notifier).state = const AsyncValue.loading();
    try {
      final list = await _client().subscriptions(token);
      ref.read(remoteSubsProvider.notifier).state = AsyncValue.data(list);
      unawaited(refreshExtras());
    } catch (e, st) {
      commonPrint.log('refreshSubscriptions failed: $e');
      ref.read(remoteSubsProvider.notifier).state = AsyncValue.error(e, st);
    }
  }

  /// 点某条订阅 = 下载并切换为当前（同 url 已存在则刷新它）；连着就重连。
  Future<void> importSubscription(RemoteSubscription sub) async {
    final token = _account.token;
    if (token.isEmpty) throw const PanelException('请先登录');
    ref.read(importingSubProvider.notifier).state = sub.name;
    try {
      final client = _client();
      final subToken = await client.subscriptionToken(token);
      final url = sub.downloadUrl(client.base, subscriptionToken: subToken);
      final controller = globalState.appController;
      final existing = ref.read(profilesProvider).where((p) => p.url == url).firstOrNull;
      if (existing != null) {
        await controller.updateProfile(existing.copyWith(label: sub.name));
        _switchTo(existing.id);
        return;
      }
      final profile = await Profile.normal(url: url, label: sub.name).update();
      await controller.addProfile(profile);
      _switchTo(profile.id);
    } finally {
      ref.read(importingSubProvider.notifier).state = null;
    }
  }

  /// 切换当前档案：改 currentProfileId 即可，Bettbox 的 ClashManager 监听 needSetup 后自动重载
  void _switchTo(String id) {
    if (ref.read(currentProfileIdProvider) != id) {
      ref.read(currentProfileIdProvider.notifier).value = id;
    }
  }

  DateTime? _extrasAt;

  /// 节点附加信息（奖牌 / 解锁）：先问主控开了哪些，没开的不调接口、清空本地数据。
  Future<void> refreshExtras({bool ifStale = false}) async {
    final token = _account.token;
    if (token.isEmpty) return;
    if (ifStale && _extrasAt != null && DateTime.now().difference(_extrasAt!) < const Duration(minutes: 10)) return;
    _extrasAt = DateTime.now();
    // po0 加白目标列表也在这里顺带刷新并立刻上报（不依赖 features 开关）
    unawaited(ref.read(po0ReporterProvider).refresh());
    final client = _client();
    PanelFeatures features;
    try {
      features = await client.features(token);
    } catch (e) {
      commonPrint.log('features failed: $e');
      return;
    }
    ref.read(panelFeaturesProvider.notifier).state = features;
    if (features.returnRoutes) {
      try {
        ref.read(medalsProvider.notifier).state = await client.returnRoutes(token);
      } catch (e) {
        commonPrint.log('returnRoutes failed: $e');
      }
    } else {
      ref.read(medalsProvider.notifier).state = const {};
    }
    if (features.unlockCheck) {
      try {
        ref.read(unlocksProvider.notifier).state = await client.unlocks(token);
      } catch (e) {
        commonPrint.log('unlocks failed: $e');
      }
    } else {
      ref.read(unlocksProvider.notifier).state = const {};
    }
  }
}

final accountActionsProvider = Provider<AccountActions>((ref) => AccountActions(ref));

/// `--dart-define=MEOWX_DEMO_EXTRAS=true`：不登录也给节点塞一批假奖牌 / 解锁结论，用来截图核对界面。
const demoExtras = bool.fromEnvironment('MEOWX_DEMO_EXTRAS');

void seedDemoExtras(WidgetRef ref, List<String> names) {
  if (ref.read(unlocksProvider).isNotEmpty || names.isEmpty) return;
  final medals = <String, NodeMedal>{};
  final unlocks = <String, NodeUnlocks>{};
  for (var i = 0; i < names.length; i++) {
    final n = names[i];
    if (i % 2 == 0) {
      medals[n] = NodeMedal(name: n, medal: i % 4 == 0 ? 'gold' : 'silver', routes: [
        ReturnRoute(carrier: 'telecom', region: '广东', routeType: i % 4 == 0 ? 'CN2 GIA' : '163', gold: i % 4 == 0),
        const ReturnRoute(carrier: 'unicom', routeType: '9929', gold: true),
        const ReturnRoute(carrier: 'mobile', routeType: 'CMI', gold: false),
      ]);
    }
    if (i % 3 != 2) {
      final statuses = ['yes', 'no', 'originals_only', 'banned', 'failed'];
      unlocks[n] = NodeUnlocks(name: n, entries: [
        for (var k = 0; k < unlockServices.length; k++)
          UnlockEntry(
            service: unlockServices[k].key,
            status: unlockServices[k].info ? 'yes' : statuses[(i + k) % statuses.length],
            region: (i + k) % 2 == 0 ? ['HK', 'US', 'JP', 'SG'][(i + k) % 4] : null,
          ),
      ]);
    }
  }
  ref.read(panelFeaturesProvider.notifier).state = const PanelFeatures(returnRoutes: true, unlockCheck: true);
  ref.read(medalsProvider.notifier).state = medals;
  ref.read(unlocksProvider.notifier).state = unlocks;
}
