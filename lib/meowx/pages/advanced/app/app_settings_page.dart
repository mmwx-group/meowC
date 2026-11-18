import 'package:bett_box/common/common.dart';
import 'package:bett_box/providers/config.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../state/connection.dart';
import '../../me/me_kit.dart';

/// 应用设置（原 Bettbox「工具 › 应用程序」，`ApplicationSettingView`）：各开关读写原样（[appSettingProvider]，
/// 标题按钮在 [vpnSettingProvider]）。和「我的」页重复的不再放：
/// 开机启动 / 静默启动 / 自动连接在 Windows / Linux 上 =「启动与窗口」，自动连接在 Android 上 =「VPN 与系统」。
class AppSettingsPage extends ConsumerWidget {
  const AppSettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final app = ref.watch(appSettingProvider);
    final alwaysShowTitleBar = ref.watch(vpnSettingProvider.select((s) => s.alwaysShowTitleBar));
    final setting = ref.read(appSettingProvider.notifier);

    final startup = <Widget>[
      if (!isDesktopUi)
        MeSwitchRow(
          label: '开机启动',
          subtitle: '跟随系统自启动',
          value: app.autoLaunch,
          onChanged: (v) => setting.updateState((s) => s.copyWith(autoLaunch: v)),
        ),
      if (system.isDesktop && !isDesktopUi)
        MeSwitchRow(
          label: '静默启动',
          subtitle: '不打开软件直接在后台启动',
          value: app.silentLaunch,
          onChanged: (v) => setting.updateState((s) => s.copyWith(silentLaunch: v)),
        ),
      if (!isDesktopUi && !system.isAndroid)
        MeSwitchRow(
          label: '自动连接',
          subtitle: '应用打开后自动连接',
          value: app.autoRun,
          onChanged: (v) => setting.updateState((s) => s.copyWith(autoRun: v)),
        ),
      if (system.isAndroid)
        MeSwitchRow(
          label: '后台隐藏',
          subtitle: '从最近任务中隐藏应用',
          value: app.hidden,
          onChanged: (v) => setting.updateState((s) => s.copyWith(hidden: v)),
        ),
    ];
    final ui = <Widget>[
      if (system.isWindows || system.isLinux)
        MeSwitchRow(
          label: '标题按钮',
          subtitle: '始终显示右上角的标题栏按钮',
          value: alwaysShowTitleBar,
          onChanged: (v) =>
              ref.read(vpnSettingProvider.notifier).updateState((s) => s.copyWith(alwaysShowTitleBar: v)),
        ),
      MeSwitchRow(
        label: '联动开关',
        subtitle: '首页显示独立的开关按钮',
        value: app.showStartSwitch,
        onChanged: (v) => setting.updateState((s) => s.copyWith(showStartSwitch: v)),
      ),
      if (system.isAndroid)
        MeSwitchRow(
          label: '触感反馈',
          subtitle: '底部导航栏切换震动反馈',
          value: app.enableNavBarHapticFeedback,
          onChanged: (v) => setting.updateState((s) => s.copyWith(enableNavBarHapticFeedback: v)),
        ),
    ];
    return MeSubPage.list(
      title: '应用设置',
      children: [
        if (startup.isNotEmpty) MeSection(title: '启动', children: startup),
        MeSection(title: '界面', children: ui),
        MeSection(
          title: '连接与统计',
          children: [
            MeSwitchRow(
              label: '自动关闭连接',
              subtitle: '切换节点后自动关闭连接',
              value: app.closeConnections,
              onChanged: (v) => setting.updateState((s) => s.copyWith(closeConnections: v)),
            ),
            MeSwitchRow(
              label: '代理流量统计',
              subtitle: '开启后将只统计代理流量',
              value: app.onlyStatisticsProxy,
              onChanged: (v) => setting.updateState((s) => s.copyWith(onlyStatisticsProxy: v)),
            ),
          ],
        ),
        MeSection(
          title: '更新',
          children: [
            MeSwitchRow(
              label: '自动检查更新',
              subtitle: '应用启动时自动检查更新',
              value: app.autoCheckUpdate,
              onChanged: (v) => setting.updateState((s) => s.copyWith(autoCheckUpdate: v)),
            ),
          ],
        ),
      ],
    );
  }
}
