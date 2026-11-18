import 'package:bett_box/enum/enum.dart';
import 'package:bett_box/models/models.dart';
import 'package:bett_box/providers/providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../me/me_kit.dart';
import 'config_kit.dart';

/// 内核配置 › DNS（对应 Bettbox lib/views/config/dns.dart）。改的都是 patchClashConfig.dns，
/// 只有「覆写 DNS」打开时才盖到配置上（由 Bettbox 底层决定，这里不管）。
class CoreDnsPage extends ConsumerWidget {
  const CoreDnsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // 「直连 DNS 遵循规则」只有填了直连域名服务器才显示（同 Bettbox）；在这里决定，分组里才不会多一道空的间隔
    final hasDirect = ref.watch(patchClashConfigProvider.select((s) => s.dns.directNameserver.isNotEmpty));
    return MeSubPage.list(
      title: 'DNS',
      actions: [CcResetButton(onReset: () => _patch(ref).updateState((s) => s.copyWith(dns: defaultDns)))],
      children: [
        const MeSection(children: [_OverrideDnsRow()]),
        const MeSection(
          title: '基本',
          children: [
            _DnsSwitch(label: '状态', subtitle: '关闭后将使用系统 DNS', field: _DnsBool.enable),
            _ListenRow(),
            _CacheAlgorithmRow(),
            _DnsSwitch(label: '使用 Hosts', field: _DnsBool.useHosts),
            _DnsSwitch(label: '使用系统 Hosts', field: _DnsBool.useSystemHosts),
            _DnsSwitch(label: 'IPv6', field: _DnsBool.ipv6),
            _DnsSwitch(label: '遵守规则', subtitle: 'DNS 连接跟随 Rules', field: _DnsBool.respectRules),
            _DnsSwitch(label: 'PreferH3', subtitle: '优先使用 DoH 的 HTTP/3', field: _DnsBool.preferH3),
          ],
        ),
        const MeSection(
          title: '增强模式',
          children: [
            _DnsModeRow(),
            _FakeIpRangeRow(),
            _FakeIpRangeV6Row(),
            _FakeIpFilterModeRow(),
            _DnsListRow(field: _DnsList.fakeIpFilter),
            _FakeIpTtlRow(),
          ],
        ),
        MeSection(
          title: '域名服务器',
          children: [
            const _DnsListRow(field: _DnsList.defaultNameserver),
            const _NameserverPolicyRow(),
            const _DnsListRow(field: _DnsList.nameserver),
            const _DnsListRow(field: _DnsList.fallback),
            const _DnsListRow(field: _DnsList.proxyServerNameserver),
            const _DnsListRow(field: _DnsList.directNameserver),
            if (hasDirect) const _DirectFollowPolicyRow(),
          ],
        ),
        const MeSection(
          title: 'Fallback 过滤',
          children: [
            _GeoipRow(),
            _GeoipCodeRow(),
            _FallbackConcurrentRow(),
            _DnsListRow(field: _DnsList.ipcidr),
            _DnsListRow(field: _DnsList.domain),
          ],
        ),
      ],
    );
  }
}

PatchClashConfig _patch(WidgetRef ref) => ref.read(patchClashConfigProvider.notifier);

class _OverrideDnsRow extends ConsumerWidget {
  const _OverrideDnsRow();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final override = ref.watch(overrideDnsProvider);
    return MeSwitchRow(
      label: '覆写 DNS',
      subtitle: '开启后将覆盖配置中的 DNS 选项',
      value: override,
      onChanged: (v) => ref.read(overrideDnsProvider.notifier).value = v,
    );
  }
}

/// dns 下的布尔项：读、写各自那一个字段。
enum _DnsBool {
  enable,
  useHosts,
  useSystemHosts,
  ipv6,
  respectRules,
  preferH3;

  bool read(Dns d) => switch (this) {
    enable => d.enable,
    useHosts => d.useHosts,
    useSystemHosts => d.useSystemHosts,
    ipv6 => d.ipv6,
    respectRules => d.respectRules,
    preferH3 => d.preferH3,
  };

  ClashConfig write(ClashConfig s, bool v) => switch (this) {
    enable => s.copyWith.dns(enable: v),
    useHosts => s.copyWith.dns(useHosts: v),
    useSystemHosts => s.copyWith.dns(useSystemHosts: v),
    ipv6 => s.copyWith.dns(ipv6: v),
    respectRules => s.copyWith.dns(respectRules: v),
    preferH3 => s.copyWith.dns(preferH3: v),
  };
}

class _DnsSwitch extends ConsumerWidget {
  const _DnsSwitch({required this.label, this.subtitle, required this.field});

  final String label;
  final String? subtitle;
  final _DnsBool field;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final value = ref.watch(patchClashConfigProvider.select((s) => field.read(s.dns)));
    return MeSwitchRow(
      label: label,
      subtitle: subtitle,
      value: value,
      onChanged: (v) => _patch(ref).updateState((s) => field.write(s, v)),
    );
  }
}

class _ListenRow extends ConsumerWidget {
  const _ListenRow();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final listen = ref.watch(patchClashConfigProvider.select((s) => s.dns.listen));
    return CcInputRow(
      label: '监听',
      value: listen,
      onTap: () async {
        final v = await ccInput(context, title: '监听', initial: listen, validator: ccNotEmpty('监听'));
        if (v == null) return;
        _patch(ref).updateState((s) => s.copyWith.dns(listen: v));
      },
    );
  }
}

class _CacheAlgorithmRow extends ConsumerWidget {
  const _CacheAlgorithmRow();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cacheAlgorithm = ref.watch(patchClashConfigProvider.select((s) => s.dns.cacheAlgorithm));
    return CcPickerRow<CacheAlgorithm>(
      label: '缓存算法',
      value: cacheAlgorithm,
      values: CacheAlgorithm.values,
      text: (v) => v.name,
      onChanged: (v) => _patch(ref).updateState((s) => s.copyWith.dns(cacheAlgorithm: v)),
    );
  }
}

class _DnsModeRow extends ConsumerWidget {
  const _DnsModeRow();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final enhancedMode = ref.watch(patchClashConfigProvider.select((s) => s.dns.enhancedMode));
    return CcPickerRow<DnsMode>(
      label: 'DNS 模式',
      value: enhancedMode,
      values: DnsMode.values,
      text: (v) => v.name,
      onChanged: (v) => _patch(ref).updateState((s) => s.copyWith.dns(enhancedMode: v)),
    );
  }
}

class _FakeIpRangeRow extends ConsumerWidget {
  const _FakeIpRangeRow();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final fakeIpRange = ref.watch(patchClashConfigProvider.select((s) => s.dns.fakeIpRange));
    return CcInputRow(
      label: 'FakeIP 范围',
      value: fakeIpRange,
      onTap: () async {
        final v = await ccInput(context, title: 'FakeIP 范围', initial: fakeIpRange, validator: ccNotEmpty('FakeIP 范围'));
        if (v == null) return;
        _patch(ref).updateState((s) => s.copyWith.dns(fakeIpRange: v));
      },
    );
  }
}

/// FakeIPv6 范围：没填时显示实际生效的值（开了 IPv6 是 2001:2::1/48，否则空）；
/// 没填过、又原样确定的不写入（免得把推算值固化进配置）。可以留空。
class _FakeIpRangeV6Row extends ConsumerWidget {
  const _FakeIpRangeV6Row();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final (dns, ipv6) = ref.watch(patchClashConfigProvider.select((s) => (s.dns, s.ipv6)));
    final fakeIpRangeV6 = dns.fakeIpRangeV6;
    final display = fakeIpRangeV6.isNotEmpty ? fakeIpRangeV6 : dns.effectiveFakeIpRangeV6(ipv6Enabled: ipv6);
    return CcInputRow(
      label: 'FakeIPv6 范围',
      value: display.isEmpty ? '未设置' : display,
      mono: display.isNotEmpty,
      onTap: () async {
        final v = await ccInput(context, title: 'FakeIPv6 范围', initial: display);
        if (v == null) return;
        if (v == display && fakeIpRangeV6.isEmpty) return;
        _patch(ref).updateState((s) => s.copyWith.dns(fakeIpRangeV6: v));
      },
    );
  }
}

/// FakeIP 过滤模式：只给黑名单 / 白名单两项（配置里读到的「规则」仍能显示）。
class _FakeIpFilterModeRow extends ConsumerWidget {
  const _FakeIpFilterModeRow();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mode = ref.watch(patchClashConfigProvider.select((s) => s.dns.fakeIpFilterMode));
    return CcPickerRow<FilterMode>(
      label: 'FakeIP 过滤模式',
      value: mode,
      values: const [FilterMode.blacklist, FilterMode.whitelist],
      text: (v) => switch (v) {
        FilterMode.blacklist => '黑名单',
        FilterMode.whitelist => '白名单',
        FilterMode.rule => '规则',
      },
      onChanged: (v) => _patch(ref).updateState((s) => s.copyWith.dns(fakeIpFilterMode: v)),
    );
  }
}

class _FakeIpTtlRow extends ConsumerWidget {
  const _FakeIpTtlRow();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ttl = ref.watch(patchClashConfigProvider.select((s) => s.dns.fakeIpTtl));
    return CcInputRow(
      label: 'FakeIP 有效时间',
      value: '$ttl',
      onTap: () async {
        final v = await ccInput(
          context,
          title: 'FakeIP 有效时间',
          initial: '$ttl',
          keyboard: TextInputType.number,
          validator: ccInt('FakeIP 有效时间'),
        );
        final intValue = v == null ? null : int.tryParse(v);
        if (intValue == null) return;
        _patch(ref).updateState((s) => s.copyWith.dns(fakeIpTtl: intValue));
      },
    );
  }
}

/// dns 下的字符串列表（含 fallback-filter 的两项）：入口行写条数，点进列表编辑页。
enum _DnsList {
  fakeIpFilter('FakeIP 过滤列表', null),
  defaultNameserver('默认域名服务器', '用于解析 DNS 服务器'),
  nameserver('域名服务器', '用于解析域名'),
  fallback('Fallback', '一般情况下使用境外 DNS'),
  proxyServerNameserver('代理域名服务器', '用于解析代理节点的域名'),
  directNameserver('直连域名服务器', '用于解析直连出口的域名'),
  ipcidr('IP / 掩码', null),
  domain('组织 / 域名', null);

  const _DnsList(this.label, this.subtitle);
  final String label;
  final String? subtitle;

  List<String> read(Dns d) => switch (this) {
    fakeIpFilter => d.fakeIpFilter,
    defaultNameserver => d.defaultNameserver,
    nameserver => d.nameserver,
    fallback => d.fallback,
    proxyServerNameserver => d.proxyServerNameserver,
    directNameserver => d.directNameserver,
    ipcidr => d.fallbackFilter.ipcidr,
    domain => d.fallbackFilter.domain,
  };

  ClashConfig write(ClashConfig s, List<String> items) {
    final v = List<String>.from(items);
    return switch (this) {
      fakeIpFilter => s.copyWith.dns(fakeIpFilter: v),
      defaultNameserver => s.copyWith.dns(defaultNameserver: v),
      nameserver => s.copyWith.dns(nameserver: v),
      fallback => s.copyWith.dns(fallback: v),
      proxyServerNameserver => s.copyWith.dns(proxyServerNameserver: v),
      directNameserver => s.copyWith.dns(directNameserver: v),
      ipcidr => s.copyWith.dns.fallbackFilter(ipcidr: v),
      domain => s.copyWith.dns.fallbackFilter(domain: v),
    };
  }
}

class _DnsListRow extends ConsumerWidget {
  const _DnsListRow({required this.field});

  final _DnsList field;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final count = ref.watch(patchClashConfigProvider.select((s) => field.read(s.dns).length));
    return CcLinkRow(
      label: field.label,
      subtitle: field.subtitle,
      value: '$count 条',
      onTap: () => mePush(
        context,
        CcListPage(
          title: field.label,
          watch: (ref) => ref.watch(patchClashConfigProvider.select((s) => field.read(s.dns))),
          onChange: (ref, items) => _patch(ref).updateState((s) => field.write(s, items)),
        ),
      ),
    );
  }
}

class _NameserverPolicyRow extends ConsumerWidget {
  const _NameserverPolicyRow();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final count = ref.watch(patchClashConfigProvider.select((s) => s.dns.nameserverPolicy.length));
    return CcLinkRow(
      label: '域名服务器策略',
      subtitle: '指定对应域名服务器策略',
      value: '$count 条',
      onTap: () => mePush(
        context,
        CcMapPage(
          title: '域名服务器策略',
          keyHint: 'geosite:cn、+.example.com',
          valueHint: '119.29.29.29、system',
          watch: (ref) => ref.watch(patchClashConfigProvider.select((s) => s.dns.nameserverPolicy)),
          onChange: (ref, map) => _patch(ref).updateState((s) => s.copyWith.dns(nameserverPolicy: map)),
        ),
      ),
    );
  }
}

/// 直连 DNS 遵循规则（是否显示由页面按直连域名服务器决定）。
class _DirectFollowPolicyRow extends ConsumerWidget {
  const _DirectFollowPolicyRow();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final value = ref.watch(patchClashConfigProvider.select((s) => s.dns.directNameserverFollowPolicy));
    return MeSwitchRow(
      label: '直连 DNS 遵循规则',
      value: value,
      onChanged: (v) => _patch(ref).updateState((s) => s.copyWith.dns(directNameserverFollowPolicy: v)),
    );
  }
}

class _GeoipRow extends ConsumerWidget {
  const _GeoipRow();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final geoip = ref.watch(patchClashConfigProvider.select((s) => s.dns.fallbackFilter.geoip));
    return MeSwitchRow(
      label: 'Geoip',
      value: geoip,
      onChanged: (v) => _patch(ref).updateState((s) => s.copyWith.dns.fallbackFilter(geoip: v)),
    );
  }
}

class _GeoipCodeRow extends ConsumerWidget {
  const _GeoipCodeRow();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final geoipCode = ref.watch(patchClashConfigProvider.select((s) => s.dns.fallbackFilter.geoipCode));
    return CcInputRow(
      label: 'GeoIP 代码',
      value: geoipCode,
      onTap: () async {
        final v = await ccInput(context, title: 'GeoIP 代码', initial: geoipCode, validator: ccNotEmpty('GeoIP 代码'));
        if (v == null) return;
        _patch(ref).updateState((s) => s.copyWith.dns.fallbackFilter(geoipCode: v));
      },
    );
  }
}

/// Fallback 并发：配置里存的是 fallback-lazy-query，界面上取反。
class _FallbackConcurrentRow extends ConsumerWidget {
  const _FallbackConcurrentRow();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final lazy = ref.watch(patchClashConfigProvider.select((s) => s.dns.fallbackLazyQuery));
    return MeSwitchRow(
      label: 'Fallback 并发',
      subtitle: '使用默认 DNS 和 Fallback 同步查询',
      value: !lazy,
      onChanged: (v) => _patch(ref).updateState((s) => s.copyWith.dns(fallbackLazyQuery: !v)),
    );
  }
}
