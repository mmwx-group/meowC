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
import '../state/status.dart';
import 'client.dart';
import 'models.dart';
import 'node_match.dart';
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

/// 节点奖牌（服务端判定），按主控给的节点名索引。界面查用 [nodeMedalsProvider]。
final medalsProvider = StateProvider<Map<String, NodeMedal>>((ref) => const {});

/// 节点解锁结论（服务端判定），按主控给的节点名索引。界面查用 [nodeUnlocksProvider]。
final unlocksProvider = StateProvider<Map<String, NodeUnlocks>>((ref) => const {});

/// 主控给的原始条目（同名的几个协议都在）：名字对不上时按 type / server / port 认节点用。
final medalEntriesProvider = StateProvider<List<NodeMedal>>((ref) => const []);
final unlockEntriesProvider = StateProvider<List<NodeUnlocks>>((ref) => const []);

/// 当前订阅里各节点的键（应用配置时记下的，见 [captureNodeKeys]）。
final localNodeKeysProvider = Provider<Map<String, NodeMatchKey?>>((ref) {
  void changed() => ref.invalidateSelf();
  localNodeKeys.addListener(changed);
  ref.onDispose(() => localNodeKeys.removeListener(changed));
  return localNodeKeys.value;
});

/// 界面按订阅里的节点名查奖牌用：名字相同的照旧；主控的套餐订阅改过名的节点（倍率前缀、流量 / 到期尾缀、
/// 套餐内名称、重名序号）按 type / server / port 认。规则见 [resolveNodeExtras]。
final nodeMedalsProvider = Provider<Map<String, NodeMedal>>((ref) {
  return nodeExtrasForLocals<NodeMedal>(
    byName: ref.watch(medalsProvider),
    entries: ref.watch(medalEntriesProvider),
    locals: ref.watch(localNodeKeysProvider),
    nameOf: (m) => m.name,
    keyOf: (m) => m.key,
    samePayload: (a, b) => a.samePayload(b),
  );
});

/// 同上，解锁结论。
final nodeUnlocksProvider = Provider<Map<String, NodeUnlocks>>((ref) {
  return nodeExtrasForLocals<NodeUnlocks>(
    byName: ref.watch(unlocksProvider),
    entries: ref.watch(unlockEntriesProvider),
    locals: ref.watch(localNodeKeysProvider),
    nameOf: (u) => u.name,
    keyOf: (u) => u.key,
    samePayload: (a, b) => a.samePayload(b),
  );
});

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
    await afterLogin();
  }

  Future<void> _store(String base, LoginSuccess ok) async {
    _update((a) => a.copyWith(host: base, token: ok.token, nickname: ok.nickname, avatarUrl: ok.avatarUrl));
    _reapplyRules();
  }

  /// 主控直连规则跟着登录状态走（见 `panelDirectRules`）：连着时重新套用一次配置，登录后紧接着的账户请求就能直连主控。
  void _reapplyRules() {
    if (ref.read(isRunningProvider)) globalState.appController.applyProfileDebounce(silence: true);
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
    _reapplyRules();
    ref.read(remoteSubsProvider.notifier).state = const AsyncValue.data([]);
    _setMedals(const []);
    _setUnlocks(const []);
    ref.read(panelFeaturesProvider.notifier).state = const PanelFeatures();
    ref.read(po0ReporterProvider).stop();
    _extrasAt = null;
    _subsAttempt = null;
  }

  /// 向主控重取昵称与头像。这两项以前只在登录应答里写一次：用户之后在主控换了头像 / 改了昵称，要重新登录才跟上。
  /// **不定时拉**（用户明确要求），只由用户点的刷新带着调（订阅卡的「刷新」「刷新我的订阅」）。
  /// 没拿到答复、主控回的是出错应答、等答复期间退出或换了账号：什么都不动。
  Future<void> refreshProfile() async {
    final token = _account.token;
    if (token.isEmpty) return;
    try {
      final p = await _client().profile(token);
      final now = _account;
      if (now.token != token) return;
      if (p.nickname == now.nickname && p.avatarUrl == now.avatarUrl) return;
      _update((a) => a.copyWith(nickname: p.nickname, avatarUrl: p.avatarUrl));
    } catch (e) {
      commonPrint.log('refreshProfile failed: $e');
    }
  }

  /// 登录成功后：拉「我的订阅」，账户下恰好一份且本机还没在用订阅时直接导入并切过去（规则见 [autoImportCandidate]）。
  /// 用户反馈「登录了之后找不到订阅」：以前登录只把列表拉下来，要自己去订阅卡里点那一项才导入。
  /// 只在登录成功那一刻跑：用户事后自己删掉的订阅不会被自动加回来。导入不挡登录流程（订阅卡那一行会显示导入中）。
  Future<void> afterLogin() async {
    await refreshSubscriptions();
    final pick = autoImportCandidate(
      remote: ref.read(remoteSubsProvider).value ?? const [],
      host: _account.host,
      localUrls: ref.read(profilesProvider).map((p) => p.url),
      usingSubscription: !isDirectProfile(ref.read(currentProfileIdProvider) ?? directProfileId),
    );
    if (pick == null) return;
    unawaited(
      importSubscription(pick).catchError((Object e) => commonPrint.log('auto import after login failed: $e')),
    );
  }

  Future<void> refreshSubscriptions() async {
    final token = _account.token;
    if (token.isEmpty) return;
    _subsAttempt = (token: token, at: DateTime.now(), ok: false);
    ref.read(remoteSubsProvider.notifier).state = const AsyncValue.loading();
    try {
      final list = await _client().subscriptions(token);
      ref.read(remoteSubsProvider.notifier).state = AsyncValue.data(list);
      _subsAttempt = (token: token, at: DateTime.now(), ok: true);
      unawaited(refreshExtras());
    } catch (e, st) {
      commonPrint.log('refreshSubscriptions failed: $e');
      ref.read(remoteSubsProvider.notifier).state = AsyncValue.error(e, st);
    }
  }

  /// 最近一次拉「我的订阅」：哪次登录（token）、何时、拿到列表没有。只给 [refreshSubscriptionsIfNeeded] 节流用。
  ({String token, DateTime at, bool ok})? _subsAttempt;

  /// 首页出现时用（切换菜单要列「账户订阅 · 未下载」）：这次登录已经拉到过（不管是谁拉的）就不再拉，
  /// 正在拉也不重复；拉失败的隔一分钟再出现才重试。不定时拉，新增的订阅靠「我的」页的刷新钮。
  Future<void> refreshSubscriptionsIfNeeded() async {
    final token = _account.token;
    if (token.isEmpty || ref.read(remoteSubsProvider).isLoading) return;
    final last = _subsAttempt;
    if (last != null && last.token == token) {
      if (last.ok || DateTime.now().difference(last.at) < const Duration(minutes: 1)) return;
    }
    await refreshSubscriptions();
  }

  /// 刷新本机的一份订阅（首页订阅卡的「N 小时前更新」、「我的」页的「刷新」同一个动作）：
  /// 顺带向主控重取昵称 / 头像（只跟着用户点的刷新走，不定时拉）。失败照原样抛给界面提示。
  Future<void> refreshLocalSubscription(Profile profile) async {
    unawaited(refreshProfile());
    await globalState.appController.updateProfile(profile);
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
        // 用户在订阅卡里改过的名字留着，没名字才用主控给的
        await controller.updateProfile(existing.copyWith(label: existing.label ?? sub.name));
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
    if (ifStale) {
      // ifStale 是切到节点页时顺带触发的那一趟（不是用户点的）：下面连着 3–4 个 RPC，封包是纯 Dart 加密、
      // 在界面线程上算，晚一点再发，避开切页时底栏那段弹簧动画。期间登出 / 换了账号就算了。
      await Future<void>.delayed(const Duration(milliseconds: 400));
      if (_account.token != token) return;
    }
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
        _setMedals(await client.returnRoutes(token));
      } catch (e) {
        commonPrint.log('returnRoutes failed: $e');
      }
    } else {
      _setMedals(const []);
    }
    if (features.unlockCheck) {
      try {
        _setUnlocks(await client.unlocks(token));
      } catch (e) {
        commonPrint.log('unlocks failed: $e');
      }
    } else {
      _setUnlocks(const []);
    }
  }

  /// 原始条目与按名字的索引一起换（前者给按键认节点用）。
  void _setMedals(List<NodeMedal> list) {
    ref.read(medalEntriesProvider.notifier).state = list;
    ref.read(medalsProvider.notifier).state = NodeMedal.index(list);
  }

  void _setUnlocks(List<NodeUnlocks> list) {
    ref.read(unlockEntriesProvider.notifier).state = list;
    ref.read(unlocksProvider.notifier).state = NodeUnlocks.index(list);
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
