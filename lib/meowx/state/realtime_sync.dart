import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:bett_box/clash/clash.dart';
import 'package:bett_box/common/common.dart';
import 'package:bett_box/enum/enum.dart';
import 'package:bett_box/models/models.dart';
import 'package:bett_box/providers/providers.dart';
import 'package:bett_box/state.dart';
import 'package:collection/collection.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app/meow_tab.dart';
import '../config/subscription_meta.dart';
import '../panel/account.dart';
import '../panel/realtime.dart';
import 'meow_settings.dart';
import 'subscription_meta_store.dart';

/// 订阅自动更新（规格 §3.3）的处理流程：取内核的待更新队列 → 每条算出要重拉的订阅档 → 逐个重拉（带 `mmwx-refresh: push`）
/// → 处理完的 ack。内核那边已经随机等过 0–10 秒、同一份订阅 30 秒内只通知一次；这里再管同一个档被几条变更同时点到。
/// 重拉失败的留在队列里，按 1、2、4… 分钟（封顶 30 分钟）重试，回前台 / 换网时也再试。
///
/// 依赖全部经构造函数注入，方便单测；App 里由 [RealtimeSync] 组装。
class SubscriptionPushDrainer {
  SubscriptionPushDrainer({
    required this.pending,
    required this.ack,
    required this.profiles,
    required this.login,
    required this.refresh,
    required this.log,
    this.onLoggedInPanelChanged,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  final Future<List<SubChange>> Function() pending;
  final Future<void> Function(List<SubChange> items) ack;

  /// 现在的订阅档（每条变更现取：前一条刚重拉过的档已经记下了新 rev）
  final List<SubscriptionProfileRef> Function() profiles;
  final PanelLogin? Function() login;

  /// 重拉一份订阅档；失败抛错
  final Future<void> Function(String profileId) refresh;
  final void Function(String message) log;

  /// 登录着的主控来了订阅变更（顺带刷新「我的订阅」列表，同以前 Dart 通道的做法）
  final void Function()? onLoggedInPanelChanged;
  final DateTime Function() _now;

  final _lastRefresh = <String, DateTime>{};
  bool _running = false;
  bool _again = false;
  int _failures = 0;
  Timer? _timer;

  /// 下次自动重试排在什么时候（测试用）
  Duration? scheduledIn;

  /// 处理一遍队列。正在处理时又被叫：这一遍完了再来一遍。
  Future<void> drain() async {
    if (_running) {
      _again = true;
      return;
    }
    _running = true;
    _timer?.cancel();
    _timer = null;
    scheduledIn = null;
    try {
      do {
        _again = false;
        await _drainOnce();
      } while (_again);
    } finally {
      _running = false;
    }
  }

  /// 回前台 / 换网：之前的失败不再说明问题，重试间隔从头算。
  void resetBackoff() => _failures = 0;

  void dispose() {
    _timer?.cancel();
    _timer = null;
  }

  Future<void> _drainOnce() async {
    List<SubChange> items;
    try {
      items = await pending();
    } catch (e) {
      log('MeowX: 取订阅待更新队列失败 $e');
      return;
    }
    if (items.isEmpty) return;
    final done = <SubChange>[];
    final refreshedNow = <String>{};
    Duration? wait;
    var failed = false;
    var attempted = false;
    var loggedInPanel = false;
    for (final item in items) {
      var ok = true;
      for (final id in profilesToRefresh(item, profiles(), login())) {
        // 这一遍里已经为别的变更重拉过：拿到的就是最新的
        if (refreshedNow.contains(id)) continue;
        final last = _lastRefresh[id];
        if (last != null) {
          final left = pushRefreshMinInterval - _now().difference(last);
          if (left > Duration.zero) {
            ok = false;
            if (wait == null || left < wait) wait = left;
            continue;
          }
        }
        _lastRefresh[id] = _now();
        attempted = true;
        try {
          await refresh(id);
          refreshedNow.add(id);
        } catch (e) {
          ok = false;
          failed = true;
          log('MeowX: 主控推送的订阅变更，重拉失败 $id：$e');
        }
      }
      if (ok) done.add(item);
      if (login()?.base == item.base) loggedInPanel = true;
    }
    if (done.isNotEmpty) {
      try {
        await ack(done);
      } catch (e) {
        log('MeowX: 订阅待更新队列 ack 失败 $e');
      }
    }
    if (loggedInPanel) onLoggedInPanelChanged?.call();
    // 只是被节流、一份都没拉的这一遍不算成功，退避不复位
    if (failed) {
      _failures++;
    } else if (attempted || done.isNotEmpty) {
      _failures = 0;
    }
    Duration? next = wait;
    if (failed) {
      final retry = pushRetryDelay(_failures - 1);
      if (next == null || retry < next) next = retry;
    }
    if (next != null) {
      scheduledIn = next;
      _timer = Timer(next, () => unawaited(drain()));
    }
  }
}

/// 主控实时通道的 Dart 这一侧（通道本身在内核里，见 panel/realtime.dart）：
/// - 登录状态、订阅档、订阅档记下的应答头、当前档变了 → 重算要连的主控（[planRealtime]）交给内核；
///   某个主控不再连了（退出登录、登录过期、这个主控的订阅都删了）→ 清掉它的入口覆盖，回到 DNS。
/// - 内核推来 meowSubChanged、启动完成、回前台 → 处理订阅待更新队列（[SubscriptionPushDrainer]）。
///   安卓上界面不在时（VPN 服务在后台跑）消息没人收，队列在内核那边落着盘，界面回来时在这里补上。
/// - 桌面换网 → 叫醒内核里退避中的通道（安卓由 VPN 服务的换网回调直接在内核里做）。
class RealtimeSync {
  RealtimeSync(this.ref) : core = ref.read(coreRealtimeProvider);

  final Ref ref;
  final CoreRealtime core;
  late final SubscriptionPushDrainer drainer = SubscriptionPushDrainer(
    pending: core.pending,
    ack: core.ack,
    profiles: _profileRefs,
    login: _login,
    refresh: _refreshProfile,
    log: commonPrint.log,
    onLoggedInPanelChanged: () => unawaited(ref.read(accountActionsProvider).refreshSubscriptions()),
  );

  RealtimePlan? _sent;
  Set<String> _bases = const {};
  bool _metasLoaded = false;
  Future<void> _planning = Future.value();
  StreamSubscription<Map<String, Object?>>? _msgSub;
  StreamSubscription<List<ConnectivityResult>>? _connSub;
  AppLifecycleListener? _lifecycle;

  bool get _inited => ref.read(initProvider);

  PanelLogin? _login() {
    final a = ref.read(meowSettingProvider).account;
    return PanelLogin.of(a.host, a.token);
  }

  List<SubscriptionProfileRef> _profileRefs() {
    final metas = subscriptionMetaStore.metas.value;
    return [
      for (final p in ref.read(profilesProvider))
        if (p.url.isNotEmpty) SubscriptionProfileRef(id: p.id, url: p.url, meta: metas[p.id]),
    ];
  }

  void start() {
    ref.listen<(String, String)>(meowSettingProvider.select((s) => (s.account.host, s.account.token)), (_, _) => replan());
    // 订阅档只看 id 与地址（拼成字符串比：freezed 列表的 == 只认同一个实例）；删掉的档顺带丢掉它记下的应答头。
    // 只丢「刚才还在、现在没了」的：导入新订阅时应答头先记下、档案后加进列表，不能按「不在列表里」去删
    ref.listen<String>(
      profilesProvider.select((list) => list.map((p) => '${p.id} ${p.url}').join('\n')),
      (prev, next) {
        Set<String> ids(String? s) => {for (final l in (s ?? '').split('\n')) if (l.isNotEmpty) l.split(' ').first};
        final removed = ids(prev).difference(ids(next));
        if (removed.isNotEmpty) unawaited(subscriptionMetaStore.remove(removed));
        replan();
      },
    );
    ref.listen<String?>(currentProfileIdProvider, (_, _) => replan());
    ref.listen<bool>(initProvider, (prev, next) {
      if (next && prev != true) {
        replan();
        unawaited(drainer.drain());
      }
    });
    subscriptionMetaStore.metas.addListener(replan);
    unawaited(
      subscriptionMetaStore.load().then((_) {
        _metasLoaded = true;
        replan();
      }),
    );
    _msgSub = clashMessage.controller.stream.where((m) => m['type'] == 'meowSubChanged').listen((_) {
      if (_inited) unawaited(drainer.drain());
    });
    _lifecycle = AppLifecycleListener(onShow: _onForeground);
    if (!Platform.isAndroid) {
      _connSub = Connectivity().onConnectivityChanged.listen((_) {
        if (!_inited) return;
        drainer.resetBackoff();
        unawaited(core.kick());
        unawaited(drainer.drain());
      }, onError: (_) {});
    }
    if (_inited) unawaited(drainer.drain());
  }

  void _onForeground() {
    if (!_inited) return;
    drainer.resetBackoff();
    unawaited(drainer.drain());
  }

  /// 重算要连的主控并交给内核（没变就不发）。不再连的主控清掉它的入口覆盖。
  void replan() {
    if (!_inited || !_metasLoaded) return;
    _planning = _planning.then((_) => _replan()).catchError((Object e) => commonPrint.log('MeowX: 实时通道配置失败 $e'));
  }

  Future<void> _replan() async {
    final plan = planRealtime(
      login: _login(),
      profiles: _profileRefs(),
      currentProfileId: ref.read(currentProfileIdProvider),
    );
    final sent = _sent;
    if (sent != null &&
        const ListEquality<RealtimeChannelPlan>().equals(sent.channels, plan.channels) &&
        const ListEquality<SubRevNote>().equals(sent.subs, plan.subs)) {
      return;
    }
    final err = await core.configure(plan);
    if (err != null) commonPrint.log('MeowX: 实时通道配置失败 $err');
    // 没交成功（核心还没起来、回包超时）下次有变化或再叫时重发
    _sent = err == null ? plan : null;
    final dropped = _bases.difference(plan.bases);
    _bases = plan.bases;
    for (final base in dropped) {
      final n = await core.clear(base);
      if (n > 0) commonPrint.log('MeowX: 不再连 $base 的实时通道，清掉它指定的 $n 个入口');
    }
  }

  /// 推送触发的重拉：带 `mmwx-refresh: push`；内容真变了、且是当前在用的订阅才重新应用（同手动 / 定时更新的应用方式）。
  Future<void> _refreshProfile(String id) async {
    final profile = ref.read(profilesProvider).firstWhereOrNull((p) => p.id == id);
    if (profile == null || profile.url.isEmpty) return;
    final before = await _readProfileFile(id);
    final Profile updated;
    try {
      updated = await profile.update(requestHeaders: pushRefreshHeaders);
    } on String catch (e) {
      // 拉到了但内容不能用（配置校验不过、通用订阅）：重试也一样，算处理过了；网络错误照常抛出去等重试
      commonPrint.log('MeowX: 主控推送订阅变更，「${profile.label ?? id}」拉到的内容不能用：$e');
      return;
    }
    final changed = before != await _readProfileFile(id);
    final controller = globalState.appController;
    final next = updated.copyWith(isUpdating: false);
    if (changed && id == ref.read(currentProfileIdProvider)) {
      controller.setProfileAndAutoApply(next);
    } else {
      controller.setProfile(next);
    }
    commonPrint.log('MeowX: 主控推送订阅变更，已重拉「${profile.label ?? id}」${changed ? '（内容有变化）' : '（内容没变）'}');
  }

  static Future<String?> _readProfileFile(String id) async {
    try {
      final f = File(await appPath.getProfilePath(id));
      return await f.exists() ? await f.readAsString() : null;
    } catch (_) {
      return null;
    }
  }

  void dispose() {
    subscriptionMetaStore.metas.removeListener(replan);
    unawaited(_msgSub?.cancel());
    unawaited(_connSub?.cancel());
    _lifecycle?.dispose();
    drainer.dispose();
  }
}

/// 调核心 `meowRealtime`（参数 → 回包 JSON）。核心那边都是本地操作，几秒就够。
Future<String> invokeMeowRealtime(Map<String, Object?> params) => clashCore.clashInterface.invoke<String>(
  method: ActionMethod.meowRealtime,
  data: json.encode(params),
  timeout: const Duration(seconds: 8),
);

/// 内核通道的调用（测试里换掉）。
final coreRealtimeProvider = Provider<CoreRealtime>((ref) => const CoreRealtime(invokeMeowRealtime));

/// 退出登录（清 token 之前调）：清掉这个主控指定的入口（规格 §6）。要在通道重配之前清：
/// 这个主控要是还有订阅给的只读凭证，换上的 rt 通道连上后会按它那份订阅重新指定，不能被这里清掉；
/// 而登录态那份覆盖面更大，rt 通道的快照不会替它撤掉。
Future<void> clearPanelEntriesOnLogout(Ref ref, String host) async {
  final base = normalizePanelBase(host);
  if (base == null) return;
  try {
    if (!ref.read(initProvider)) return;
    final n = await ref.read(coreRealtimeProvider).clear(base);
    if (n > 0) commonPrint.log('MeowX: 退出登录，清掉 $base 指定的 $n 个入口');
  } catch (e) {
    commonPrint.log('MeowX: 退出登录清入口覆盖失败 $e');
  }
}

final realtimeSyncProvider = Provider<RealtimeSync>((ref) {
  final sync = RealtimeSync(ref)..start();
  ref.onDispose(sync.dispose);
  return sync;
});

/// 当前的入口覆盖表（节点格上「主控指定入口」用）。节点页看得见、App 在前台时每 30 秒问一次内核，切到节点页时立刻问；
/// 其余时候不问（本地调用，但没人看就不必叫醒核心）。
final entryOverridesProvider = NotifierProvider<EntryOverridesController, List<EntryOverride>>(EntryOverridesController.new);

class EntryOverridesController extends Notifier<List<EntryOverride>> {
  static const _everyTicks = 6; // tick5s × 6 = 30 秒
  int _ticks = 0;
  bool _fetching = false;

  @override
  List<EntryOverride> build() {
    void onTick() {
      if (++_ticks % _everyTicks == 0) unawaited(refresh());
    }

    dashboardRefreshManager.tick5s.addListener(onTick);
    ref.onDispose(() => dashboardRefreshManager.tick5s.removeListener(onTick));
    ref.listen<MeowTab>(meowTabProvider, (prev, next) {
      if (next == MeowTab.proxies && prev != next) unawaited(refresh());
    });
    Future.microtask(refresh);
    return const [];
  }

  @override
  bool updateShouldNotify(List<EntryOverride> previous, List<EntryOverride> next) =>
      !const ListEquality<EntryOverride>().equals(previous, next);

  Future<void> refresh() async {
    if (_fetching || ref.read(meowTabProvider) != MeowTab.proxies) return;
    _fetching = true;
    try {
      if (!ref.read(initProvider)) return;
      state = await ref.read(coreRealtimeProvider).entries();
    } catch (e) {
      commonPrint.log('MeowX: 取入口覆盖表失败 $e');
    } finally {
      _fetching = false;
    }
  }
}

/// 节点 [name] 现在生效的主控指定入口（按订阅里这个节点的 server 查）；没有为 null。
final nodeEntryOverrideProvider = Provider.autoDispose.family<EntryOverride?, String>((ref, name) {
  final server = ref.watch(localNodeKeysProvider.select((m) => m[name]?.server));
  if (server == null) return null;
  return ref.watch(entryOverridesProvider.select((list) => entryOverrideFor(server, list)));
});
