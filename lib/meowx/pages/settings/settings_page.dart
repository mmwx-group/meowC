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
import '../../state/meow_settings.dart';
import '../../state/status.dart';
import '../../theme/glass_card.dart';
import '../../theme/page_title.dart';
import '../../theme/tokens.dart';
import '../../theme/two_pane.dart';
import 'overrides_pages.dart';
import 'proxy_apps_page.dart';

const _testUrlPresets = {
  'Cloudflare': 'https://cp.cloudflare.com/generate_204',
  'Google': 'https://www.gstatic.com/generate_204',
  'Google（connectivitycheck）': 'http://connectivitycheck.gstatic.com/generate_204',
  'Apple': 'https://captive.apple.com/hotspot-detect.html',
};

const _syncOptions = {0: '手动', 6: '6 小时', 12: '12 小时', 24: '每天', 72: '3 天'};

/// 设置页：代理 / 流量控制 / 本地代理 / 订阅 / 日志 / 外观 / 高级 / 关于（与 iOS 端分组一致）。
class SettingsPage extends ConsumerWidget {
  const SettingsPage({super.key});

  void _reloadIfRunning(WidgetRef ref) {
    if (ref.read(isRunningProvider)) globalState.appController.applyProfileDebounce(silence: true);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mm = context.mm;
    final wide = ref.watch(isWideLayoutProvider);
    final themeMode = ref.watch(themeSettingProvider.select((s) => s.themeMode));
    final meow = ref.watch(meowSettingProvider);
    final testUrl = ref.watch(appSettingProvider.select((s) => s.testUrl));
    final openLogs = ref.watch(appSettingProvider.select((s) => s.openLogs));
    final blockQuic = ref.watch(vpnSettingProvider.select((s) => s.disableQuic));
    final accessControl = ref.watch(vpnSettingProvider.select((s) => s.accessControl));
    final clash = ref.watch(patchClashConfigProvider);
    final localIp = ref.watch(localIpProvider);

    final body = ListView(
      padding: EdgeInsets.fromLTRB(wide ? 0 : 16, wide ? 16 : 0, 16, 24 + MediaQuery.paddingOf(context).bottom),
      children: [
        const PageTitle(S.settings),
        const SizedBox(height: 12),
        _Section(
          title: '代理',
          children: [
            _PickerRow<MeowDnsMode>(
              icon: Icons.dns_rounded,
              color: mm.teal,
              title: S.dnsMode,
              value: meow.dnsMode,
              values: MeowDnsMode.values,
              label: (v) => v.label,
              onChanged: (v) {
                final declared = ref.read(declaredDnsModeProvider);
                final changed = effectiveDnsMode(meow.dnsMode, declared) != effectiveDnsMode(v, declared);
                ref.read(meowSettingProvider.notifier).updateState((s) => s.copyWith(dnsMode: v));
                if (changed) _reloadIfRunning(ref);
              },
            ),
            _PickerRow<LatencyMode>(
              icon: Icons.speed_rounded,
              color: mm.accent,
              title: '测速方式',
              value: meow.latencyMode,
              values: LatencyMode.values,
              label: (v) => v.label,
              onChanged: (v) {
                ref.read(meowSettingProvider.notifier).updateState((s) => s.copyWith(latencyMode: v));
                // HTTPS 延迟 = mihomo unified-delay（去掉握手）；真连接 = 关掉它。TCPing 不涉及
                if (v != LatencyMode.tcping) {
                  ref.read(patchClashConfigProvider.notifier).updateState((c) => c.copyWith(unifiedDelay: v == LatencyMode.url));
                }
                ref.read(delayDataSourceProvider.notifier).value = {};   // 三档口径不同，旧值作废
              },
            ),
            _PickerRow<String>(
              icon: Icons.link_rounded,
              color: mm.orange,
              title: '测速地址',
              value: _testUrlPresets.containsValue(testUrl) ? testUrl : '__custom__',
              values: [..._testUrlPresets.values, '__custom__'],
              label: (v) => v == '__custom__' ? '自定义' : _testUrlPresets.entries.firstWhere((e) => e.value == v).key,
              onChanged: (v) async {
                if (v == '__custom__') {
                  final input = await _prompt(context, '自定义测速地址', testUrl, keyboard: TextInputType.url);
                  if (input == null || input.trim().isEmpty) return;
                  v = input.trim();
                }
                ref.read(appSettingProvider.notifier).updateState((s) => s.copyWith(testUrl: v));
              },
            ),
          ],
        ),
        _Section(
          title: '流量控制',
          children: [
            _SwitchRow(
              icon: Icons.block_rounded,
              color: mm.slow,
              title: '阻止 QUIC',
              subtitle: '丢弃 UDP 443，让应用回落 TCP',
              value: blockQuic,
              onChanged: (v) {
                ref.read(vpnSettingProvider.notifier).updateState((s) => s.copyWith(disableQuic: v));
                _reloadIfRunning(ref);
              },
            ),
            _SwitchRow(
              icon: Icons.notifications_active_rounded,
              color: mm.good,
              title: '代理推送服务',
              subtitle: '关闭时 FCM / GMS 推送直连',
              value: !meow.pushDirect,
              onChanged: (v) {
                ref.read(meowSettingProvider.notifier).updateState((s) => s.copyWith(pushDirect: !v));
                _reloadIfRunning(ref);
              },
            ),
            if (system.isAndroid)
              _Row(
                icon: Icons.apps_rounded,
                color: mm.accent,
                title: '代理应用',
                subtitle: !accessControl.enable
                    ? '全部应用都走代理'
                    : accessControl.mode == AccessControlMode.acceptSelected
                        ? '白名单：仅勾选的应用走代理'
                        : '黑名单：仅勾选的应用不走代理',
                trailing: _chevron(mm, accessControl.enable ? '${accessControl.currentList.length}' : '关'),
                onTap: () => BaseNavigator.push(context, const ProxyAppsPage()),
              ),
            _Row(
              icon: Icons.alt_route_rounded,
              color: mm.pur,
              title: 'DNS 劫持',
              trailing: _chevron(mm, meow.dnsHijack.isEmpty ? null : '${meow.dnsHijack.length}'),
              onTap: () => BaseNavigator.push(context, const DnsHijackPage()),
            ),
            _Row(
              icon: Icons.call_split_rounded,
              color: mm.teal,
              title: '绕过代理',
              trailing: _chevron(mm, meow.bypassDomains.isEmpty && meow.bypassCidrs.isEmpty ? null : '${meow.bypassDomains.length + meow.bypassCidrs.length}'),
              onTap: () => BaseNavigator.push(context, const BypassPage()),
            ),
          ],
        ),
        _Section(
          title: '本地代理',
          footer: '${'127.0.0.1:${clash.mixedPort}'}${clash.allowLan && localIp != null ? '  ·  $localIp:${clash.mixedPort}' : ''}（点按复制）',
          onFooterTap: () {
            Clipboard.setData(ClipboardData(text: '127.0.0.1:${clash.mixedPort}'));
            globalState.showNotifier('已复制');
          },
          children: [
            _Row(
              icon: Icons.settings_ethernet_rounded,
              color: mm.accent,
              title: '端口',
              trailing: Text('${clash.mixedPort}', style: MeowFont.mono(size: MeowFont.subheadline, color: mm.t2)),
              onTap: () async {
                final input = await _prompt(context, '本地代理端口', '${clash.mixedPort}', keyboard: TextInputType.number, helper: '范围 1024–65535');
                final port = int.tryParse(input ?? '');
                if (port == null) return;
                if (port < 1024 || port > 65535) {
                  globalState.showNotifier('端口范围 1024–65535');
                  return;
                }
                ref.read(patchClashConfigProvider.notifier).updateState((s) => s.copyWith(mixedPort: port));
              },
            ),
            _SwitchRow(
              icon: Icons.lan_rounded,
              color: mm.good,
              title: '允许局域网',
              value: clash.allowLan,
              onChanged: (v) => ref.read(patchClashConfigProvider.notifier).updateState((s) => s.copyWith(allowLan: v)),
            ),
            _Row(
              icon: Icons.person_rounded,
              color: mm.orange,
              title: '用户名',
              trailing: Text(
                meow.localProxy.username.isEmpty ? '未设置' : meow.localProxy.username,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.end,
                style: TextStyle(fontSize: MeowFont.subheadline, color: mm.t2),
              ),
              onTap: () async {
                final v = await _prompt(context, '用户名（留空 = 不认证）', meow.localProxy.username);
                if (v == null) return;
                ref.read(meowSettingProvider.notifier).updateState((s) => s.copyWith(localProxy: s.localProxy.copyWith(username: v.trim())));
                _reloadIfRunning(ref);
              },
            ),
            _Row(
              icon: Icons.password_rounded,
              color: mm.pur,
              title: '密码',
              trailing: Text(meow.localProxy.password.isEmpty ? '未设置' : '••••••', style: TextStyle(fontSize: MeowFont.subheadline, color: mm.t2)),
              onTap: () async {
                final v = await _prompt(context, '密码', meow.localProxy.password, obscure: true);
                if (v == null) return;
                ref.read(meowSettingProvider.notifier).updateState((s) => s.copyWith(localProxy: s.localProxy.copyWith(password: v)));
                _reloadIfRunning(ref);
              },
            ),
          ],
        ),
        _Section(
          title: '订阅',
          footer: '到期后下次进入 App 自动重拉当前订阅。',
          children: [
            _PickerRow<int>(
              icon: Icons.sync_rounded,
              color: mm.accent,
              title: '同步间隔',
              value: _syncOptions.containsKey(meow.syncIntervalHours) ? meow.syncIntervalHours : 24,
              values: _syncOptions.keys.toList(),
              label: (v) => _syncOptions[v]!,
              onChanged: (v) {
                ref.read(meowSettingProvider.notifier).updateState((s) => s.copyWith(syncIntervalHours: v));
                final notifier = ref.read(profilesProvider.notifier);
                for (final p in ref.read(profilesProvider)) {
                  if (p.url.isEmpty) continue;
                  notifier.setProfile(p.copyWith(autoUpdate: v > 0, autoUpdateDuration: Duration(hours: v > 0 ? v : 24)));
                }
              },
            ),
            // 开关变化由 MeowRoot 监听 po0Enabled 统一处理：打开立刻拉列表上报，关闭停表清空
            _SwitchRow(
              icon: Icons.verified_user_rounded,
              color: mm.teal,
              title: 'po0 加白',
              subtitle: '把本机出口 IP 上报到主控里登记的 po0 服务器，每 10 分钟及网络变化时自动加白',
              value: meow.po0Enabled,
              onChanged: (v) => ref.read(meowSettingProvider.notifier).updateState((s) => s.copyWith(po0Enabled: v)),
            ),
          ],
        ),
        _Section(
          title: '日志',
          footer: '默认关闭；开启后在「连接」页查看日志流。',
          children: [
            _SwitchRow(
              icon: Icons.notes_rounded,
              color: mm.t2,
              title: '记录日志',
              value: openLogs,
              onChanged: (v) => ref.read(appSettingProvider.notifier).updateState((s) => s.copyWith(openLogs: v)),
            ),
          ],
        ),
        _Section(
          title: S.appearance,
          children: [
            _PickerRow<ThemeMode>(
              icon: Icons.brightness_6_rounded,
              color: mm.pur,
              title: S.theme,
              value: themeMode,
              values: const [ThemeMode.system, ThemeMode.light, ThemeMode.dark],
              label: (v) => switch (v) {
                ThemeMode.system => S.themeSystem,
                ThemeMode.light => S.themeLight,
                ThemeMode.dark => S.themeDark,
              },
              onChanged: (v) => ref.read(themeSettingProvider.notifier).updateState((s) => s.copyWith(themeMode: v)),
            ),
          ],
        ),
        _Section(
          title: S.advanced,
          children: [
            _Row(
              icon: Icons.tune_rounded,
              color: mm.orange,
              title: S.advanced,
              subtitle: S.advancedDesc,
              trailing: _chevron(mm, null),
              onTap: () => BaseNavigator.push(context, const ToolsView()),
            ),
          ],
        ),
        _Section(
          title: S.about,
          children: [
            _Row(
              icon: Icons.info_rounded,
              color: mm.t2,
              title: S.version,
              trailing: Text(globalState.packageInfo.version, style: MeowFont.mono(size: MeowFont.subheadline, color: mm.t2)),
            ),
            _Row(
              icon: Icons.system_update_rounded,
              color: mm.accent,
              title: S.checkUpdate,
              subtitle: system.isWindows ? '有新版本时可在 App 内直接更新' : null,
              trailing: _chevron(mm, null),
              onTap: _checkUpdate,
            ),
            _Row(
              icon: Icons.gavel_rounded,
              color: mm.good,
              title: S.openSourceLicense,
              subtitle: 'GPL-3.0 · 基于 Bettbox / FlClash / mihomo',
              trailing: Icon(Icons.open_in_new_rounded, size: 18, color: mm.t3),
              onTap: () => globalState.openUrl('https://github.com/mmwx-group/meowC'),
            ),
          ],
        ),
      ],
    );
    return wide ? PageWidth(child: body) : body;
  }

  /// 手动检查更新：与 Bettbox 关于页同一条链路，出错 / 已是最新都弹提示
  static Future<void> _checkUpdate() async {
    final data = await globalState.appController.safeRun<Map<String, dynamic>?>(
      request.checkForUpdate,
      title: S.checkUpdate,
      needLoading: true,
    );
    await globalState.appController.checkUpdateResultHandle(data: data, handleError: true);
  }

  static Widget _chevron(MeowTokens mm, String? count) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      if (count != null) Text(count, style: TextStyle(fontSize: MeowFont.subheadline, color: mm.t2)),
      Icon(Icons.chevron_right_rounded, color: mm.t3),
    ],
  );

  static Future<String?> _prompt(BuildContext context, String title, String initial, {TextInputType? keyboard, bool obscure = false, String? helper}) {
    final c = TextEditingController(text: initial);
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        // 横屏弹键盘时高度不够：整体可滚，别把输入框压到按钮上
        scrollable: true,
        title: Text(title),
        content: TextField(
          controller: c,
          autofocus: true,
          keyboardType: keyboard,
          obscureText: obscure,
          decoration: InputDecoration(helperText: helper),
          onSubmitted: (v) => Navigator.of(ctx).pop(v),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.of(ctx).pop(c.text), child: const Text('确定')),
        ],
      ),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.children, this.footer, this.onFooterTap});
  final String title;
  final List<Widget> children;
  final String? footer;
  final VoidCallback? onFooterTap;

  @override
  Widget build(BuildContext context) {
    final mm = context.mm;
    return Padding(
      padding: const EdgeInsets.only(bottom: 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(left: 14, bottom: 6),
            child: Text(title, style: TextStyle(fontSize: MeowFont.footnote, color: mm.t2)),
          ),
          GlassCard(
            radius: 18,
            padding: EdgeInsets.zero,
            child: Column(
              children: [
                for (var i = 0; i < children.length; i++) ...[
                  if (i > 0) Divider(height: 1, indent: 56, color: mm.t3.withValues(alpha: 0.2)),
                  children[i],
                ],
              ],
            ),
          ),
          if (footer != null)
            Padding(
              padding: const EdgeInsets.only(left: 14, top: 6),
              child: GestureDetector(
                onTap: onFooterTap,
                child: Text(footer!, style: TextStyle(fontSize: MeowFont.caption, color: mm.t3)),
              ),
            ),
        ],
      ),
    );
  }
}

/// 行：29×29 圆角 7 纯色方块 + 白 symbol，标题 body，右侧任意。
class _Row extends StatelessWidget {
  const _Row({required this.icon, required this.color, required this.title, this.subtitle, this.trailing, this.onTap});
  final IconData icon;
  final Color color;
  final String title;
  final String? subtitle;
  final Widget? trailing;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final mm = context.mm;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        child: LayoutBuilder(
          builder: (_, constraints) => Row(
            children: [
              Container(
                width: 29,
                height: 29,
                decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(7)),
                child: Icon(icon, size: 17, color: Colors.white),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: TextStyle(fontSize: MeowFont.body, color: mm.t1)),
                    if (subtitle != null) Text(subtitle!, style: TextStyle(fontSize: MeowFont.caption, color: mm.t3)),
                  ],
                ),
              ),
              // 右侧最多占行宽 45%：长选项（如测速地址）在里面省略，不把标题挤成两行、放大字号也不溢出
              if (trailing != null)
                ConstrainedBox(
                  constraints: BoxConstraints(maxWidth: constraints.maxWidth * 0.45),
                  child: trailing,
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SwitchRow extends StatelessWidget {
  const _SwitchRow({required this.icon, required this.color, required this.title, this.subtitle, required this.value, required this.onChanged});
  final IconData icon;
  final Color color;
  final String title;
  final String? subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) => _Row(
    icon: icon,
    color: color,
    title: title,
    subtitle: subtitle,
    trailing: Switch.adaptive(value: value, onChanged: onChanged),
    onTap: () => onChanged(!value),
  );
}

class _PickerRow<T> extends StatelessWidget {
  const _PickerRow({
    required this.icon,
    required this.color,
    required this.title,
    required this.value,
    required this.values,
    required this.label,
    required this.onChanged,
  });
  final IconData icon;
  final Color color;
  final String title;
  final T value;
  final List<T> values;
  final String Function(T) label;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) {
    final mm = context.mm;
    return PopupMenuButton<T>(
      tooltip: '',
      onSelected: onChanged,
      itemBuilder: (_) => [for (final v in values) CheckedPopupMenuItem(value: v, checked: v == value, child: Text(label(v)))],
      child: _Row(
        icon: icon,
        color: color,
        title: title,
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(
              child: Text(
                label(value),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                softWrap: false,
                style: TextStyle(fontSize: MeowFont.subheadline, color: mm.t2),
              ),
            ),
            const SizedBox(width: 2),
            Icon(Icons.unfold_more_rounded, size: 18, color: mm.t3),
          ],
        ),
      ),
    );
  }
}
