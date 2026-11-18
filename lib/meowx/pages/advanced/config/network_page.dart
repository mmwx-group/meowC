import 'package:bett_box/common/common.dart';
import 'package:bett_box/enum/enum.dart';
import 'package:bett_box/models/models.dart';
import 'package:bett_box/providers/providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../me/me_kit.dart';
import 'config_kit.dart';

/// 内核配置 › 网络（对应 Bettbox lib/views/config/network.dart）。各项的平台可见条件与原版一致：
/// 安卓有 VPN 两组，桌面有「系统」组与 TUN 开关，macOS 多「自动设置系统 DNS」，非安卓有「严格路由」。
class CoreNetworkPage extends ConsumerWidget {
  const CoreNetworkPage({super.key});

  /// 右上角「重置」：VPN 设置恢复默认（保留访问控制、VPN 开关、系统代理），TUN 恢复默认（保留开关）。同 Bettbox config.dart。
  static void reset(WidgetRef ref) {
    ref
        .read(vpnSettingProvider.notifier)
        .updateState(
          (s) => defaultVpnProps.copyWith(accessControl: s.accessControl, enable: s.enable, systemProxy: s.systemProxy),
        );
    ref
        .read(patchClashConfigProvider.notifier)
        .updateState((s) => s.copyWith(tun: defaultTun.copyWith(enable: s.tun.enable)));
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) => MeSubPage.list(
    title: '网络',
    actions: [CcResetButton(onReset: () => reset(ref))],
    children: [
      if (system.isAndroid) const MeSection(children: [_VpnRow()]),
      if (system.isAndroid) const MeSection(title: 'VPN', children: [_AllowBypassRow(), _VpnSystemProxyRow()]),
      if (system.isDesktop) const MeSection(title: '系统', children: [_SystemProxyRow(), _BypassDomainRow()]),
      MeSection(
        title: '选项',
        children: [
          if (system.isDesktop) const _TunRow(),
          if (system.isMacOS) const _AutoSetSystemDnsRow(),
          if (!system.isAndroid) const _StrictRouteRow(),
          const _IcmpForwardingRow(),
          const _DnsHijackRow(),
          const _EndpointIndependentNatRow(),
          const _TunStackRow(),
          const _MtuRow(),
          const _BypassPrivateRouteRow(),
          // 原版在桌面端「绕过私有网络」标题旁有个齿轮进地址列表，这里拆成单独一行
          if (system.isDesktop) const _BypassPrivateRouteListRow(),
        ],
      ),
    ],
  );
}

PatchClashConfig _patch(WidgetRef ref) => ref.read(patchClashConfigProvider.notifier);

class _VpnRow extends ConsumerWidget {
  const _VpnRow();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final enable = ref.watch(vpnSettingProvider.select((s) => s.enable));
    return MeSwitchRow(
      label: 'VPN',
      subtitle: '通过 VpnService 自动路由系统流量',
      value: enable,
      onChanged: (v) => ref.read(vpnSettingProvider.notifier).updateState((s) => s.copyWith(enable: v)),
    );
  }
}

class _AllowBypassRow extends ConsumerWidget {
  const _AllowBypassRow();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final allowBypass = ref.watch(vpnSettingProvider.select((s) => s.allowBypass));
    return MeSwitchRow(
      label: '允许绕过 VPN',
      subtitle: '开启后部分应用可绕过 VPN',
      value: allowBypass,
      onChanged: (v) async {
        ref.read(vpnSettingProvider.notifier).updateState((s) => s.copyWith(allowBypass: v));
        await handleNetworkConfigChange(ref);
      },
    );
  }
}

/// VpnService 附加 HTTP 代理：打开前先确认。
class _VpnSystemProxyRow extends ConsumerWidget {
  const _VpnSystemProxyRow();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final systemProxy = ref.watch(vpnSettingProvider.select((s) => s.systemProxy));
    return MeSwitchRow(
      label: '系统代理',
      subtitle: '为 VpnService 附加 HTTP 代理',
      value: systemProxy,
      onChanged: (v) async {
        if (v) {
          final ok = await ccConfirm(context, message: '非桌面端通常不推荐使用 HTTP 代理，此功能仅建议您在必要且熟悉的情况下开启');
          if (!ok) return;
        }
        ref.read(vpnSettingProvider.notifier).updateState((s) => s.copyWith(systemProxy: v));
        await handleNetworkConfigChange(ref);
      },
    );
  }
}

class _SystemProxyRow extends ConsumerWidget {
  const _SystemProxyRow();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final systemProxy = ref.watch(networkSettingProvider.select((s) => s.systemProxy));
    return MeSwitchRow(
      label: '系统代理',
      subtitle: '设置系统代理',
      value: systemProxy,
      onChanged: (v) => ref.read(networkSettingProvider.notifier).updateState((s) => s.copyWith(systemProxy: v)),
    );
  }
}

class _BypassDomainRow extends ConsumerWidget {
  const _BypassDomainRow();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final count = ref.watch(networkSettingProvider.select((s) => s.bypassDomain.length));
    return CcLinkRow(
      label: '排除域名',
      subtitle: '仅在系统代理启用时生效',
      value: '$count 条',
      onTap: () => mePush(
        context,
        CcListPage(
          title: '排除域名',
          caption: '仅在系统代理启用时生效。',
          actions: [
            CcResetButton(
              onReset: () => ref
                  .read(networkSettingProvider.notifier)
                  .updateState((s) => s.copyWith(bypassDomain: defaultBypassDomain)),
            ),
          ],
          watch: (ref) => ref.watch(networkSettingProvider.select((s) => s.bypassDomain)),
          onChange: (ref, items) =>
              ref.read(networkSettingProvider.notifier).updateState((s) => s.copyWith(bypassDomain: List.from(items))),
        ),
      ),
    );
  }
}

class _TunRow extends ConsumerWidget {
  const _TunRow();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final enable = ref.watch(patchClashConfigProvider.select((s) => s.tun.enable));
    return MeSwitchRow(
      label: '虚拟网卡',
      subtitle: '使用 TUN 接管设备流量',
      value: enable,
      onChanged: (v) => _patch(ref).updateState((s) => s.copyWith.tun(enable: v)),
    );
  }
}

/// 自动设置系统 DNS（macOS）：内核在跑且 TUN 真正开着时才能改，否则开关不可用。
class _AutoSetSystemDnsRow extends ConsumerWidget {
  const _AutoSetSystemDnsRow();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(autoSetSystemDnsStateProvider);
    final canSetSystemDns = state.a;
    return MeSwitchRow(
      label: '自动设置系统 DNS',
      value: state.b,
      onChanged: canSetSystemDns
          ? (v) => ref.read(networkSettingProvider.notifier).updateState((s) => s.copyWith(autoSetSystemDns: v))
          : null,
    );
  }
}

class _StrictRouteRow extends ConsumerWidget {
  const _StrictRouteRow();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final strictRoute = ref.watch(patchClashConfigProvider.select((s) => s.tun.strictRoute));
    return MeSwitchRow(
      label: '严格路由',
      subtitle: '使用 TUN 严格路由模式',
      value: strictRoute,
      onChanged: (v) async {
        _patch(ref).updateState((s) => s.copyWith.tun(strictRoute: v));
        await handleNetworkConfigChange(ref);
      },
    );
  }
}

/// ICMP 转发：配置里存的是 disable-icmp-forwarding，界面上取反。
class _IcmpForwardingRow extends ConsumerWidget {
  const _IcmpForwardingRow();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final icmpForwarding = ref.watch(patchClashConfigProvider.select((s) => !s.tun.disableIcmpForwarding));
    return MeSwitchRow(
      label: 'ICMP 转发',
      subtitle: '开启后将支持 ICMP Ping',
      value: icmpForwarding,
      onChanged: (v) async {
        _patch(ref).updateState((s) => s.copyWith.tun(disableIcmpForwarding: !v));
        await handleNetworkConfigChange(ref);
      },
    );
  }
}

/// DNS 劫持：开 = dns-hijack 写 any:53 与 tcp://any:53，关 = 清空。
class _DnsHijackRow extends ConsumerWidget {
  const _DnsHijackRow();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final dnsHijack = ref.watch(patchClashConfigProvider.select((s) => s.tun.dnsHijack.isNotEmpty));
    return MeSwitchRow(
      label: 'DNS 劫持',
      subtitle: '将解析导入内部 DNS 模块',
      value: dnsHijack,
      onChanged: (v) async {
        _patch(ref).updateState((s) => s.copyWith.tun(dnsHijack: v ? ['any:53', 'tcp://any:53'] : []));
        await handleNetworkConfigChange(ref);
      },
    );
  }
}

/// NAT 增强（Endpoint-Independent NAT）：打开前先确认。
class _EndpointIndependentNatRow extends ConsumerWidget {
  const _EndpointIndependentNatRow();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final value = ref.watch(patchClashConfigProvider.select((s) => s.tun.endpointIndependentNat));
    return MeSwitchRow(
      label: 'NAT 增强',
      subtitle: '优化 UDP/P2P 应用体验',
      value: value,
      onChanged: (v) async {
        if (v) {
          final ok = await ccConfirm(
            context,
            title: '提示',
            message: '启用 Endpoint-Independent NAT 功能，性能可能会略有下降，此功能仅建议您在必要且熟悉的情况下开启',
          );
          if (!ok) return;
        }
        _patch(ref).updateState((s) => s.copyWith.tun(endpointIndependentNat: v));
        await handleNetworkConfigChange(ref);
      },
    );
  }
}

class _TunStackRow extends ConsumerWidget {
  const _TunStackRow();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final stack = ref.watch(patchClashConfigProvider.select((s) => s.tun.stack));
    return CcPickerRow<TunStack>(
      label: '栈模式',
      value: stack,
      values: TunStack.values,
      text: (v) => v.name,
      onChanged: (v) async {
        _patch(ref).updateState((s) => s.copyWith.tun(stack: v));
        await handleNetworkConfigChange(ref);
      },
    );
  }
}

const _mtuPresets = [1480, 4064, 9000];

/// MTU：预设 1480 / 4064 / 9000，或自定义 1280–65535。
class _MtuRow extends ConsumerWidget {
  const _MtuRow();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mtu = ref.watch(patchClashConfigProvider.select((s) => s.tun.mtu));
    final isCustom = !_mtuPresets.contains(mtu);
    return CcPickerRow<String>(
      label: 'MTU',
      value: isCustom ? 'custom' : '$mtu',
      values: const ['1480', '4064', '9000', 'custom'],
      text: (v) => v == 'custom' ? '自定义…' : v,
      display: isCustom ? '$mtu（自定义）' : '$mtu',
      onChanged: (v) async {
        if (v == 'custom') {
          final input = await ccInput(
            context,
            title: 'MTU',
            initial: '$mtu',
            label: 'MTU',
            hint: '1280-65535',
            keyboard: TextInputType.number,
            validator: (value) {
              if (value == null || value.isEmpty) return ccEmptyTip('MTU');
              final intValue = int.tryParse(value);
              if (intValue == null) return ccNumberTip('MTU');
              if (intValue < 1280 || intValue > 65535) return 'MTU 必须在 1280-65535 之间';
              return null;
            },
          );
          final intValue = input == null ? null : int.tryParse(input);
          if (intValue == null || intValue < 1280 || intValue > 65535) return;
          _patch(ref).updateState((s) => s.copyWith.tun(mtu: intValue));
        } else {
          final intValue = int.parse(v);
          _patch(ref).updateState((s) => s.copyWith.tun(mtu: intValue));
        }
        await handleNetworkConfigChange(ref);
      },
    );
  }
}

class _BypassPrivateRouteRow extends ConsumerWidget {
  const _BypassPrivateRouteRow();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final bypassPrivateRoute = ref.watch(networkSettingProvider.select((s) => s.bypassPrivateRoute));
    return MeSwitchRow(
      label: '绕过私有网络',
      subtitle: '自动绕过私有网络 IP 地址',
      value: bypassPrivateRoute,
      onChanged: (v) async {
        ref.read(networkSettingProvider.notifier).updateState((s) => s.copyWith(bypassPrivateRoute: v));
        await handleNetworkConfigChange(ref);
      },
    );
  }
}

/// 绕过的私有网络地址列表（桌面端）：列表显示实际生效的那份（没改过时是默认值），改了 / 重置都要重新下发网络配置。
class _BypassPrivateRouteListRow extends ConsumerWidget {
  const _BypassPrivateRouteListRow();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final count = ref.watch(networkSettingProvider.select((s) => s.realBypassPrivateRouteAddress.length));
    return CcLinkRow(
      label: '私有网络地址',
      subtitle: '「绕过私有网络」绕过哪些地址',
      value: '$count 条',
      onTap: () => mePush(
        context,
        CcListPage(
          title: '绕过私有网络',
          actions: [
            CcResetButton(
              onReset: () async {
                ref
                    .read(networkSettingProvider.notifier)
                    .updateState(
                      (s) => s.copyWith(
                        bypassPrivateRouteAddress: system.isDesktop
                            ? defaultDesktopBypassPrivateRouteAddress
                            : defaultBypassPrivateRouteAddress,
                      ),
                    );
                await handleNetworkConfigChange(ref);
              },
            ),
          ],
          watch: (ref) => ref.watch(networkSettingProvider.select((s) => s.realBypassPrivateRouteAddress)),
          onChange: (ref, items) async {
            ref
                .read(networkSettingProvider.notifier)
                .updateState((s) => s.copyWith(bypassPrivateRouteAddress: List.from(items)));
            await handleNetworkConfigChange(ref);
          },
        ),
      ),
    );
  }
}
