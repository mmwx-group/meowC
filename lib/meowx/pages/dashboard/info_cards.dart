import 'dart:async';

import 'package:bett_box/common/common.dart';
import 'package:bett_box/enum/enum.dart';
import 'package:bett_box/models/models.dart';
import 'package:bett_box/providers/providers.dart';
import 'package:bett_box/state.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/meow_tab.dart';
import '../../app/strings.dart';
import '../../config/direct_profile.dart';
import '../../config/meow_patch.dart';
import '../../panel/account.dart';
import '../../panel/client.dart' show PanelException;
import '../../state/connection.dart';
import '../../state/exit_ip.dart';
import '../../state/format.dart';
import '../../state/meow_settings.dart';
import '../../state/region_names.dart';
import '../../state/status.dart';
import '../../theme/haptics.dart';
import '../../theme/morph_menu.dart';
import '../../theme/m3.dart';
import '../../theme/m3_kit.dart';
import '../../theme/tokens.dart';
import '../settings/proxy_apps_page.dart';
import 'memory_report.dart';

// 这个文件里的卡片都可能放在宽屏首页的 IntrinsicHeight 里（见 dashboard_page.dart），不要用 LayoutBuilder。

/// 订阅卡（同 iOS 首页）：第一行订阅名 + 行尾「切换订阅 ⌄」胶囊，两处点开同一份切换菜单（以前入口只是名字后面一个小上下箭头，不好点）。
/// - 内置直连档（没在用订阅）：胶囊换成实心「选择订阅」，下面一行「未使用订阅，流量全部直连」，没有用量；
/// - 在用订阅：用量条（有总量才画）+「已用 / 总量 · 到期」|「N 小时前更新 ↻」，后者点了直接刷新当前订阅（有地址才可点）。
/// 菜单：本机订阅（当前那份打勾）→ 已登录时账户下还没下载的（去重见 [notDownloadedSubscriptions]，点了先下载再切）→「导入订阅…」去「我的」。
/// 没有当前档时是去「我的」导入的引导。[dense] = 宽屏 / Windows 首页的紧凑版：同样的内容与交互，尺寸小一档。
class HomeSubscriptionCard extends ConsumerStatefulWidget {
  const HomeSubscriptionCard({super.key, this.dense = false});
  final bool dense;

  @override
  ConsumerState<HomeSubscriptionCard> createState() => _HomeSubscriptionCardState();
}

/// 切换菜单的选项。
sealed class _SubPick {
  const _SubPick();
}

final class _PickLocal extends _SubPick {
  const _PickLocal(this.id);
  final String id;
}

final class _PickRemote extends _SubPick {
  const _PickRemote(this.sub);
  final RemoteSubscription sub;
}

final class _PickImport extends _SubPick {
  const _PickImport();
}

class _HomeSubscriptionCardState extends ConsumerState<HomeSubscriptionCard> {
  bool _refreshing = false;

  /// 最近一次拉到的账户订阅：重新拉取期间（provider 是 loading、没有值）菜单照旧列它
  List<RemoteSubscription> _lastSubs = const [];

  @override
  void initState() {
    super.initState();
    _lastSubs = ref.read(remoteSubsProvider).value ?? const [];
    ref.listenManual(remoteSubsProvider, (_, next) {
      if (next.hasValue) _lastSubs = next.value!;
    });
    // 首页也要知道账户下有哪些订阅（菜单列「未下载」的）：首页出现 / 登录后各问一次，这次登录拉过就不再拉（节流在 AccountActions 里）
    ref.listenManual(meowTabProvider, (_, tab) {
      if (tab == MeowTab.home) _fetchAccountSubs();
    });
    ref.listenManual(isLoggedInProvider, (_, loggedIn) {
      if (loggedIn) _fetchAccountSubs();
    });
    Future.microtask(() {
      if (mounted && ref.read(meowTabProvider) == MeowTab.home) _fetchAccountSubs();
    });
  }

  void _fetchAccountSubs() {
    if (ref.read(isLoggedInProvider)) unawaited(ref.read(accountActionsProvider).refreshSubscriptionsIfNeeded());
  }

  Future<void> _refresh(Profile p) async {
    if (_refreshing) return;
    MeowHaptics.tap();
    setState(() => _refreshing = true);
    try {
      await ref.read(accountActionsProvider).refreshLocalSubscription(p);
    } catch (e) {
      globalState.showNotifier('刷新订阅失败：${e is PanelException ? e.message : e}');
    } finally {
      if (mounted) setState(() => _refreshing = false);
    }
  }

  List<MeowMenuEntry<_SubPick>> _entries(String currentId) {
    final profiles = withDirectProfileLast(ref.read(profilesProvider));
    final loggedIn = ref.read(isLoggedInProvider);
    final loading = ref.read(remoteSubsProvider).isLoading;
    final pending = loggedIn
        ? notDownloadedSubscriptions(
            remote: _lastSubs,
            host: ref.read(meowSettingProvider).account.host,
            localUrls: profiles.map((p) => p.url),
          )
        : const <RemoteSubscription>[];
    return [
      for (final p in profiles) MeowMenuItem(_PickLocal(p.id), p.label ?? p.id, checked: p.id == currentId),
      if (loggedIn && (pending.isNotEmpty || loading)) ...[
        const MeowMenuDivider(),
        const MeowMenuCaption('账户订阅 · 未下载'),
        if (loading && pending.isEmpty) const MeowMenuCaption('加载中…'),
        // 菜单项没有图标位：下载箭头写在名字前面
        for (final s in pending) MeowMenuItem(_PickRemote(s), '↓ ${s.name}'),
      ],
      const MeowMenuDivider(),
      const MeowMenuItem(_PickImport(), '导入订阅…'),
    ];
  }

  void _onPick(_SubPick pick) {
    switch (pick) {
      case _PickLocal(:final id):
        // 改 currentProfileId 即切换（ClashManager 监听后自动重载）
        if (ref.read(profilesProvider).getProfile(id) != null && ref.read(currentProfileIdProvider) != id) {
          ref.read(currentProfileIdProvider.notifier).value = id;
        }
      case _PickRemote(:final sub):
        if (ref.read(importingSubProvider) != null) return;
        // 同「我的」页：下载并切过去（连着就按新配置重载）
        unawaited(
          ref.read(accountActionsProvider).importSubscription(sub).catchError((Object e) {
            globalState.showNotifier('下载订阅失败：${e is PanelException ? e.message : e}');
          }),
        );
      case _PickImport():
        goTab(ref, MeowTab.me);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = context.cs;
    final dense = widget.dense;
    final profile = ref.watch(currentProfileProvider);
    final caption = TextStyle(fontSize: 12, color: cs.onSurfaceVariant);
    if (profile == null) {
      return M3Card(
        onTap: () => goTab(ref, MeowTab.me),
        child: Row(
          children: [
            M3IconTile(icon: Icons.add_rounded, bg: cs.primaryContainer, fg: cs.onPrimaryContainer, size: 44),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    S.noSubscription,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: dense ? 17 : 20, fontWeight: FontWeight.w800, color: cs.onSurface),
                  ),
                  Text('去「我的」导入订阅', maxLines: 1, overflow: TextOverflow.ellipsis, style: caption),
                ],
              ),
            ),
            Icon(Icons.chevron_right_rounded, color: cs.onSurfaceVariant),
          ],
        ),
      );
    }

    final direct = isDirectProfile(profile.id);
    final importing = ref.watch(importingSubProvider) != null;

    Widget menu({required bool alignEnd, required Widget Function(VoidCallback open) trigger}) => MeowMenuButton<_SubPick>(
      width: 240,
      alignEnd: alignEnd,
      onSelected: _onPick,
      entries: () => _entries(profile.id),
      builder: (_, open) => trigger(open),
    );

    final name = menu(
      alignEnd: false,
      trigger: (open) => InkWell(
        onTap: open,
        borderRadius: BorderRadius.circular(MeowShape.s),
        child: Text(
          profile.label ?? profile.id,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(fontSize: dense ? 16 : 17, fontWeight: FontWeight.w800, color: cs.onSurface),
        ),
      ),
    );

    // 直连档 = 主色实心「选择订阅」；在用订阅 = 次色容器「切换订阅」（画布稿）
    final (chipBg, chipFg) = direct ? (cs.primary, cs.onPrimary) : (cs.secondaryContainer, cs.onSecondaryContainer);
    final chip = menu(
      alignEnd: true,
      trigger: (open) => Material(
        color: chipBg,
        shape: const StadiumBorder(),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: open,
          child: SizedBox(
            height: 34,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    direct ? '选择订阅' : '切换订阅',
                    maxLines: 1,
                    style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: chipFg),
                  ),
                  if (importing) ...[
                    const SizedBox(width: 6),
                    SizedBox.square(dimension: 12, child: CircularProgressIndicator(strokeWidth: 1.6, color: chipFg)),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );

    String line;
    Widget? progress;
    Widget? updated;
    if (direct) {
      line = '未使用订阅，流量全部直连';
    } else {
      final info = profile.subscriptionInfo;
      final used = (info?.upload ?? 0) + (info?.download ?? 0);
      final total = info?.total ?? 0;
      final expire = info?.expire ?? 0;
      final frac = total > 0 ? (used / total).clamp(0.0, 1.0) : 0.0;
      final hasUsage = total > 0 || used > 0;
      if (!hasUsage && expire <= 0) {
        // 订阅没给 subscription-userinfo：写明，免得只剩下面一个更新时间
        line = profile.url.isEmpty ? '本地配置' : '订阅未提供用量信息';
      } else {
        final expiry = expire <= 0
            ? '未知到期'
            : isPermanentExpire(expire)
            ? '永久'
            : '到期 ${fmtDate(DateTime.fromMillisecondsSinceEpoch(expire * 1000))}';
        line = hasUsage ? '已用 ${_usageText(used, total)} · $expiry' : expiry;
      }
      if (total > 0) {
        progress = M3WavyProgress(value: frac, color: frac > 0.9 ? cs.error : null, animate: _refreshing);
      }
      final at = profile.lastUpdateDate;
      final footStyle = TextStyle(fontSize: MeowFont.caption, color: cs.onSurfaceVariant);
      final updatedRow = Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _refreshing
              ? SizedBox.square(dimension: 14, child: CircularProgressIndicator(strokeWidth: 1.6, color: cs.onSurfaceVariant))
              : Icon(Icons.refresh_rounded, size: 16, color: cs.onSurfaceVariant),
          const SizedBox(width: 6),
          Text(at == null ? '未更新' : '${fmtRelative(at)}更新', maxLines: 1, style: footStyle),
        ],
      );
      updated = profile.url.isEmpty
          ? (at == null ? null : updatedRow)
          : Tooltip(
              message: '刷新订阅',
              child: InkWell(
                onTap: _refreshing ? null : () => _refresh(profile),
                borderRadius: BorderRadius.circular(MeowShape.s),
                child: Padding(padding: const EdgeInsets.symmetric(vertical: 4), child: updatedRow),
              ),
            );
    }

    // 照 iOS 首页订阅卡（2026-11-18 用户：安卓首页卡片太高）：名字 + 切换订阅一行，用量条，「已用 · 到期」与更新时间并排一行
    final lineText = Text(line, maxLines: 1, overflow: TextOverflow.ellipsis, style: caption);
    return M3Card(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Expanded(child: Align(alignment: Alignment.centerLeft, child: name)),
              const SizedBox(width: 12),
              chip,
            ],
          ),
          if (progress != null) ...[const SizedBox(height: 10), progress],
          SizedBox(height: progress != null ? 6 : 8),
          Row(
            children: [
              Expanded(child: lineText),
              if (updated != null) ...[const SizedBox(width: 8), updated],
            ],
          ),
        ],
      ),
    );
  }
}

/// 「128.4 / 500 GB」：已用和总量用同一个单位（按总量取 GB / MB），整数不带小数；没有总量 = 不限量。
String _usageText(int used, int total) {
  if (total <= 0) return '${fmtSize(used)} / ${S.unlimited}';
  const mb = 1024 * 1024, gb = mb * 1024;
  final (unit, name) = total >= gb ? (gb, 'GB') : (mb, 'MB');
  String n(int bytes) {
    final s = (bytes / unit).toStringAsFixed(1);
    return s.endsWith('.0') ? s.substring(0, s.length - 2) : s;
  }

  return '${n(used)} / ${n(total)} $name';
}

/// 长的 IPv6 从中间的冒号后折成两行（外面套 FittedBox 整体缩小）：完整显示，不截成「2001:db8:…」。
String _wrapIp(String ip) {
  if (ip.length <= 20 || !ip.contains(':')) return ip;
  final at = ip.indexOf(':', ip.length ~/ 2);
  return at < 0 || at == ip.length - 1 ? ip : '${ip.substring(0, at + 1)}\n${ip.substring(at + 1)}';
}

/// 首页的功能块（画布稿 Main 的「喵窝」「代理应用」两格）：色调容器底、图标在上、标题 + 一行说明在下，
/// 两格并排时圆角不对称（[borderRadius]），只有一格时整行（调用方给普通圆角）。
class HomeFeatureTile extends StatelessWidget {
  const HomeFeatureTile({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.bg,
    required this.fg,
    required this.borderRadius,
    this.trailing,
    this.onTap,
    this.single = false,
  });

  final Widget icon;
  final String title, subtitle;

  /// 只有这一格（没有并排的另一格）：排成横向一行（图标、标题与说明、行尾开关或箭头），不占 120 高
  final bool single;
  final Color bg, fg;
  final BorderRadius borderRadius;
  final Widget? trailing;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => Material(
    color: bg,
    borderRadius: borderRadius,
    clipBehavior: Clip.antiAlias,
    child: InkWell(onTap: onTap, child: single ? _row() : _tile()),
  );

  Widget _row() => Padding(
    padding: EdgeInsets.fromLTRB(16, 14, trailing == null ? 12 : 8, 14),
    child: Row(
      children: [
        IconTheme(data: IconThemeData(color: fg, size: 28), child: icon),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800, color: fg)),
              const SizedBox(height: 2),
              Text(
                subtitle,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: MeowFont.caption, color: fg.withValues(alpha: 0.85)),
              ),
            ],
          ),
        ),
        const SizedBox(width: 8),
        trailing ?? Icon(Icons.chevron_right_rounded, color: fg.withValues(alpha: 0.8)),
      ],
    ),
  );

  Widget _tile() => ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 120),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              SizedBox(
                height: 32,
                child: Row(
                  children: [
                    IconTheme(data: IconThemeData(color: fg, size: 28), child: icon),
                    const Spacer(),
                    ?trailing,
                  ],
                ),
              ),
              const SizedBox(height: 14),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800, color: fg),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: MeowFont.caption, color: fg.withValues(alpha: 0.85)),
                  ),
                ],
              ),
            ],
          ),
        ),
      );
}

/// Android 专属：分应用代理的状态与入口（次色容器的功能块）。
class HomeProxyAppsRow extends ConsumerWidget {
  const HomeProxyAppsRow({super.key, this.borderRadius = const BorderRadius.all(Radius.circular(MeowShape.xl)), this.single = false});
  final BorderRadius borderRadius;
  final bool single;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cs = context.cs;
    final access = ref.watch(vpnSettingProvider.select((s) => s.accessControl));
    final count = access.currentList.length;
    final summary = !access.enable
        ? '全部应用都走代理'
        : access.mode == AccessControlMode.acceptSelected
        ? '白名单 · 只代理选中的 $count 个应用'
        : '黑名单 · $count 个应用不走代理';
    return HomeFeatureTile(
      icon: const Icon(Icons.apps_rounded),
      title: '代理应用',
      subtitle: summary,
      bg: cs.secondaryContainer,
      fg: cs.onSecondaryContainer,
      borderRadius: borderRadius,
      single: single,
      onTap: () => BaseNavigator.push(context, const ProxyAppsPage()),
    );
  }
}

/// 指标小格（surfaceContainer 底、圆角 20）：标题 11 次级色 + 数值粗字；一行最多四格，放不下时各自整体缩小（不截断）。
class _Tile extends StatelessWidget {
  const _Tile({required this.label, required this.value, required this.dense, this.onTap, this.small = false});
  final String label, value;
  final bool dense;
  final VoidCallback? onTap;

  /// 数值是文字（DNS 模式）时用小一号
  final bool small;

  @override
  Widget build(BuildContext context) {
    final cs = context.cs;
    return M3Card(
      color: cs.card,
      radius: MeowShape.lInc,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 12),
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.center,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(
              label,
              maxLines: 1,
              style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: cs.onSurfaceVariant),
            ),
          ),
          const SizedBox(height: 2),
          FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(
              value,
              maxLines: 1,
              style: TextStyle(
                fontSize: small ? 16 : (dense ? 22 : 22),
                fontWeight: FontWeight.w800,
                color: cs.onSurface,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 等高并排的一行小格。外层高度无界（手机端的 ListView）时 Row 的 stretch 会把子项撑成无限高，所以套 IntrinsicHeight。
Widget _tileRow(List<Widget> tiles, {required bool dense}) => IntrinsicHeight(
  child: Row(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      for (final (i, t) in tiles.indexed) ...[
        if (i > 0) SizedBox(width: dense ? 10 : 8),
        Expanded(child: t),
      ],
    ],
  ),
);

/// 指标行：代理连接 / 直连连接（点了去「动态」）/ 内存 / DNS 模式。[cards] = 开着的那几格，按这个顺序排，等分一行。
class HomeMetricsRow extends ConsumerWidget {
  const HomeMetricsRow({super.key, required this.cards, this.dense = false});
  final List<HomeCard> cards;
  final bool dense;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final running = ref.watch(isRunningProvider);
    // 计数 / 内存每一两秒变一次：不在首页时不跟
    final stats = ref.watchOnTab(MeowTab.home, connStatsProvider);
    void toActivity() => goTab(ref, MeowTab.connections);
    return _tileRow([
      for (final c in cards)
        switch (c) {
          HomeCard.proxied => _Tile(
            label: S.proxyConnections,
            value: '${running ? stats.proxied : 0}',
            dense: dense,
            onTap: toActivity,
          ),
          HomeCard.direct => _Tile(
            label: S.directConnections,
            value: '${running ? stats.direct : 0}',
            dense: dense,
            onTap: toActivity,
          ),
          HomeCard.memory => _Tile(
            label: dense ? S.coreMemory : S.memory,
            value: running && stats.memory > 0 ? fmtSize(stats.memory) : '—',
            dense: dense,
            // 点开看核心的内存构成（同 iOS）
            onTap: running ? () => unawaited(showMemoryReport(context)) : null,
          ),
          _ => _DnsTile(dense: dense),
        },
    ], dense: dense);
  }
}

/// DNS 模式格：跟随订阅 / Redir-Host / Fake-IP，点按循环 follow → redir → fake；生效模式变了才重载。
class _DnsTile extends ConsumerWidget {
  const _DnsTile({required this.dense});
  final bool dense;

  static String _effective(MeowDnsMode mode, String? declared) =>
      effectiveDnsMode(mode, declared) == 'fake-ip' ? S.dnsFakeIp : S.dnsRedirHost;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mode = ref.watch(meowSettingProvider.select((s) => s.dnsMode));
    final declared = ref.watch(declaredDnsModeProvider);
    final follow = mode == MeowDnsMode.follow;
    return Tooltip(
      message: '点按切换：跟随订阅 → Redir-Host → Fake-IP',
      child: _Tile(
        small: true,
        label: dense ? (follow ? 'DNS · 跟随订阅' : 'DNS · 手动指定') : (follow ? 'DNS · 跟随' : 'DNS · 手动'),
        value: _effective(mode, declared),
        dense: dense,
        onTap: () {
          final next = MeowDnsMode.values[(mode.index + 1) % MeowDnsMode.values.length];
          final before = _effective(mode, declared);
          ref.read(meowSettingProvider.notifier).updateState((s) => s.copyWith(dnsMode: next));
          if (_effective(next, declared) != before && ref.read(isRunningProvider)) {
            globalState.appController.applyProfileDebounce();
          }
        },
      ),
    );
  }
}

/// 出口 IP：两格「中国大陆 · 直连出口」|「香港 · 经 {出站}」（地区没查到时「国内 / 国际」），国旗 + 等宽 IP。
/// 连接状态或节点变化（checkIpNum）后延迟 1.5s 重查；国内格不需要连接。手动重查在页面标题行的圆钮上。
/// 这个 widget 不在树上（「首页卡片」里关掉了出口 IP）就不查。
class HomeExitIp extends ConsumerStatefulWidget {
  const HomeExitIp({super.key, this.dense = false});
  final bool dense;

  @override
  ConsumerState<HomeExitIp> createState() => _HomeExitIpState();
}

class _HomeExitIpState extends ConsumerState<HomeExitIp> {
  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    ref.listenManual(isRunningProvider, (prev, next) => _schedule(running: next));
    ref.listenManual(checkIpNumProvider, (prev, next) => _schedule(running: ref.read(isRunningProvider)));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _schedule(running: ref.read(isRunningProvider), delay: Duration.zero);
    });
  }

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }

  void _schedule({required bool running, Duration delay = const Duration(milliseconds: 1500)}) {
    _debounce?.cancel();
    if (!running) ref.read(exitIpProvider.notifier).clearGlobal();
    _debounce = Timer(delay, () {
      if (!mounted) return;
      unawaited(ref.read(exitIpProvider.notifier).refresh(running: ref.read(isRunningProvider)));
    });
  }

  @override
  Widget build(BuildContext context) {
    final cs = context.cs;
    final dense = widget.dense;
    final running = ref.watch(isRunningProvider);
    final st = ref.watch(exitIpProvider);

    Widget tile(String title, IpInfo? info, {required bool loading, required String placeholder}) {
      final text = info?.ip ?? (loading ? S.querying : placeholder);
      final style = MeowFont.mono(size: 14, weight: FontWeight.w600, color: info == null ? cs.onSurfaceVariant : cs.onSurface);
      final code = info?.countryCode.toUpperCase() ?? '';
      return M3Card(
        color: cs.card,
        radius: MeowShape.lInc,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.center,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: cs.onSurfaceVariant),
            ),
            const SizedBox(height: 6),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                // 归属地画成国旗（2026-11-17 用户要求，以前是 HK / US 字母块；Windows 靠主题里的 Twemoji 回落）
                if (RegExp(r'^[A-Z]{2}$').hasMatch(code)) ...[
                  Text(utils.countryCodeToEmoji(code), style: const TextStyle(fontSize: 18, height: 1.1)),
                  const SizedBox(width: 6),
                ],
                Flexible(
                  // IP 要完整显示：放不下就整体缩小，长的 IPv6 先折成两行再缩（半格宽排不下 39 个字符）
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(info == null ? text : _wrapIp(text), maxLines: 2, textAlign: TextAlign.center, style: style),
                  ),
                ),
              ],
            ),
          ],
        ),
      );
    }

    final via = st.globalVia;
    // 标题开头是 IP 所属地区的中文名（同 iOS #1775：「香港 · 经 X」「中国大陆 · 直连出口」）；还没查到时照旧写「国内 / 国际」
    final domestic = (st.domestic != null ? regionNameZh(st.domestic!.countryCode) : null) ?? '国内';
    final international = (st.global != null ? regionNameZh(st.global!.countryCode) : null) ?? '国际';
    return _tileRow([
      tile('$domestic · ${S.directExit}', st.domestic, loading: st.loadingDomestic, placeholder: '—'),
      tile(
        running && via != null ? '$international · 经 $via' : '$international · ${S.proxyExit}',
        st.global,
        loading: st.loadingGlobal,
        placeholder: running ? '—' : S.disconnected,
      ),
    ], dense: dense);
  }
}
