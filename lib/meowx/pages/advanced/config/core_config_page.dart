import 'package:bett_box/common/common.dart';
import 'package:bett_box/models/models.dart';
import 'package:bett_box/providers/providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../me/me_kit.dart';
import 'config_kit.dart';
import 'dns_page.dart';
import 'general_page.dart';
import 'network_page.dart';
import 'sniffer_page.dart';
import 'tunnel_page.dart';

/// 内核配置：Bettbox「内核配置」页（lib/views/config/）的 M3 重写，各项读写与原版一致。
/// 项多的分组（通用 / 网络 / DNS / Hosts / 嗅探 / 转发）做成入口行进子页；NTP 与实验性配置项少，直接铺在这一页。
class CoreConfigPage extends ConsumerWidget {
  const CoreConfigPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final logLevel = ref.watch(patchClashConfigProvider.select((s) => s.logLevel));
    final mixedPort = ref.watch(patchClashConfigProvider.select((s) => s.mixedPort));
    final stack = ref.watch(patchClashConfigProvider.select((s) => s.tun.stack));
    final mtu = ref.watch(patchClashConfigProvider.select((s) => s.tun.mtu));
    final overrideDns = ref.watch(overrideDnsProvider);
    final dnsMode = ref.watch(patchClashConfigProvider.select((s) => s.dns.enhancedMode));
    final hostsCount = ref.watch(patchClashConfigProvider.select((s) => s.hosts.length));
    final overrideSniffer = ref.watch(overrideSnifferProvider);
    final snifferOn = ref.watch(patchClashConfigProvider.select((s) => s.sniffer.enable));
    final tunnelsCount = ref.watch(patchClashConfigProvider.select((s) => s.tunnels.length));
    return MeSubPage.list(
      title: '内核配置',
      children: [
        MeSection(
          title: '常规',
          children: [
            CcLinkRow(
              label: '通用',
              subtitle: '日志 ${logLevel.name} · 混合端口 $mixedPort',
              onTap: () => mePush(context, const CoreGeneralPage()),
            ),
            CcLinkRow(
              label: '网络',
              subtitle: 'TUN 栈 ${stack.name} · MTU $mtu',
              onTap: () => mePush(context, const CoreNetworkPage()),
            ),
          ],
        ),
        MeSection(
          title: '解析',
          children: [
            CcLinkRow(
              label: 'DNS',
              subtitle: overrideDns ? '已覆写 · ${dnsMode.name}' : '跟随配置',
              onTap: () => mePush(context, const CoreDnsPage()),
            ),
            CcLinkRow(
              label: 'Hosts',
              subtitle: '追加当前配置 Hosts',
              value: '$hostsCount 条',
              onTap: () => mePush(context, const _HostsPage()),
            ),
            CcLinkRow(
              label: '域名嗅探',
              subtitle: overrideSniffer ? '已覆写 · ${snifferOn ? '开启' : '关闭'}' : '跟随配置',
              onTap: () => mePush(context, const CoreSnifferPage()),
            ),
          ],
        ),
        MeSection(
          title: '转发',
          children: [
            CcLinkRow(
              label: '流量转发隧道',
              subtitle: '把本机端口转发到目标地址',
              value: '$tunnelsCount 条',
              onTap: () => mePush(context, const CoreTunnelPage()),
            ),
          ],
        ),
        const _NtpSection(),
        const _ExperimentalSection(),
      ],
    );
  }
}

PatchClashConfig _patch(WidgetRef ref) => ref.read(patchClashConfigProvider.notifier);

/// Hosts：键值表。开着「商店修复」时 services.googleapis.cn、开着「网络修复」时 dns.msftncsi.com 这两条不给删（同 Bettbox）。
class _HostsPage extends StatelessWidget {
  const _HostsPage();

  @override
  Widget build(BuildContext context) => CcMapPage(
    title: 'Hosts',
    keyHint: 'example.com',
    valueHint: '1.2.3.4',
    caption: '追加到当前配置的 hosts。',
    watch: (ref) => ref.watch(patchClashConfigProvider.select((s) => s.hosts)),
    canDelete: (ref, item) {
      final storeFix = ref.watch(vpnSettingProvider.select((s) => s.storeFix));
      final networkFix = ref.watch(vpnSettingProvider.select((s) => s.networkFix));
      return !(storeFix && item.key == 'services.googleapis.cn') && !(networkFix && item.key == 'dns.msftncsi.com');
    },
    onChange: (ref, map) => _patch(ref).updateState((s) => s.copyWith(hosts: map)),
  );
}

const _customNtpServer = '__CUSTOM_NTP_SERVER__';

/// NTP（对应 Bettbox ntp.dart）：覆写开关 + 选项；「写入系统」安卓上不显示（没有 root）。末行重置。
class _NtpSection extends ConsumerWidget {
  const _NtpSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final override = ref.watch(overrideNtpProvider);
    final ntp = ref.watch(patchClashConfigProvider.select((s) => s.ntp));
    final isPresetServer = presetNtpServers.contains(ntp.server);
    return MeSection(
      title: 'NTP',
      note: '使用 NTP 时间服务',
      children: [
        MeSwitchRow(
          label: '覆写 NTP',
          subtitle: '开启后将覆盖配置中的 NTP 选项',
          value: override,
          onChanged: (v) => ref.read(overrideNtpProvider.notifier).value = v,
        ),
        MeSwitchRow(
          label: '状态',
          subtitle: '开启 NTP 时间服务',
          value: ntp.enable,
          onChanged: (v) => _patch(ref).updateState((s) => s.copyWith.ntp(enable: v)),
        ),
        if (!system.isAndroid)
          MeSwitchRow(
            label: '写入系统',
            subtitle: '需要管理员权限',
            value: ntp.writeToSystem,
            onChanged: (v) => _patch(ref).updateState((s) => s.copyWith.ntp(writeToSystem: v)),
          ),
        CcPickerRow<String>(
          label: '服务器',
          value: isPresetServer ? ntp.server : _customNtpServer,
          values: const [...presetNtpServers, _customNtpServer],
          text: (v) => v == _customNtpServer ? '自定义 URL…' : v,
          display: ntp.server,
          mono: true,
          onChanged: (v) async {
            if (v != _customNtpServer) {
              _patch(ref).updateState((s) => s.copyWith.ntp(server: v));
              return;
            }
            final custom = await ccInput(
              context,
              title: '自定义 URL',
              initial: isPresetServer ? '' : ntp.server,
              resetValue: defaultNtpServer,
              keyboard: TextInputType.url,
              validator: ccNotEmpty('服务器'),
            );
            if (custom != null) _patch(ref).updateState((s) => s.copyWith.ntp(server: custom));
          },
        ),
        CcInputRow(
          label: '端口',
          value: '${ntp.port}',
          onTap: () async {
            final v = await ccInput(
              context,
              title: '端口',
              initial: '${ntp.port}',
              keyboard: TextInputType.number,
              validator: ccInt('端口'),
            );
            final intValue = v == null ? null : int.tryParse(v);
            if (intValue == null) return;
            _patch(ref).updateState((s) => s.copyWith.ntp(port: intValue));
          },
        ),
        CcInputRow(
          label: '更新时间',
          value: '${ntp.interval}',
          onTap: () async {
            final v = await ccInput(
              context,
              title: '更新时间',
              initial: '${ntp.interval}',
              keyboard: TextInputType.number,
              validator: ccInt('更新时间'),
            );
            final intValue = v == null ? null : int.tryParse(v);
            if (intValue == null) return;
            _patch(ref).updateState((s) => s.copyWith.ntp(interval: intValue));
          },
        ),
        MeRow(
          label: '重置 NTP',
          subtitle: '把上面的 NTP 选项恢复成默认值',
          onTap: () async {
            if (await ccConfirmReset(context)) _patch(ref).updateState((s) => s.copyWith(ntp: defaultNtp));
          },
        ),
      ],
    );
  }
}

/// 实验性配置（对应 Bettbox experimental.dart）：覆写开关 + 三个开关，末行重置。
class _ExperimentalSection extends ConsumerWidget {
  const _ExperimentalSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final override = ref.watch(overrideExperimentalProvider);
    final exp = ref.watch(patchClashConfigProvider.select((s) => s.experimental));
    void set(Experimental Function(Experimental e) f) =>
        _patch(ref).updateState((s) => s.copyWith(experimental: f(s.experimental)));
    return MeSection(
      title: '实验性',
      note: '请谨慎使用',
      children: [
        MeSwitchRow(
          label: '覆写实验性配置',
          subtitle: '开启后将覆盖配置中的实验性配置',
          value: override,
          onChanged: (v) => ref.read(overrideExperimentalProvider.notifier).value = v,
        ),
        MeSwitchRow(
          label: '禁用 QUIC 通用分段卸载',
          value: exp.quicGoDisableGso,
          onChanged: (v) => set((e) => e.copyWith(quicGoDisableGso: v)),
        ),
        MeSwitchRow(
          label: '禁用 QUIC 显式拥塞通知',
          value: exp.quicGoDisableEcn,
          onChanged: (v) => set((e) => e.copyWith(quicGoDisableEcn: v)),
        ),
        MeSwitchRow(
          label: '启用拨号 IP4P 地址转换',
          value: exp.dialerIp4pConvert,
          onChanged: (v) => set((e) => e.copyWith(dialerIp4pConvert: v)),
        ),
        MeRow(
          label: '重置实验性配置',
          subtitle: '把上面的实验性选项恢复成默认值',
          onTap: () async {
            if (await ccConfirmReset(context)) {
              _patch(ref).updateState((s) => s.copyWith(experimental: defaultExperimental));
            }
          },
        ),
      ],
    );
  }
}
