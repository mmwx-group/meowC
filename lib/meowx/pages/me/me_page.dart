import 'package:bett_box/common/common.dart';
import 'package:bett_box/providers/providers.dart';
import 'package:bett_box/state.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../../panel/client.dart';
import '../../state/connection.dart';
import '../../state/meow_settings.dart';
import '../../state/status.dart';
import '../../theme/glass_card.dart';
import '../../theme/page_title.dart';
import '../../theme/tokens.dart';
import '../../theme/two_pane.dart';
import '../../update/update_state.dart';
import '../settings/proxy_apps_page.dart';
import 'account_card.dart';
import 'me_kit.dart';
import 'platform_rows.dart';
import 'settings_rows.dart';
import 'subscriptions_card.dart';

/// 「我的」（原「配置」+「设置」两页）：账户 → 订阅 → 设置。
/// 手机：一页可滚，设置收成入口行，每行进一张二级页（设计稿 AMe）。
/// 宽屏：三列铺开——账户 + 订阅 | 设置分组 | 设置分组（设计稿 WSettings）；平台专属分组用粉色标题。
class MePage extends ConsumerStatefulWidget {
  const MePage({super.key});

  @override
  ConsumerState<MePage> createState() => _MePageState();
}

class _MePageState extends ConsumerState<MePage> {
  String? _error;

  void _showError(Object e) {
    if (mounted) setState(() => _error = e is PanelException ? e.message : e.toString());
  }

  @override
  Widget build(BuildContext context) {
    final mm = context.mm;
    final twoPane = ref.watch(isTwoPaneProvider);
    final rail = ref.watch(isWideLayoutProvider);
    final account = AccountCard(onError: _showError, compact: twoPane);
    final subs = SubscriptionsCard(onError: _showError, compact: twoPane);
    final errorStrip = _error == null
        ? null
        : GlassCard(
            radius: 16,
            padding: const EdgeInsets.fromLTRB(12, 4, 0, 4),
            color: mm.slow.withValues(alpha: 0.12),
            child: Row(
              children: [
                Icon(Icons.error_outline_rounded, size: 16, color: mm.slow),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(_error!, style: TextStyle(fontSize: MeowFont.footnote, color: mm.slow)),
                ),
                IconButton(
                  visualDensity: VisualDensity.compact,
                  icon: Icon(Icons.close_rounded, size: 16, color: mm.slow),
                  onPressed: () => setState(() => _error = null),
                ),
              ],
            ),
          );
    // 扫一扫只有 Android 有（登录码 / 订阅链接都认）
    final scan = system.isAndroid
        ? RoundGlassButton(
            icon: Icons.qr_code_scanner_rounded,
            tooltip: '扫码登录 / 扫码导入订阅',
            onTap: () => scanLoginOrSubscription(context, ref, onError: _showError),
          )
        : null;

    if (!twoPane) {
      return ListView(
        // 有侧栏（700–899 宽）时用宽屏的留白；手机底部要让出悬浮底栏
        padding: rail ? widePagePadding() : EdgeInsets.fromLTRB(16, 0, 16, 24 + MediaQuery.paddingOf(context).bottom),
        children: [
          PageTitle('我的', trailing: scan),
          const SizedBox(height: 12),
          account,
          const SizedBox(height: 12),
          subs,
          if (errorStrip != null) ...[const SizedBox(height: 12), errorStrip],
          const SizedBox(height: 12),
          const _EntryList(),
        ],
      );
    }

    const proxy = MeSection(title: '代理与测速', children: [ProxyRows()]);
    final traffic = MeSection(title: '流量控制', children: [TrafficRows(showProxyApps: system.isAndroid)]);
    final platform = <Widget>[
      if (isDesktopUi) ...const [
        MeSection(title: '启动与窗口', note: '关闭按钮 = 收到托盘', accent: true, children: [StartupRows()]),
        MeSection(title: '接管方式', accent: true, children: [TakeoverRows()]),
        MeSection(title: '全局快捷键', accent: true, children: [HotkeyRows()]),
      ],
      if (system.isAndroid) const MeSection(title: 'VPN 与系统', accent: true, children: [VpnSystemRows()]),
    ];
    const rest = <Widget>[
      MeSection(title: '本地代理 · 订阅', children: [LocalProxyRows(), SyncRows()]),
      MeSection(title: '外观 · 关于', children: [AppearanceRows(), LogRows(), AboutRows()]),
    ];
    // Windows：第 2 列全是专属分组，通用分组都在第 3 列；平板没有那么多专属项，通用分组两列对半分
    final colA = isDesktopUi ? platform : [proxy, traffic, ...platform];
    final colB = isDesktopUi ? [proxy, traffic, ...rest] : rest;
    Widget column(List<Widget> groups) => MeDense(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final (i, g) in groups.indexed) ...[if (i > 0) const SizedBox(height: 10), g],
        ],
      ),
    );

    return Padding(
      padding: widePagePadding().copyWith(bottom: 0),
      // 窗口再宽内容也不跟着拉长（开关离标题太远）；靠左，标题与其它页对齐
      child: Align(
        alignment: Alignment.topLeft,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1100),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              PageTitle(
                '我的',
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (scan != null) ...[scan, const SizedBox(width: 8)],
                    MePill(label: '高级设置', height: 40, onTap: () => openAdvanced(context)),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.only(bottom: 16),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SizedBox(
                        width: 292,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            account,
                            const SizedBox(height: 12),
                            subs,
                            if (errorStrip != null) ...[const SizedBox(height: 12), errorStrip],
                          ],
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(child: column(colA)),
                      const SizedBox(width: 12),
                      Expanded(child: column(colB)),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 设置入口行上的图标（设计稿的线性图标路径，24 网格）。
enum _Glyph {
  proxy('M12 3a9 9 0 1 0 0 18 9 9 0 0 0 0-18M3 12h18M12 3c3 3 3 15 0 18M12 3c-3 3-3 15 0 18'),
  traffic('M6 3v6a6 6 0 0 0 6 6v6M18 3v6a6 6 0 0 1-6 6'),
  apps('M5 4h5v5H5zM14 4h5v5h-5zM5 13h5v5H5zM14 17l2 2 4-4'),
  shield('M12 3l7 3v5c0 5-3 8-7 10-4-2-7-5-7-10V6z'),
  window('M4 5h16v14H4zM4 9h16'),
  keyboard('M3 7h18v10H3zM7 11h.01M11 11h.01M15 11h.01M8 14h8'),
  server('M4 6h16v5H4zM4 13h16v5H4zM7 8.5h.01M7 15.5h.01'),
  sync('M20 12a8 8 0 1 1-2.3-5.7M20 4v5h-5'),
  log('M6 3h9l4 4v14H6zM14 3v5h5M9 13h7M9 17h5'),
  appearance('M12 3a9 9 0 1 0 0 18zM12 3a9 9 0 0 1 0 18'),
  advanced('M4 7h10M18 7h2M4 17h2M10 17h10M16 5v4M8 15v4'),
  about('M12 3a9 9 0 1 0 0 18 9 9 0 0 0 0-18M12 11v6M12 7.5h.01');

  const _Glyph(this.d);
  final String d;
}

/// 手机上的设置入口：每行 = 图标方块 + 名字 + 当前值摘要 + 箭头，点进二级页。
/// 平台专属的几行（Android：代理应用 / VPN 与系统；Windows：启动与窗口 / 接管方式 / 全局快捷键）用粉色图标方块。
class _EntryList extends ConsumerWidget {
  const _EntryList();

  static String _join(List<String> parts, {String empty = '未开启'}) => parts.isEmpty ? empty : parts.join(' · ');

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mm = context.mm;
    final meow = ref.watch(meowSettingProvider);
    final vpn = ref.watch(vpnSettingProvider);
    final app = ref.watch(appSettingProvider);
    final port = ref.watch(patchClashConfigProvider.select((s) => s.mixedPort));
    final allowLan = ref.watch(patchClashConfigProvider.select((s) => s.allowLan));
    final themeMode = ref.watch(themeSettingProvider.select((s) => s.themeMode));
    final bypassCount = meow.bypassDomains.length + meow.bypassCidrs.length;
    final availableUpdate = ref.watch(availableUpdateProvider);

    Widget entry(_Glyph glyph, String label, String? value, VoidCallback onTap, {bool platform = false}) => MeRow(
      leading: Container(
        width: 32,
        height: 32,
        alignment: Alignment.center,
        decoration: BoxDecoration(color: platform ? mm.soft : mm.card2, borderRadius: BorderRadius.circular(10)),
        child: SvgPicture.string(
          '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24"><path d="${glyph.d}" fill="none" stroke="#000" '
          'stroke-width="1.9" stroke-linecap="round" stroke-linejoin="round"/></svg>',
          width: 17,
          height: 17,
          colorFilter: ColorFilter.mode(platform ? mm.accent : mm.t1, BlendMode.srcIn),
        ),
      ),
      label: label,
      value: value,
      chevron: true,
      onTap: onTap,
    );
    // 二级页：一张白卡装这一组的行
    VoidCallback page(String title, Widget rows, {String? caption}) =>
        () => BaseNavigator.push(
          context,
          MeSubPage.list(
            title: title,
            children: [
              MeSection(children: [rows]),
              if (caption != null) MeCaption(caption),
            ],
          ),
        );

    return MeSection(
      children: [
        entry(_Glyph.proxy, '代理与测速', '${meow.dnsMode.label} · ${meow.latencyMode.label}', page('代理与测速', const ProxyRows())),
        entry(
          _Glyph.traffic,
          '流量控制',
          _join([
            if (vpn.disableQuic) '阻止 QUIC',
            if (meow.dnsHijack.isNotEmpty) '劫持 ${meow.dnsHijack.length}',
            if (bypassCount > 0) '绕过 $bypassCount',
          ], empty: '默认'),
          page('流量控制', const TrafficRows()),
        ),
        if (system.isAndroid) ...[
          entry(
            _Glyph.apps,
            '代理应用',
            proxyAppsSummary(vpn.accessControl),
            () => BaseNavigator.push(context, const ProxyAppsPage()),
            platform: true,
          ),
          entry(
            _Glyph.shield,
            'VPN 与系统',
            _join([if (app.autoRun) '自动连接', if (vpn.networkSpeedNotification) '网速通知']),
            page('VPN 与系统', const VpnSystemRows()),
            platform: true,
          ),
        ],
        if (isDesktopUi) ...[
          entry(
            _Glyph.window,
            '启动与窗口',
            _join([if (app.autoLaunch) '开机启动', if (app.silentLaunch) '静默启动', if (app.autoRun) '自动连接']),
            page('启动与窗口', const StartupRows(), caption: '关闭按钮 = 收到托盘'),
            platform: true,
          ),
          entry(
            _Glyph.shield,
            '接管方式',
            _join([if (ref.watch(tunEnabledProvider)) '虚拟网卡', if (ref.watch(systemProxyEnabledProvider)) '系统代理']),
            page('接管方式', const TakeoverRows()),
            platform: true,
          ),
          entry(_Glyph.keyboard, '全局快捷键', null, page('全局快捷键', const HotkeyRows()), platform: true),
        ],
        entry(_Glyph.server, '本地代理', '$port · ${allowLan ? '局域网可用' : '仅本机'}', page('本地代理', const LocalProxyRows())),
        entry(
          _Glyph.sync,
          '订阅同步',
          '${syncIntervalLabels[meow.syncIntervalHours] ?? syncIntervalLabels[24]}${meow.po0Enabled ? ' · po0 加白' : ''}',
          page('订阅同步', const SyncRows()),
        ),
        entry(_Glyph.log, '日志', app.openLogs ? '已开启' : '未开启', page('日志', const LogRows())),
        entry(_Glyph.appearance, '外观', themeModeLabel(themeMode), page('外观', const AppearanceRows())),
        entry(_Glyph.advanced, '高级', '内核配置 · 备份 · 脚本', () => openAdvanced(context)),
        entry(
          _Glyph.about,
          '关于',
          // 查到新版本时把它写在入口行上，不用点进去才知道
          availableUpdate != null ? '有新版本 $availableUpdate' : '${globalState.packageInfo.version} · 检查更新',
          page('关于', const AboutRows()),
        ),
      ],
    );
  }
}
