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
import '../../state/connection.dart';
import '../../state/exit_ip.dart';
import '../../state/format.dart';
import '../../state/meow_settings.dart';
import '../../state/status.dart';
import '../../theme/glass_card.dart';
import '../../theme/tokens.dart';
import '../../theme/widgets.dart';
import '../settings/proxy_apps_page.dart';

// 这个文件里的卡片都可能放在宽屏首页的 IntrinsicHeight 里（见 dashboard_page.dart），不要用 LayoutBuilder。

/// 订阅卡：名称（点开切换订阅）+「已用 / 总量」等宽 + 6pt 用量条 + 到期 / 更新时间。没有当前订阅时是去「我的」导入的引导。
class HomeSubscriptionCard extends ConsumerWidget {
  const HomeSubscriptionCard({super.key, this.dense = false});
  final bool dense;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mm = context.mm;
    final profile = ref.watch(currentProfileProvider);
    if (profile == null) {
      return GlassCard(
        radius: dense ? 22 : 24,
        padding: EdgeInsets.symmetric(horizontal: 14, vertical: dense ? 10 : 12),
        onTap: () => goTab(ref, MeowTab.me),
        child: Row(
          children: [
            const IconTile(icon: Icons.add_rounded),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    S.noSubscription,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: dense ? 14 : 15, fontWeight: FontWeight.w600, color: mm.t1),
                  ),
                  Text(
                    '去「我的」导入订阅',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: dense ? 11 : 12, color: mm.t2),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            MeowIcon(MeowGlyph.chevron, size: 16, color: mm.t2),
          ],
        ),
      );
    }

    final info = profile.subscriptionInfo;
    final used = (info?.upload ?? 0) + (info?.download ?? 0);
    final total = info?.total ?? 0;
    final expire = info?.expire ?? 0;
    final frac = total > 0 ? (used / total).clamp(0.0, 1.0) : 0.0;
    final hasUsage = total > 0 || used > 0;
    final profiles = withDirectProfileLast(ref.watch(profilesProvider));
    final String left;
    if (expire > 0) {
      left = isPermanentExpire(expire) ? '长期有效' : '到期 ${fmtDate(DateTime.fromMillisecondsSinceEpoch(expire * 1000))}';
    } else if (isDirectProfile(profile.id)) {
      left = '内置配置';
    } else {
      // 订阅没给 subscription-userinfo：左边写明，免得只剩右边一个更新时间、卡片中间空一块
      left = profile.url.isEmpty ? '本地配置' : '订阅未提供用量信息';
    }
    final updated = profile.url.isNotEmpty && profile.lastUpdateDate != null ? '${fmtRelative(profile.lastUpdateDate!)}更新' : '';
    final foot = TextStyle(fontSize: 11, color: mm.t2);

    return GlassCard(
      radius: dense ? 22 : 24,
      padding: EdgeInsets.symmetric(horizontal: 16, vertical: dense ? 12 : 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              // 名称最多占六成、用量最多占四成（放不下就缩小）：TB 级套餐 + 窄屏 + 大字号时不把订阅名挤没 / 整行越界
              Flexible(
                flex: 3,
                child: PopupMenuButton<String>(
                  tooltip: '切换订阅',
                  padding: EdgeInsets.zero,
                  // 改 currentProfileId 即切换（ClashManager 监听后自动重载）。
                  // 之前调的 setProfileAndAutoApply 只是「更新并重载当前档」，选了别的订阅不会切过去。
                  onSelected: (id) {
                    if (profiles.getProfile(id) != null && ref.read(currentProfileIdProvider) != id) {
                      ref.read(currentProfileIdProvider.notifier).value = id;
                    }
                  },
                  itemBuilder: (_) => [
                    for (final p in profiles)
                      PopupMenuItem(value: p.id, child: Text(p.label ?? p.id, maxLines: 1, overflow: TextOverflow.ellipsis)),
                  ],
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Flexible(
                        child: Text(
                          profile.label ?? profile.id,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: dense ? 14 : 15, fontWeight: FontWeight.w600, color: mm.t1),
                        ),
                      ),
                      const SizedBox(width: 4),
                      MeowIcon(MeowGlyph.updown, size: dense ? 12 : 13, color: mm.t2),
                    ],
                  ),
                ),
              ),
              if (hasUsage) ...[
                const SizedBox(width: 8),
                Flexible(
                  flex: 2,
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.centerRight,
                    child: Text(
                      _usageText(used, total),
                      maxLines: 1,
                      style: MeowFont.mono(size: 12, color: mm.t2),
                    ),
                  ),
                ),
              ],
            ],
          ),
          if (total > 0) ...[
            SizedBox(height: dense ? 7 : 8),
            ClipRRect(
              borderRadius: BorderRadius.circular(3),
              child: LinearProgressIndicator(
                value: frac,
                minHeight: 6,
                backgroundColor: mm.card2,
                color: frac > 0.9 ? mm.slow : mm.pink,
              ),
            ),
          ],
          if (left.isNotEmpty || updated.isNotEmpty) ...[
            SizedBox(height: dense ? 7 : 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Flexible(child: Text(left, maxLines: 1, overflow: TextOverflow.ellipsis, style: foot)),
                const SizedBox(width: 8),
                Flexible(child: Text(updated, maxLines: 1, overflow: TextOverflow.ellipsis, style: foot)),
              ],
            ),
          ],
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

/// Android 专属：分应用代理的状态与入口。
class HomeProxyAppsRow extends ConsumerWidget {
  const HomeProxyAppsRow({super.key, this.dense = false});
  final bool dense;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mm = context.mm;
    final access = ref.watch(vpnSettingProvider.select((s) => s.accessControl));
    final count = access.currentList.length;
    final summary = !access.enable
        ? '全部应用都走代理'
        : access.mode == AccessControlMode.acceptSelected
        ? '白名单 · 只代理选中的 $count 个应用'
        : '黑名单 · 选中的 $count 个应用不走代理';
    return GlassCard(
      radius: 20,
      padding: const EdgeInsets.fromLTRB(14, 8, 12, 8),
      onTap: () => BaseNavigator.push(context, const ProxyAppsPage()),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 40),
        child: Row(
          children: [
            const IconTile(glyph: MeowGlyph.apps),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    '代理应用',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: dense ? 14 : 15, fontWeight: FontWeight.w600, color: mm.t1),
                  ),
                  Text(
                    summary,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: dense ? 11 : 12, color: mm.t2),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            MeowIcon(MeowGlyph.chevron, size: 16, color: mm.t2),
          ],
        ),
      ),
    );
  }
}

/// 指标小格：标题 11 次级色 + 数值圆体粗字；一行最多四格，放不下时标题和数值各自整体缩小（不截断）。
class _Tile extends StatelessWidget {
  const _Tile({required this.label, required this.value, required this.dense, this.onTap});
  final String label, value;
  final bool dense;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final mm = context.mm;
    return GlassCard(
      radius: 18,
      padding: EdgeInsets.symmetric(horizontal: dense ? 12 : 10, vertical: 10),
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(label, maxLines: 1, style: TextStyle(fontSize: 11, color: mm.t2)),
          ),
          SizedBox(height: dense ? 1 : 2),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(
              value,
              maxLines: 1,
              style: TextStyle(
                fontSize: dense ? 20 : 18,
                fontWeight: FontWeight.w700,
                color: mm.t1,
                fontFamilyFallback: meowRounded,
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
    final stats = ref.watch(connStatsProvider);
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

/// 出口 IP：两格「国内 · 直连出口」|「国际 · 经 {出站}」，地区码 + 等宽 IP。
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
    final mm = context.mm;
    final dense = widget.dense;
    final running = ref.watch(isRunningProvider);
    final st = ref.watch(exitIpProvider);

    Widget tile(String title, IpInfo? info, {required bool loading, required String placeholder}) {
      final text = info?.ip ?? (loading ? S.querying : placeholder);
      final style = MeowFont.mono(size: dense ? 14 : 13, color: info == null ? mm.t2 : mm.t1);
      final code = info?.countryCode.toUpperCase() ?? '';
      return GlassCard(
        radius: 18,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 11, color: mm.t2)),
            SizedBox(height: dense ? 4 : 5),
            Row(
              children: [
                if (code.length == 2) ...[RegionTag(code), const SizedBox(width: 6)],
                Expanded(
                  // IP 要完整显示：放不下就整体缩小，长的 IPv6 先折成两行再缩（半格宽排不下 39 个字符）
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.centerLeft,
                    child: Text(info == null ? text : _wrapIp(text), maxLines: 2, style: style),
                  ),
                ),
              ],
            ),
          ],
        ),
      );
    }

    final via = st.globalVia;
    return _tileRow([
      tile(S.domesticDirect, st.domestic, loading: st.loadingDomestic, placeholder: '—'),
      tile(
        running ? '${S.globalVia} ${via == null ? '代理' : stripFlag(via)}' : '国际 · 代理出口',
        st.global,
        loading: st.loadingGlobal,
        placeholder: running ? '—' : S.disconnected,
      ),
    ], dense: dense);
  }
}
