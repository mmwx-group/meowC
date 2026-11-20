import 'package:bett_box/common/common.dart';
import 'package:bett_box/common/network_matcher.dart';
import 'package:bett_box/enum/enum.dart';
import 'package:bett_box/plugins/app.dart';
import 'package:bett_box/plugins/service.dart';
import 'package:bett_box/providers/config.dart';
import 'package:bett_box/providers/providers.dart';
import 'package:bett_box/state.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../state/connection.dart';
import '../../../theme/m3_kit.dart';
import '../../me/me_kit.dart';
import 'app_dialogs.dart';

/// 其它设置（原 Bettbox「工具 › 增强工具」，`OtherSettingView`）：各项的读写、副作用与平台条件照原样。
/// 和「我的」页重复的不再放：禁用 QUIC（= 流量控制「阻止 QUIC」）、网速通知（= Android「VPN 与系统」）、
/// 托盘增强（Windows / Linux 上 = 「启动与窗口」里的「托盘显示代理组与节点」）。
class OtherSettingsPage extends ConsumerWidget {
  const OtherSettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // 「排除国内」原是「禁用 QUIC」下面的子开关：禁用 QUIC 开着、界面不是俄语时才出现
    final disableQuic = ref.watch(vpnSettingProvider.select((s) => s.disableQuic));
    final locale = ref.watch(appSettingProvider.select((s) => s.locale));
    final isRussian = locale?.toLowerCase().startsWith('ru') ?? false;
    final network = <Widget>[
      const _SmartAutoStopRows(),
      if (system.isAndroid) const _QuickResponseRow(),
      const _StoreFixRow(),
      if (disableQuic && !isRussian) const _ExcludeChinaRow(),
    ];
    final android = <Widget>[
      if (system.isAndroid) const _DozeSuspendRow(),
      if (system.isAndroid) const _HighPriorityNotificationRow(),
      if (system.isAndroid) const _BatteryOptimizationRow(),
    ];
    // 托盘（非 Android）：Windows / Linux 上「托盘增强」已在「我的 › 启动与窗口」；点击行为与菜单栏网速只 macOS
    final tray = <Widget>[
      if (!system.isAndroid && !isDesktopUi) const _TrayEnhancementRow(),
      if (system.isMacOS) ...const [_TrayClickBehaviorRow(), _TraySpeedRow()],
    ];
    final windows = <Widget>[
      if (system.isWindows) const _HighPriorityRow(),
      if (system.isWindows) const _NetworkFixRow(),
    ];
    return MeSubPage.list(
      title: '其它设置',
      children: [
        MeSection(title: '网络', children: network),
        if (android.isNotEmpty) MeSection(title: '后台与通知', accent: true, children: android),
        if (tray.isNotEmpty) MeSection(title: '托盘', children: tray),
        if (windows.isNotEmpty) MeSection(title: 'Windows', accent: true, children: windows),
      ],
    );
  }
}

/// 智能启停：连上指定网络后停止代理；打开后多一行「网络匹配」（IP / CIDR / 网关:IP/CIDR，最多 5 条）。
/// 智能启停开着时网络匹配是它的一部分，两行放在一个块里。
class _SmartAutoStopRows extends ConsumerWidget {
  const _SmartAutoStopRows();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final enabled = ref.watch(vpnSettingProvider.select((s) => s.smartAutoStop));
    final networks = ref.watch(vpnSettingProvider.select((s) => s.smartAutoStopNetworks));
    final notifier = ref.read(vpnSettingProvider.notifier);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        MeSwitchRow(
          label: '智能启停',
          subtitle: '连接指定网络后停止代理服务',
          value: enabled,
          onChanged: (v) => notifier.updateState((s) => s.copyWith(smartAutoStop: v)),
        ),
        if (enabled) ...[
          const MeSegmentGap(),
          MeRow(
            label: '网络匹配',
            subtitle: networks.isEmpty ? '输入 IP、CIDR 或 Gateway:IP/CIDR' : networks,
            chevron: true,
            onTap: () async {
              final value = await advPrompt(
                context,
                title: '网络匹配',
                initial: networks,
                hint: '输入 IP、CIDR 或 Gateway:IP/CIDR',
                validator: (v) {
                  if (v == null || v.isEmpty) return null;
                  return NetworkMatcher.getValidationError(
                    v,
                    invalidFormatMsg: '无效的 IP 或 CIDR 格式',
                    tooManyRulesMsg: '最多允许 5 个规则',
                  );
                },
              );
              if (value == null) return;
              notifier.updateState((s) => s.copyWith(smartAutoStopNetworks: value));
            },
          ),
        ],
      ],
    );
  }
}

class _DozeSuspendRow extends ConsumerWidget {
  const _DozeSuspendRow();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final value = ref.watch(vpnSettingProvider.select((s) => s.dozeSuspend));
    return MeSwitchRow(
      label: '休眠支持',
      subtitle: '开启后同步系统 Doze 休眠模式',
      value: value,
      onChanged: (v) => ref.read(vpnSettingProvider.notifier).updateState((s) => s.copyWith(dozeSuspend: v)),
    );
  }
}

/// 商店修复：开着时在覆写的 hosts 里把 services.googleapis.cn 指到 services.googleapis.com。
class _StoreFixRow extends ConsumerWidget {
  const _StoreFixRow();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final value = ref.watch(vpnSettingProvider.select((s) => s.storeFix));
    return MeSwitchRow(
      label: '商店修复',
      subtitle: '修复 Google Play 商店下载异常',
      value: value,
      onChanged: (v) {
        ref.read(vpnSettingProvider.notifier).updateState((s) => s.copyWith(storeFix: v));
        final hosts = Map<String, String>.from(ref.read(patchClashConfigProvider).hosts);
        if (v) {
          hosts['services.googleapis.cn'] = 'services.googleapis.com';
        } else {
          hosts.remove('services.googleapis.cn');
        }
        ref.read(patchClashConfigProvider.notifier).updateState((s) => s.copyWith(hosts: hosts));
      },
    );
  }
}

class _QuickResponseRow extends ConsumerWidget {
  const _QuickResponseRow();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final value = ref.watch(vpnSettingProvider.select((s) => s.quickResponse));
    return MeSwitchRow(
      label: '快速响应',
      subtitle: '网络发生变化时主动断开连接',
      value: value,
      onChanged: (v) async {
        ref.read(vpnSettingProvider.notifier).updateState((s) => s.copyWith(quickResponse: v));
        if (system.isAndroid) await service?.setQuickResponse(v);
      },
    );
  }
}

/// 排除国内：禁用 QUIC 本身在「我的 › 流量控制 › 阻止 QUIC」，这里只留子开关、出现条件不变（见页面 build）。
class _ExcludeChinaRow extends ConsumerWidget {
  const _ExcludeChinaRow();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final excludeChina = ref.watch(vpnSettingProvider.select((s) => s.excludeChina));
    return MeSwitchRow(
      label: '排除国内',
      subtitle: '阻止 QUIC 时放行中国 QUIC 流量而非全部禁用',
      value: excludeChina,
      onChanged: (v) {
        ref.read(vpnSettingProvider.notifier).updateState((s) => s.copyWith(excludeChina: v));
        globalState.appController.setupClashConfigDebounce();
      },
    );
  }
}

/// 通知栏高优先级（Android）：打开前先确认。
class _HighPriorityNotificationRow extends ConsumerWidget {
  const _HighPriorityNotificationRow();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final value = ref.watch(vpnSettingProvider.select((s) => s.highPriorityNotification));
    return MeSwitchRow(
      label: '高优先级通知',
      subtitle: '调整当前通知栏为前台高优先级',
      value: value,
      onChanged: (v) async {
        if (v) {
          final ok = await advConfirm(
            context,
            title: '高优先级通知',
            message: '高优先级通知在有些定制系统上可以缓解后台核心保活的问题，如果你的 VPN 服务当前运行正常，这个选项建议继续保持关闭，确定要开启吗？',
          );
          if (!ok) return;
        }
        ref.read(vpnSettingProvider.notifier).updateState((s) => s.copyWith(highPriorityNotification: v));
        if (system.isAndroid) await service?.setHighPriorityNotification(v);
      },
    );
  }
}

class _TrayEnhancementRow extends ConsumerWidget {
  const _TrayEnhancementRow();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final value = ref.watch(vpnSettingProvider.select((s) => s.trayEnhancement));
    return MeSwitchRow(
      label: '托盘增强',
      subtitle: '在系统托盘区菜单中控制代理组',
      value: value,
      onChanged: (v) async {
        ref.read(vpnSettingProvider.notifier).updateState((s) => s.copyWith(trayEnhancement: v));
        await globalState.appController.updateTray();
      },
    );
  }
}

const _trayClickLabels = {TrayClickBehavior.showPanel: '显示窗口', TrayClickBehavior.showMenu: '打开菜单'};

/// 托盘点击行为（只 macOS）：左键 / 右键各选一种，在对话框里一起确定。
class _TrayClickBehaviorRow extends ConsumerWidget {
  const _TrayClickBehaviorRow();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final (left, right) = ref.watch(
      vpnSettingProvider.select((s) => (s.trayLeftClickBehavior, s.trayRightClickBehavior)),
    );
    return MeRow(
      label: '托盘点击行为',
      value: '左键${_trayClickLabels[left]} · 右键${_trayClickLabels[right]}',
      chevron: true,
      onTap: () async {
        final result = await showDialog<(TrayClickBehavior, TrayClickBehavior)>(
          context: context,
          builder: (_) => _TrayClickDialog(left: left, right: right),
        );
        if (result == null) return;
        ref
            .read(vpnSettingProvider.notifier)
            .updateState((s) => s.copyWith(trayLeftClickBehavior: result.$1, trayRightClickBehavior: result.$2));
      },
    );
  }
}

class _TrayClickDialog extends StatefulWidget {
  const _TrayClickDialog({required this.left, required this.right});

  final TrayClickBehavior left;
  final TrayClickBehavior right;

  @override
  State<_TrayClickDialog> createState() => _TrayClickDialogState();
}

class _TrayClickDialogState extends State<_TrayClickDialog> {
  late TrayClickBehavior _left = widget.left;
  late TrayClickBehavior _right = widget.right;

  @override
  Widget build(BuildContext context) {
    final items = [for (final e in _trayClickLabels.entries) (e.key, e.value)];
    return AlertDialog(
      scrollable: true,
      title: const Text('托盘点击行为'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('左键点击'),
          const SizedBox(height: 8),
          MeowSlideSegment<TrayClickBehavior>(items: items, selected: _left, onChanged: (v) => setState(() => _left = v)),
          const SizedBox(height: 20),
          const Text('右键点击'),
          const SizedBox(height: 8),
          MeowSlideSegment<TrayClickBehavior>(items: items, selected: _right, onChanged: (v) => setState(() => _right = v)),
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('取消')),
        FilledButton(onPressed: () => Navigator.of(context).pop((_left, _right)), child: const Text('确定')),
      ],
    );
  }
}

class _TraySpeedRow extends ConsumerWidget {
  const _TraySpeedRow();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final value = ref.watch(vpnSettingProvider.select((s) => s.enableTraySpeed));
    return MeSwitchRow(
      label: '网速显示',
      subtitle: '在菜单栏显示上传和下载速率',
      value: value,
      onChanged: (v) async {
        ref.read(vpnSettingProvider.notifier).updateState((s) => s.copyWith(enableTraySpeed: v));
        await globalState.appController.updateTray();
      },
    );
  }
}

/// 进程高优先级（只 Windows）：写设置后立即改主程序与内核进程的优先级。
class _HighPriorityRow extends ConsumerWidget {
  const _HighPriorityRow();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final value = ref.watch(appSettingProvider.select((s) => s.enableHighPriority));
    return MeSwitchRow(
      label: '高优先级',
      subtitle: '提升主程序和内核进程的优先级',
      value: value,
      onChanged: (v) async {
        ref.read(appSettingProvider.notifier).updateState((s) => s.copyWith(enableHighPriority: v));
        if (system.isWindows) {
          try {
            await globalState.appController.setProcessPriority(v);
          } catch (e) {
            commonPrint.log('Set process priority error: $e');
            if (context.mounted) context.showSnackBar('设置进程优先级失败：$e');
          }
        }
      },
    );
  }
}

/// 网络修复（只 Windows）：以管理员身份改写 NLA 的网络探测注册表项，修系统托盘的「地球」图标；关掉时写回系统缺省值。
/// 注册表值照原 Bettbox 实现。
class _NetworkFixRow extends ConsumerWidget {
  const _NetworkFixRow();

  static const _regPath = r'HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Services\NlaSvc\Parameters\Internet';

  static List<String> _commands(bool enable) {
    String sz(String name, String value) => 'reg add "$_regPath" /v $name /t REG_SZ /d "$value" /f';
    String dword(String name, String value) => 'reg add "$_regPath" /v $name /t REG_DWORD /d $value /f';
    return [
      sz('ActiveDnsProbeContent', '131.107.255.255'),
      sz('ActiveDnsProbeContentV6', 'fd3e:4f5a:5b81::1'),
      sz('ActiveDnsProbeHost', 'dns.msftncsi.com'),
      sz('ActiveDnsProbeHostV6', 'dns.msftncsi.com'),
      sz('ActiveWebProbeContent', enable ? '' : 'Microsoft NCSI'),
      sz('ActiveWebProbeContentV6', enable ? '' : 'Microsoft NCSI'),
      sz('ActiveWebProbeHost', enable ? 'dns.alidns.com' : 'www.msftncsi.com'),
      sz('ActiveWebProbeHostV6', enable ? 'dns.alidns.com' : 'ipv6.msftncsi.com'),
      sz('ActiveWebProbePath', enable ? 'dns-query' : 'ncsi.txt'),
      sz('ActiveWebProbePathV6', enable ? 'dns-query' : 'ncsi.txt'),
      dword('CaptivePortalTimer', '0x00000000'),
      dword('CaptivePortalTimerBackOffIncrementsInSeconds', '0x00000001'),
      dword('CaptivePortalTimerMaxInSeconds', '0x0000001e'),
      dword('EnableActiveProbing', '0x00000001'),
      dword('PassivePollPeriod', '0x0000000f'),
      dword('StaleThreshold', '0x0000001e'),
      dword('WebTimeout', '0x00000023'),
    ];
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final value = ref.watch(vpnSettingProvider.select((s) => s.networkFix));
    return MeSwitchRow(
      label: '网络修复',
      subtitle: '修复系统网络检测地球图标问题',
      value: value,
      onChanged: (v) {
        try {
          for (final cmd in _commands(v)) {
            windows?.runas(cmd, '', showWindow: false);
          }
          ref.read(vpnSettingProvider.notifier).updateState((s) => s.copyWith(networkFix: v));
        } catch (e) {
          commonPrint.log('Network fix error: $e');
          if (context.mounted) context.showSnackBar('网络修复失败：$e');
        }
      },
    );
  }
}

/// 电池优化白名单（Android）：开关显示当前是否已在白名单；没在时点开关去系统设置申请，回到 App 后重查（最多 3 次）。
class _BatteryOptimizationRow extends StatefulWidget {
  const _BatteryOptimizationRow();

  @override
  State<_BatteryOptimizationRow> createState() => _BatteryOptimizationRowState();
}

class _BatteryOptimizationRowState extends State<_BatteryOptimizationRow> with WidgetsBindingObserver {
  bool? _isIgnoring;
  bool _isWaitingForSettings = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _checkStatus();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _checkStatus(maxRetries: _isWaitingForSettings ? 3 : 1);
    }
  }

  Future<void> _checkStatus({int maxRetries = 1}) async {
    for (var attempt = 0; attempt < maxRetries; attempt++) {
      try {
        final isIgnoring = await app.isIgnoringBatteryOptimizations();
        if (mounted) {
          setState(() {
            _isIgnoring = isIgnoring;
            if (isIgnoring) _isWaitingForSettings = false;
          });
        }
        if (isIgnoring || attempt >= maxRetries - 1) break;
        await Future.delayed(const Duration(milliseconds: 666));
      } catch (e) {
        commonPrint.log('Battery optimization check error: $e');
        break;
      }
    }
    if (mounted && _isWaitingForSettings) setState(() => _isWaitingForSettings = false);
  }

  Future<void> _onChanged(bool value) async {
    final isIgnoring = _isIgnoring;
    if (isIgnoring == null) return;
    if (isIgnoring) {
      context.showSnackBar('当前应用已在白名单内');
      setState(() {});
      return;
    }
    try {
      setState(() => _isWaitingForSettings = true);
      await app.requestIgnoreBatteryOptimizations();
    } catch (e) {
      commonPrint.log('Battery optimization error: $e');
      if (mounted) setState(() => _isWaitingForSettings = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return MeSwitchRow(
      label: '电池优化白名单',
      subtitle: '请求安卓电池优化白名单权限',
      value: _isIgnoring ?? false,
      onChanged: _onChanged,
    );
  }
}
