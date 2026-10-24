import 'package:bett_box/common/common.dart';
import 'package:bett_box/enum/enum.dart';
import 'package:bett_box/models/models.dart';
import 'package:bett_box/providers/providers.dart';
import 'package:bett_box/state.dart';
import 'package:bett_box/views/views.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/strings.dart';
import '../../config/meow_patch.dart';
import '../../state/app_icon.dart';
import '../../state/meow_settings.dart';
import '../../state/status.dart';
import '../../theme/tokens.dart';
import '../../update/update_state.dart';
import '../settings/custom_rules_page.dart';
import '../settings/overrides_pages.dart';
import '../settings/po0_servers_page.dart';
import '../settings/proxy_apps_page.dart';
import 'appearance_parts.dart';
import 'me_kit.dart';

/// 各平台通用的设置分组。每组是一个 [MeRows]：手机上各自进一张二级页，宽屏直接铺在分组卡里（见 me_page.dart）。

const _testUrlPresets = {
  'Cloudflare': 'https://cp.cloudflare.com/generate_204',
  'Google': 'https://www.gstatic.com/generate_204',
  'Google（connectivitycheck）': 'http://connectivitycheck.gstatic.com/generate_204',
  'Apple': 'https://captive.apple.com/hotspot-detect.html',
};

const _customTestUrl = '__custom__';

const syncIntervalLabels = {0: '手动', 6: '6 小时', 12: '12 小时', 24: '每天', 72: '3 天'};

String themeModeLabel(ThemeMode m) => switch (m) {
  ThemeMode.system => S.themeSystem,
  ThemeMode.light => S.themeLight,
  ThemeMode.dark => S.themeDark,
};

/// 「代理应用」行右侧 / 入口行的摘要。
String proxyAppsSummary(AccessControl access) => !access.enable
    ? '未开启'
    : '${access.mode == AccessControlMode.acceptSelected ? '白名单' : '黑名单'} · ${access.currentList.length} 个应用';

/// 改了要重新生成配置的项（覆写只在 patchRawConfig 里生效）：连着就重载。
void _reloadIfRunning(WidgetRef ref) {
  if (ref.read(isRunningProvider)) globalState.appController.applyProfileDebounce(silence: true);
}

/// 代理与测速：DNS 模式 / 测速方式 / 测速地址。
class ProxyRows extends ConsumerWidget {
  const ProxyRows({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final dnsMode = ref.watch(meowSettingProvider.select((s) => s.dnsMode));
    final latencyMode = ref.watch(meowSettingProvider.select((s) => s.latencyMode));
    final testUrl = ref.watch(appSettingProvider.select((s) => s.testUrl));
    return MeRows(
      children: [
        MePickerRow<MeowDnsMode>(
          label: S.dnsMode,
          value: dnsMode,
          values: MeowDnsMode.values,
          text: (v) => v.label,
          onChanged: (v) {
            final declared = ref.read(declaredDnsModeProvider);
            final changed = effectiveDnsMode(dnsMode, declared) != effectiveDnsMode(v, declared);
            ref.read(meowSettingProvider.notifier).updateState((s) => s.copyWith(dnsMode: v));
            if (changed) _reloadIfRunning(ref);
          },
        ),
        MePickerRow<LatencyMode>(
          label: '测速方式',
          value: latencyMode,
          values: LatencyMode.values,
          text: (v) => v.label,
          onChanged: (v) {
            ref.read(meowSettingProvider.notifier).updateState((s) => s.copyWith(latencyMode: v));
            // HTTPS 延迟 = mihomo unified-delay（去掉握手）；真连接 = 关掉它。TCPing 不涉及
            if (v != LatencyMode.tcping) {
              ref.read(patchClashConfigProvider.notifier).updateState((c) => c.copyWith(unifiedDelay: v == LatencyMode.url));
            }
            ref.read(delayDataSourceProvider.notifier).value = {};   // 三档口径不同，旧值作废
          },
        ),
        MePickerRow<String>(
          label: '测速地址',
          value: _testUrlPresets.containsValue(testUrl) ? testUrl : _customTestUrl,
          values: [..._testUrlPresets.values, _customTestUrl],
          text: (v) => v == _customTestUrl ? '自定义' : _testUrlPresets.entries.firstWhere((e) => e.value == v).key,
          onChanged: (v) async {
            if (v == _customTestUrl) {
              final input = await mePrompt(context, '自定义测速地址', testUrl, keyboard: TextInputType.url);
              if (input == null || input.trim().isEmpty) return;
              v = input.trim();
            }
            ref.read(appSettingProvider.notifier).updateState((s) => s.copyWith(testUrl: v));
          },
        ),
      ],
    );
  }
}

/// 流量控制：阻止 QUIC / 代理推送服务 / DNS 劫持 / 绕过代理 / 自定义规则。
/// [showProxyApps] = 把 Android 的「代理应用」入口也列在这里（宽屏没有入口行那一层）。
class TrafficRows extends ConsumerWidget {
  const TrafficRows({super.key, this.showProxyApps = false});
  final bool showProxyApps;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final meow = ref.watch(meowSettingProvider);
    final blockQuic = ref.watch(vpnSettingProvider.select((s) => s.disableQuic));
    final bypassCount = meow.bypassDomains.length + meow.bypassCidrs.length;
    return MeRows(
      children: [
        MeSwitchRow(
          label: '阻止 QUIC',
          subtitle: '丢弃 UDP 443，让应用回落 TCP',
          value: blockQuic,
          onChanged: (v) {
            ref.read(vpnSettingProvider.notifier).updateState((s) => s.copyWith(disableQuic: v));
            _reloadIfRunning(ref);
          },
        ),
        MeSwitchRow(
          label: '代理推送服务',
          subtitle: '关闭时 FCM / GMS 推送直连',
          value: !meow.pushDirect,
          onChanged: (v) {
            ref.read(meowSettingProvider.notifier).updateState((s) => s.copyWith(pushDirect: !v));
            _reloadIfRunning(ref);
          },
        ),
        if (showProxyApps)
          MeRow(
            label: '代理应用',
            value: proxyAppsSummary(ref.watch(vpnSettingProvider.select((s) => s.accessControl))),
            chevron: true,
            onTap: () => BaseNavigator.push(context, const ProxyAppsPage()),
          ),
        MeRow(
          label: 'DNS 劫持',
          value: meow.dnsHijack.isEmpty ? null : '${meow.dnsHijack.length} 条',
          chevron: true,
          onTap: () => mePush(context, const DnsHijackPage()),
        ),
        MeRow(
          label: '绕过代理',
          value: bypassCount == 0 ? null : '$bypassCount 条',
          chevron: true,
          onTap: () => mePush(context, const BypassPage()),
        ),
        MeRow(
          label: '自定义规则',
          value: meow.customRules.isEmpty ? null : '${meow.customRules.length} 条',
          chevron: true,
          onTap: () => mePush(context, const CustomRulesPage()),
        ),
      ],
    );
  }
}

/// 本地代理：端口 / 允许局域网 / 用户名 / 密码；组末是监听地址（点按复制）。
class LocalProxyRows extends ConsumerWidget {
  const LocalProxyRows({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final clash = ref.watch(patchClashConfigProvider);
    final local = ref.watch(meowSettingProvider.select((s) => s.localProxy));
    final localIp = ref.watch(localIpProvider);
    return MeRows(
      footer:
          '127.0.0.1:${clash.mixedPort}${clash.allowLan && localIp != null ? '  ·  $localIp:${clash.mixedPort}' : ''}（点按复制）',
      onFooterTap: () {
        Clipboard.setData(ClipboardData(text: '127.0.0.1:${clash.mixedPort}'));
        globalState.showNotifier('已复制');
      },
      children: [
        MeRow(
          label: '端口',
          value: '${clash.mixedPort}',
          mono: true,
          chevron: true,
          onTap: () async {
            final input = await mePrompt(
              context,
              '本地代理端口',
              '${clash.mixedPort}',
              keyboard: TextInputType.number,
              helper: '范围 1024–65535',
            );
            final port = int.tryParse(input ?? '');
            if (port == null) return;
            if (port < 1024 || port > 65535) {
              globalState.showNotifier('端口范围 1024–65535');
              return;
            }
            ref.read(patchClashConfigProvider.notifier).updateState((s) => s.copyWith(mixedPort: port));
          },
        ),
        MeSwitchRow(
          label: '允许局域网',
          value: clash.allowLan,
          onChanged: (v) => ref.read(patchClashConfigProvider.notifier).updateState((s) => s.copyWith(allowLan: v)),
        ),
        MeRow(
          label: '用户名',
          value: local.username.isEmpty ? '未设置' : local.username,
          chevron: true,
          onTap: () async {
            final v = await mePrompt(context, '用户名（留空 = 不认证）', local.username);
            if (v == null) return;
            ref
                .read(meowSettingProvider.notifier)
                .updateState((s) => s.copyWith(localProxy: s.localProxy.copyWith(username: v.trim())));
            _reloadIfRunning(ref);
          },
        ),
        MeRow(
          label: '密码',
          value: local.password.isEmpty ? '未设置' : '••••••',
          chevron: true,
          onTap: () async {
            final v = await mePrompt(context, '密码', local.password, obscure: true);
            if (v == null) return;
            ref
                .read(meowSettingProvider.notifier)
                .updateState((s) => s.copyWith(localProxy: s.localProxy.copyWith(password: v)));
            _reloadIfRunning(ref);
          },
        ),
      ],
    );
  }
}

/// 订阅同步：同步间隔 / po0 加白 / 自定义 po0 服务器。
class SyncRows extends ConsumerWidget {
  const SyncRows({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hours = ref.watch(meowSettingProvider.select((s) => s.syncIntervalHours));
    final po0 = ref.watch(meowSettingProvider.select((s) => s.po0Enabled));
    final po0Custom = ref.watch(meowSettingProvider.select((s) => s.po0Custom.length));
    return MeRows(
      footer: '到期后下次进入 App 自动重拉当前订阅。',
      children: [
        MePickerRow<int>(
          label: MeDense.of(context) ? '订阅同步间隔' : '同步间隔',
          value: syncIntervalLabels.containsKey(hours) ? hours : 24,
          values: syncIntervalLabels.keys.toList(),
          text: (v) => syncIntervalLabels[v]!,
          onChanged: (v) {
            ref.read(meowSettingProvider.notifier).updateState((s) => s.copyWith(syncIntervalHours: v));
            final notifier = ref.read(profilesProvider.notifier);
            for (final p in ref.read(profilesProvider)) {
              if (p.url.isEmpty) continue;
              notifier.setProfile(
                p.copyWith(autoUpdate: v > 0, autoUpdateDuration: Duration(hours: v > 0 ? v : 24)),
              );
            }
          },
        ),
        // 开关与自定义条目的变化由 MeowRoot 统一处理：打开 / 增删立刻拉列表上报，关闭停表清空
        MeSwitchRow(
          label: 'po0 加白',
          subtitle: '把本机出口 IP 上报到 po0 服务器（主控登记的与自己添加的），每 10 分钟及网络变化时自动加白',
          value: po0,
          onChanged: (v) => ref.read(meowSettingProvider.notifier).updateState((s) => s.copyWith(po0Enabled: v)),
        ),
        MeRow(
          label: '自定义 po0 服务器',
          value: po0Custom == 0 ? null : '$po0Custom 条',
          chevron: true,
          onTap: () => mePush(context, const Po0ServersPage()),
        ),
      ],
    );
  }
}

/// 「记录日志」开关：「我的」页设置列表里直接一行（不再进二级页）。[leading] = 手机入口列表里的图标方块。
class LogSwitchRow extends ConsumerWidget {
  const LogSwitchRow({super.key, this.leading});

  final Widget? leading;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final openLogs = ref.watch(appSettingProvider.select((s) => s.openLogs));
    return MeSwitchRow(
      leading: leading,
      label: '记录日志',
      subtitle: '开启后额外记录每条连接的分流与 DNS 详情',
      value: openLogs,
      onChanged: (v) => ref.read(appSettingProvider.notifier).updateState((s) => s.copyWith(openLogs: v)),
    );
  }
}

/// 外观：深浅色 / 主题风格（经典 · 液态玻璃）/ 玻璃样式（只在液态玻璃下）/ 卡片颜色 / 启动卡片颜色 / 强调色 / App 图标（只 Android）。后几项见 appearance_parts.dart。
class AppearanceRows extends ConsumerWidget {
  const AppearanceRows({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final themeMode = ref.watch(themeSettingProvider.select((s) => s.themeMode));
    final glass = ref.watch(meowSettingProvider.select((s) => s.themeStyle == MeowThemeStyle.glass));
    return MeRows(
      children: [
        MePickerRow<ThemeMode>(
          label: S.theme,
          value: themeMode,
          values: const [ThemeMode.system, ThemeMode.light, ThemeMode.dark],
          text: themeModeLabel,
          onChanged: (v) => ref.read(themeSettingProvider.notifier).updateState((s) => s.copyWith(themeMode: v)),
        ),
        const ThemeStyleRow(),
        if (glass) const GlassTintRow(),
        const ColorChoiceRow(MeowColorKind.card),
        const ColorChoiceRow(MeowColorKind.hero),
        const ColorChoiceRow(MeowColorKind.accent),
        if (ref.watch(appIconSupportedProvider)) const AppIconRow(),
      ],
    );
  }
}

/// 关于：版本 / 检查更新 / 开源许可。
class AboutRows extends ConsumerWidget {
  const AboutRows({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // 自动 / 手动检查查到的新版本：行尾直接写出来，弹窗被点掉以后还找得到
    final available = ref.watch(availableUpdateProvider);
    return MeRows(
      children: [
        MeRow(label: S.version, value: globalState.packageInfo.version, mono: true),
        MeRow(
          label: S.checkUpdate,
          subtitle: system.isWindows || system.isAndroid ? '有新版本时可在 App 内直接更新' : null,
          value: available == null ? null : S.newVersionAvailable(available),
          chevron: true,
          // 与 Bettbox 关于页同一条链路：有新版弹下载 / 更新，已是最新和检查失败分别提示
          onTap: () => globalState.appController.manualCheckUpdate(),
        ),
        MeRow(
          label: S.openSourceLicense,
          subtitle: 'GPL-3.0 · 基于 Bettbox / FlClash / mihomo',
          trailing: Icon(Icons.open_in_new_rounded, size: 16, color: context.mm.t2),
          onTap: () => globalState.openUrl('https://github.com/mmwx-group/meowC'),
        ),
        MeRow(
          label: '免责声明',
          chevron: true,
          onTap: () => globalState.showMessage(
            title: '免责声明',
            message: TextSpan(text: [for (final (i, line) in meowDisclaimer.indexed) '${i + 1}. $line'].join('\n\n')),
            confirmText: '知道了',
            cancelable: false,
          ),
        ),
      ],
    );
  }
}

/// 「关于」里的免责声明（与 iOS / macOS 的 `AppInfo.disclaimer` 同一份文字）。
const meowDisclaimer = [
  'MeowX 是网络代理客户端，本身不提供任何代理服务器、节点或订阅。配置与订阅均由使用者自行导入，其内容与服务由提供方负责，与本软件无关。',
  '请在遵守所在国家和地区法律法规的前提下使用本软件，不得用于任何违法违规用途。',
  '本软件按现状提供，不对连接的可用性、稳定性、速度或安全性作任何保证。',
  '因使用本软件产生的任何直接或间接后果由使用者自行承担，开发者不承担任何责任。',
  '使用本软件即表示你已阅读、理解并同意本声明。',
];

/// 进 Bettbox 的完整设置与工具（内核配置、备份、脚本等）。
void openAdvanced(BuildContext context) => BaseNavigator.push(context, const ToolsView());
