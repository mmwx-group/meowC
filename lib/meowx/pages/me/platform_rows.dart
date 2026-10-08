import 'dart:async';

import 'package:bett_box/common/common.dart';
import 'package:bett_box/enum/enum.dart';
import 'package:bett_box/plugins/service.dart';
import 'package:bett_box/providers/providers.dart';
import 'package:bett_box/state.dart';
import 'package:bett_box/views/hotkey.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/connection.dart';
import '../../theme/tokens.dart';
import '../settings/sys_proxy_bypass_page.dart';
import 'me_kit.dart';

/// 平台专属的设置分组（设计稿里粉色标题 / 粉色图标的那几组）：
/// Windows = 启动与窗口 / 接管方式 / 全局快捷键；Android = VPN 与系统。开关都是 Bettbox 原有的设置项，这里只是提到「我的」页。

/// Windows · 启动与窗口：开机启动 / 静默启动 / 启动后自动连接 / 托盘显示代理组与节点。
class StartupRows extends ConsumerWidget {
  const StartupRows({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final app = ref.watch(appSettingProvider.select((s) => (s.autoLaunch, s.silentLaunch, s.autoRun)));
    final trayGroups = ref.watch(vpnSettingProvider.select((s) => s.trayEnhancement));
    final setting = ref.read(appSettingProvider.notifier);
    return MeRows(
      children: [
        MeSwitchRow(
          label: '开机启动',
          value: app.$1,
          onChanged: (v) => setting.updateState((s) => s.copyWith(autoLaunch: v)),
        ),
        MeSwitchRow(
          label: '静默启动（不弹主窗口）',
          value: app.$2,
          onChanged: (v) => setting.updateState((s) => s.copyWith(silentLaunch: v)),
        ),
        MeSwitchRow(
          label: '启动后自动连接',
          value: app.$3,
          onChanged: (v) => setting.updateState((s) => s.copyWith(autoRun: v)),
        ),
        MeSwitchRow(
          label: '托盘显示代理组与节点',
          value: trayGroups,
          onChanged: (v) {
            ref.read(vpnSettingProvider.notifier).updateState((s) => s.copyWith(trayEnhancement: v));
            if (system.isDesktop) unawaited(globalState.appController.updateTray());
          },
        ),
      ],
    );
  }
}

/// Windows · 接管方式：虚拟网卡（TUN）/ 系统代理 / 系统代理排除域名。两个开关与首页接管卡、侧栏共用 [takeoverProvider]。
class TakeoverRows extends ConsumerWidget {
  const TakeoverRows({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mm = context.mm;
    final tun = ref.watch(tunEnabledProvider);
    final sys = ref.watch(systemProxyEnabledProvider);
    final (tunHint, tunWarn) = ref.watch(tunHintProvider);
    final installing = ref.watch(takeoverProvider.select((s) => s.installing));
    final bypass = ref.watch(networkSettingProvider.select((s) => s.bypassDomain.length));
    return MeRows(
      children: [
        MeSwitchRow(
          label: '虚拟网卡（TUN）',
          subtitle: tunHint,
          subtitleColor: tunWarn ? mm.mid : null,
          value: tun,
          onChanged: installing ? null : (v) => unawaited(ref.read(takeoverProvider.notifier).setTun(context, v)),
        ),
        MeSwitchRow(
          label: '系统代理',
          value: sys,
          onChanged: (v) => ref.read(takeoverProvider.notifier).setSystemProxy(v),
        ),
        MeRow(
          label: '系统代理排除域名',
          value: '$bypass 条',
          chevron: true,
          onTap: () => BaseNavigator.push(context, const SysProxyBypassPage()),
        ),
      ],
    );
  }
}

const _hotkeyLabels = {
  HotAction.start: '启动 / 停止',
  HotAction.view: '显示 / 隐藏窗口',
  HotAction.mode: '切换模式',
  HotAction.proxy: '系统代理',
  HotAction.tun: '虚拟网卡',
};

/// Windows · 全局快捷键：点一行进 Bettbox 的录制对话框（按下组合键 → 确定 / 移除）。
class HotkeyRows extends StatelessWidget {
  const HotkeyRows({super.key});

  @override
  Widget build(BuildContext context) =>
      MeRows(children: [for (final action in HotAction.values) _HotkeyRow(action)]);
}

class _HotkeyRow extends ConsumerWidget {
  const _HotkeyRow(this.action);
  final HotAction action;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mm = context.mm;
    final hotKey = ref.watch(getHotKeyActionProvider(action));
    final key = hotKey.key;
    final keys = key == null
        ? null
        : [...hotKey.modifiers.map((m) => m.physicalKeys.first.label), PhysicalKeyboardKey(key).label].join(' + ');
    return MeRow(
      label: _hotkeyLabels[action]!,
      value: keys == null ? '未设置' : null,
      chevron: keys == null,
      trailing: keys == null
          ? null
          : Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(color: mm.card2, borderRadius: BorderRadius.circular(7)),
              child: Text(
                keys,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: MeowFont.mono(size: MeowFont.caption2, weight: FontWeight.w600, color: mm.t1),
              ),
            ),
      onTap: () => globalState.showCommonDialog(child: HotKeyRecorder(hotKeyAction: hotKey)),
    );
  }
}

/// Android · VPN 与系统：自动连接 / 网速通知。
class VpnSystemRows extends ConsumerWidget {
  const VpnSystemRows({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final autoRun = ref.watch(appSettingProvider.select((s) => s.autoRun));
    final speedNotice = ref.watch(vpnSettingProvider.select((s) => s.networkSpeedNotification));
    return MeRows(
      children: [
        MeSwitchRow(
          label: '自动连接',
          subtitle: '应用打开后自动连接',
          value: autoRun,
          onChanged: (v) => ref.read(appSettingProvider.notifier).updateState((s) => s.copyWith(autoRun: v)),
        ),
        MeSwitchRow(
          label: '网速通知',
          subtitle: '在通知栏显示网速和订阅信息',
          value: speedNotice,
          onChanged: (v) async {
            ref.read(vpnSettingProvider.notifier).updateState((s) => s.copyWith(networkSpeedNotification: v));
            // 关掉时让通知立刻恢复成普通样式（与 Bettbox 的同名开关一致）
            if (!v && system.isAndroid) await service?.restoreNotification();
          },
        ),
      ],
    );
  }
}
