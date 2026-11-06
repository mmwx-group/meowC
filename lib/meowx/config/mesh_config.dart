// 喵窝（主控内置的组网）与订阅里的 Tailscale 组网节点：「组网」三选一的规则、运行配置的改写、TUN 路由的调整。
// 全是纯函数，可单测；状态与主控交互在 lib/meowx/state/mesh.dart。设计见 MeowX 仓库 Design/meshnet.md §8 / §10。
import 'dart:convert';

import 'package:bett_box/models/meow.dart';

/// 「组网」三选一：喵窝与订阅里的 Tailscale 组网节点只能开一个——两边都用 100.64.0.0/10、各起一台设备，同时开会抢路由。
enum NetworkingMode { off, mesh, tailscale }

/// 注入的喵窝节点名（规则 / DNS 策略按它引用）。显示名走多语言（arb 的 meowNest），这个名字是配置里的标识、不翻译。
const meshOutboundName = '喵窝';

/// 喵窝节点的状态目录（相对内核 home）：设备密钥存在这里，删了就是一台新设备
const meshStateDir = 'meowx-mesh';

/// tsnet 的状态文件名（`<state-dir>/tailscaled.state`）
const meshStateFile = 'tailscaled.state';

/// 喵窝设备地址段（Tailscale / Headscale 惯例）
const meshDeviceCidr = '100.64.0.0/10';

/// 现在开着的是哪个：喵窝开着就是喵窝；否则订阅里有组网节点且没被停用就是 Tailscale。
NetworkingMode networkingModeOf(MeowSettings s, {required bool hasTailscaleNodes}) {
  if (s.mesh.enabled) return NetworkingMode.mesh;
  if (hasTailscaleNodes && s.tailscaleNodes) return NetworkingMode.tailscale;
  return NetworkingMode.off;
}

/// 生成运行配置时要不要去掉订阅里的组网节点：喵窝开着一律去掉（只能开一个），否则看开关。
bool stripsSubscriptionTailscale(MeowSettings s) => s.mesh.enabled || !s.tailscaleNodes;

/// 切到 [mode] 后的设置（两边的开关一起改，调用方只重载一次）。喵窝真正打开前要先问过主控，见 MeshController。
MeowSettings withNetworkingMode(MeowSettings s, NetworkingMode mode) => switch (mode) {
  NetworkingMode.mesh => s.copyWith(tailscaleNodes: false, mesh: s.mesh.copyWith(enabled: true)),
  NetworkingMode.tailscale => s.copyWith(tailscaleNodes: true, mesh: s.mesh.copyWith(enabled: false)),
  NetworkingMode.off => s.copyWith(tailscaleNodes: false, mesh: s.mesh.copyWith(enabled: false)),
};

/// 设备名规范化（同 MeowX：不加前缀）：小写，字母数字以外的换成横线，去掉首尾与连续的横线，最长 63；什么都不剩时用 [fallback]。
String meshHostname(String raw, {String fallback = 'meowx'}) {
  var s = raw.toLowerCase().replaceAll(RegExp(r'[^a-z0-9-]+'), '-').replaceAll(RegExp(r'-{2,}'), '-');
  s = s.replaceAll(RegExp(r'^-+|-+$'), '');
  if (s.length > 63) s = s.substring(0, 63).replaceAll(RegExp(r'-+$'), '');
  return s.isEmpty ? fallback : s;
}

// ---------------------------------------------------------------------------------------------------------------
// IPv4 网段

/// 点分十进制 IPv4 → 32 位整数；不合法返回 null。
int? parseIpv4(String s) {
  final p = s.trim().split('.');
  if (p.length != 4) return null;
  var v = 0;
  for (final x in p) {
    final n = int.tryParse(x);
    if (n == null || n < 0 || n > 255 || x.isEmpty) return null;
    v = (v << 8) | n;
  }
  return v;
}

String _ipv4String(int v) => '${(v >> 24) & 0xff}.${(v >> 16) & 0xff}.${(v >> 8) & 0xff}.${v & 0xff}';

/// IPv4 网段（主机位清零）。
class Ipv4Cidr {
  const Ipv4Cidr(this.network, this.prefix);

  final int network;
  final int prefix;

  static int _mask(int prefix) => prefix == 0 ? 0 : (0xffffffff << (32 - prefix)) & 0xffffffff;

  /// `a.b.c.d/n` 或单个地址（= /32）；不合法返回 null。
  static Ipv4Cidr? parse(String s) {
    final t = s.trim();
    final slash = t.indexOf('/');
    final ip = parseIpv4(slash == -1 ? t : t.substring(0, slash));
    if (ip == null) return null;
    final prefix = slash == -1 ? 32 : int.tryParse(t.substring(slash + 1));
    if (prefix == null || prefix < 0 || prefix > 32) return null;
    return Ipv4Cidr(ip & _mask(prefix), prefix);
  }

  bool contains(int ip) => (ip & _mask(prefix)) == network;

  /// [other] 整个在这个网段里
  bool covers(Ipv4Cidr other) => other.prefix >= prefix && contains(other.network);

  bool overlaps(Ipv4Cidr other) => covers(other) || other.covers(this);

  @override
  String toString() => '${_ipv4String(network)}/$prefix';

  @override
  bool operator ==(Object other) => other is Ipv4Cidr && other.network == network && other.prefix == prefix;

  @override
  int get hashCode => Object.hash(network, prefix);
}

/// [base] 去掉 [hole] 之后剩下的网段（不重叠时原样返回 [base]，被整个盖住时为空）。
List<Ipv4Cidr> subtractCidr(Ipv4Cidr base, Ipv4Cidr hole) {
  if (!base.overlaps(hole)) return [base];
  if (hole.covers(base)) return const [];
  // hole 在 base 里面：沿着 hole 的位一路二分，每层留下不含 hole 的那一半
  final out = <Ipv4Cidr>[];
  var cur = base;
  while (cur.prefix < hole.prefix) {
    final next = cur.prefix + 1;
    final bit = 1 << (32 - next);
    final low = Ipv4Cidr(cur.network, next);
    final high = Ipv4Cidr(cur.network | bit, next);
    if (low.covers(hole)) {
      out.add(high);
      cur = low;
    } else {
      out.add(low);
      cur = high;
    }
  }
  return out;
}

/// 喵窝这次接入的站点网段：去掉不合法的、和本机当前所在网络重叠的（本地优先，Design/meshnet.md §6.2）。
/// 拿不到本机网段的前缀长度（Dart 的网卡列表不带掩码），按「站点里有本机地址」算重叠。
List<String> meshActiveSites(Iterable<String> routes, Iterable<String> localIPv4s) {
  final locals = localIPv4s.map(parseIpv4).nonNulls.toList();
  final out = <String>[];
  for (final r in routes) {
    final c = Ipv4Cidr.parse(r);
    if (c == null || c.prefix == 0) continue;
    if (locals.any(c.contains)) continue;
    final s = c.toString();
    if (!out.contains(s)) out.add(s);
  }
  return out;
}

/// 喵窝开着时要进隧道的网段：设备地址段 + 这次接入的站点网段；没开（或还没有控制地址）时为空。
List<String> meshTunRoutes(MeowMesh mesh, Iterable<String> localIPv4s) {
  if (!mesh.enabled || mesh.controlUrl.isEmpty) return const [];
  return [meshDeviceCidr, ...meshActiveSites(mesh.routes, localIPv4s).where((s) => s != meshDeviceCidr)];
}

/// 按喵窝的网段调整 TUN 路由，让它们进隧道：
/// - [routeAddress] 不空（Android「绕过私有网络」时只路由公网段）→ 补上喵窝网段（已被盖住的不重复加）；
/// - [routeExclude]（桌面「绕过私有网络」时排除私网段）→ 从排除的 IPv4 网段里挖掉喵窝网段（IPv6 原样）。
({List<String> routeAddress, List<String> routeExclude}) meshAdjustRoutes(
  List<String> routeAddress,
  List<String> routeExclude,
  List<String> meshRoutes,
) {
  final holes = meshRoutes.map(Ipv4Cidr.parse).nonNulls.toList();
  if (holes.isEmpty) return (routeAddress: routeAddress, routeExclude: routeExclude);
  var address = routeAddress;
  if (routeAddress.isNotEmpty) {
    final existing = routeAddress.map(Ipv4Cidr.parse).nonNulls.toList();
    address = [
      ...routeAddress,
      for (final h in holes)
        if (!existing.any((e) => e.covers(h))) h.toString(),
    ];
  }
  final exclude = <String>[];
  for (final e in routeExclude) {
    final c = Ipv4Cidr.parse(e);
    if (c == null) {
      exclude.add(e);
      continue;
    }
    var parts = [c];
    for (final h in holes) {
      parts = [for (final p in parts) ...subtractCidr(p, h)];
    }
    if (parts.length == 1 && parts.first == c) {
      exclude.add(e);
    } else {
      exclude.addAll(parts.map((p) => p.toString()));
    }
  }
  return (routeAddress: address, routeExclude: exclude);
}

// ---------------------------------------------------------------------------------------------------------------
// 运行配置的改写

/// 注入的喵窝节点所需的全部输入。
class MeshInjection {
  const MeshInjection({
    required this.controlUrl,
    required this.hostname,
    this.magicDns = '',
    this.sites = const [],
    this.authKey,
  });

  final String controlUrl;
  final String hostname;
  final String magicDns;

  /// 这次接入的站点网段（已去掉和本机网络重叠的，见 [meshActiveSites]）
  final List<String> sites;

  /// 一次性入网 key：只在这台设备还没登记（或在主控被删了）时带上；登记过的设备靠状态目录里的设备密钥
  final String? authKey;

  /// 喵窝节点（`type: tailscale`）。不进任何分组、不参与测速（只被规则与 DNS 引用）
  Map<String, dynamic> node() => {
    'name': meshOutboundName,
    'type': 'tailscale',
    'control-url': controlUrl,
    'state-dir': meshStateDir,
    'hostname': hostname,
    'accept-routes': true,
    'udp': true,
    if (authKey != null && authKey!.isNotEmpty) 'auth-key': authKey,
  };

  /// 喵窝的规则：设备地址段 → MagicDNS 后缀 → 站点网段。写进内核的 `priority-rules`（先于出站模式匹配，
  /// 规则 / 全局 / 直连三种模式下都交给喵窝，同 iOS）
  List<String> rules() => [
    'IP-CIDR,$meshDeviceCidr,$meshOutboundName,no-resolve',
    if (magicDns.isNotEmpty) 'DOMAIN-SUFFIX,$magicDns,$meshOutboundName',
    for (final s in sites)
      if (s != meshDeviceCidr) 'IP-CIDR,$s,$meshOutboundName,no-resolve',
  ];
}

/// 改写的结果。
class NetworkingPatch {
  const NetworkingPatch({
    required this.rules,
    this.subscriptionTailscaleNodes = const [],
    this.removed = const [],
  });

  /// 改写后的订阅规则（指向去掉的节点的已改成 DIRECT；新列表，不动传进来的那份）
  final List<dynamic> rules;

  /// 订阅里原本有的 Tailscale 组网节点（去掉之前记下的，「组网」页据此判断 Tailscale 那一项可不可选）
  final List<String> subscriptionTailscaleNodes;

  /// 这次从配置里去掉的节点名
  final List<String> removed;
}

bool _isTailscale(Object? proxy) => proxy is Map && proxy['type']?.toString().toLowerCase() == 'tailscale';

/// 配置里 `type: tailscale` 的节点名。
List<String> tailscaleNodeNames(Map<String, dynamic> rawConfig) {
  final proxies = rawConfig['proxies'];
  if (proxies is! List) return const [];
  return [
    for (final p in proxies)
      if (_isTailscale(p) && p['name'] is String) p['name'] as String,
  ];
}

/// 「组网」对运行配置的改写，就地修改 [rawConfig]（改到的集合都换成新的，不碰原来那份：可能是不可改的列表）；
/// [rules] 是订阅规则（写回规则表之前那份），改写后的在返回值里：
/// - [stripTailscale]：去掉订阅里的 Tailscale 组网节点，指向它们的规则改成 DIRECT、代理组里的引用去掉、
///   `ts://<节点>` 的 DNS 策略去掉——配置照样合法（见 [removeProxies]）；
/// - [mesh] 不为 null：注入喵窝节点（订阅里同名的节点先去掉）、喵窝的规则写进内核的 `priority-rules`（先于出站模式、
///   先于全部规则含阻止 QUIC，三种模式下都生效）、MagicDNS 后缀交给喵窝（nameserver-policy，fake-ip 时再加进
///   fake-ip-filter）、TUN 路由放行喵窝网段。
NetworkingPatch applyMeowNetworking(
  Map<String, dynamic> rawConfig,
  List<dynamic> rules, {
  required bool stripTailscale,
  MeshInjection? mesh,
}) {
  final subscriptionNodes = tailscaleNodeNames(rawConfig);
  final remove = <String>{
    if (stripTailscale) ...subscriptionNodes,
    if (mesh != null) ...[
      for (final p in (rawConfig['proxies'] is List ? rawConfig['proxies'] as List : const []))
        if (p is Map && p['name'] == meshOutboundName) meshOutboundName,
    ],
  };
  final newRules = remove.isEmpty ? List<dynamic>.of(rules) : removeProxies(rawConfig, rules, remove);
  if (mesh == null) {
    return NetworkingPatch(rules: newRules, subscriptionTailscaleNodes: subscriptionNodes, removed: remove.toList());
  }

  final proxies = rawConfig['proxies'] is List ? rawConfig['proxies'] as List : <dynamic>[];
  rawConfig['proxies'] = [...proxies, mesh.node()];
  rawConfig['priority-rules'] = mesh.rules();

  if (mesh.magicDns.isNotEmpty) {
    final dns = switch (rawConfig['dns']) {
      Map m => Map<String, dynamic>.from(m),
      _ => <String, dynamic>{},
    };
    final policy = switch (dns['nameserver-policy']) {
      Map m => Map<String, dynamic>.from(m),
      _ => <String, dynamic>{},
    };
    policy['+.${mesh.magicDns}'] = 'ts://$meshOutboundName';
    dns['nameserver-policy'] = policy;
    if (dns['enhanced-mode']?.toString() == 'fake-ip') {
      final filter = dns['fake-ip-filter'] is List ? List<dynamic>.from(dns['fake-ip-filter'] as List) : <dynamic>[];
      final entry = '+.${mesh.magicDns}';
      if (!filter.contains(entry)) filter.add(entry);
      dns['fake-ip-filter'] = filter;
    }
    rawConfig['dns'] = dns;
  }

  final tun = rawConfig['tun'];
  if (tun is Map) {
    final adjusted = meshAdjustRoutes(
      _strings(tun['route-address']),
      _strings(tun['route-exclude-address']),
      [meshDeviceCidr, ...mesh.sites],
    );
    tun['route-address'] = adjusted.routeAddress;
    tun['route-exclude-address'] = adjusted.routeExclude;
  }

  return NetworkingPatch(
    rules: newRules,
    subscriptionTailscaleNodes: subscriptionNodes,
    removed: remove.toList(),
  );
}

List<String> _strings(Object? v) => v is List ? [for (final e in v) e.toString()] : const [];

/// mihomo 的规则里出站在哪一格（同内核 `ParseRulePayload`）：MATCH 是第二格；逻辑规则 / 正则规则的载荷里有逗号，
/// 出站在最后一格；其它是第三格。SUB-RULE 最后一格是子规则名、不是出站，返回 null。
int? _targetIndex(List<String> parts) {
  if (parts.length < 2) return null;
  switch (parts.first.trim().toUpperCase()) {
    case 'MATCH':
      return 1;
    case 'SUB-RULE':
      return null;
    case 'NOT' || 'OR' || 'AND' || 'DOMAIN-REGEX' || 'PROCESS-NAME-REGEX' || 'PROCESS-PATH-REGEX':
      return parts.length - 1;
    default:
      return parts.length > 2 ? 2 : null;
  }
}

/// 规则的出站在 [removed] 里就换成 [replacement]；不涉及时原样返回。
String rewriteRuleTarget(String rule, Set<String> removed, {String replacement = 'DIRECT'}) {
  final parts = rule.split(',');
  final i = _targetIndex(parts);
  if (i == null || !removed.contains(parts[i].trim())) return rule;
  parts[i] = replacement;
  return parts.join(',');
}

/// nameserver 写法是不是指向 [removed] 里的组网节点（`ts://名字` / `tailscale://名字`）。
bool _isRemovedTsNameserver(Object? v, Set<String> removed) {
  final s = v?.toString().trim() ?? '';
  for (final scheme in const ['ts://', 'tailscale://']) {
    if (s.toLowerCase().startsWith(scheme)) return removed.contains(s.substring(scheme.length).trim());
  }
  return false;
}

/// 从配置里去掉 [names] 这些节点，并让配置照样合法（改到的集合都换成新的），返回改写后的 [rules]：
/// - `proxies` 里删掉；别的节点 `dialer-proxy` 指向它们的去掉这一项；
/// - 代理组的 `proxies` 里去掉引用，删空了又没有 `use` / `include-all*` 的组补一个 DIRECT（mihomo 不接受空组）；
/// - [rules] 与 `sub-rules` 里指向它们的规则出站改成 DIRECT；
/// - DNS：`nameserver-policy` 里 `ts://<节点>` 的值去掉（列表删空就整条去掉），nameserver / fallback 等列表里的同样去掉。
List<dynamic> removeProxies(Map<String, dynamic> rawConfig, List<dynamic> rules, Set<String> names) {
  List<dynamic> rewrite(List<dynamic> list) => [for (final r in list) r is String ? rewriteRuleTarget(r, names) : r];
  if (names.isEmpty) return List<dynamic>.of(rules);

  final proxies = rawConfig['proxies'];
  if (proxies is List) {
    rawConfig['proxies'] = [
      for (final p in proxies)
        if (!(p is Map && names.contains(p['name'])))
          p is Map && names.contains(p['dialer-proxy']) ? (Map<String, dynamic>.from(p)..remove('dialer-proxy')) : p,
    ];
  }

  final groups = rawConfig['proxy-groups'];
  if (groups is List) {
    rawConfig['proxy-groups'] = [
      for (final g in groups)
        if (g is! Map || g['proxies'] is! List) g else _withoutMembers(g, names),
    ];
  }

  final subRules = rawConfig['sub-rules'];
  if (subRules is Map) {
    rawConfig['sub-rules'] = {for (final e in subRules.entries) e.key: e.value is List ? rewrite(e.value as List) : e.value};
  }

  final dns = rawConfig['dns'];
  if (dns is Map) {
    final out = Map<String, dynamic>.from(dns);
    final policy = dns['nameserver-policy'];
    if (policy is Map) {
      final kept = <String, dynamic>{};
      for (final e in policy.entries) {
        final v = e.value;
        if (v is List) {
          final left = v.where((x) => !_isRemovedTsNameserver(x, names)).toList();
          if (left.isNotEmpty) kept[e.key.toString()] = left.length == v.length ? v : left;
        } else if (!_isRemovedTsNameserver(v, names)) {
          kept[e.key.toString()] = v;
        }
      }
      out['nameserver-policy'] = kept;
    }
    for (final key in const ['nameserver', 'fallback', 'default-nameserver', 'proxy-server-nameserver', 'direct-nameserver']) {
      final v = dns[key];
      if (v is List) out[key] = v.where((x) => !_isRemovedTsNameserver(x, names)).toList();
    }
    rawConfig['dns'] = out;
  }

  return rewrite(rules);
}

Map<String, dynamic> _withoutMembers(Map<dynamic, dynamic> g, Set<String> names) {
  final members = (g['proxies'] as List).where((m) => !(m is String && names.contains(m))).toList();
  final hasOtherSource = (g['use'] is List && (g['use'] as List).isNotEmpty) ||
      g['include-all'] == true ||
      g['include-all-proxies'] == true ||
      g['include-all-providers'] == true;
  if (members.isEmpty && !hasOtherSource) members.add('DIRECT');
  return Map<String, dynamic>.from(g)..['proxies'] = members;
}

// ---------------------------------------------------------------------------------------------------------------
// tsnet 状态文件

/// 从 tsnet 的状态文件（`<state-dir>/tailscaled.state`，JSON：键 → base64 的值）里取当前登录档在控制服务器上的设备编号：
/// `_current-profile` 是当前档的状态键（`profile-xxxx`），`_profiles` 按档 ID 列出各档（每档带自己的 `Key`），
/// 那一档的 `NodeID` 是 Headscale 的 StableID（就是数字编号）。没登记过 / 文件坏了 → null。
int? meshNodeIdFromState(String content) {
  try {
    final root = json.decode(content);
    if (root is! Map) return null;
    String? decode(Object? v) => v is String ? utf8.decode(base64.decode(v)) : null;
    final current = decode(root['_current-profile'])?.trim();
    final profiles = json.decode(decode(root['_profiles']) ?? 'null');
    if (current == null || current.isEmpty || profiles is! Map) return null;
    for (final e in profiles.entries) {
      final p = e.value;
      if (p is! Map) continue;
      final id = (p['ID'] ?? e.key).toString();
      if (p['Key'] != current && id != current && 'profile-$id' != current) continue;
      return int.tryParse(p['NodeID']?.toString() ?? '');
    }
    return null;
  } catch (_) {
    return null;
  }
}

// ---------------------------------------------------------------------------------------------------------------
// 系统代理排除清单

final _octetPattern = RegExp(r'^(\d{1,3}(?:\.\d{1,3}){0,2})(?:\.\*)+$');

/// 系统代理的排除清单里，盖住喵窝网段（[meshRoutes]：设备地址段与这次接入的站点网段）的「按段通配」条目（`192.168.*`、
/// `10.*`、`172.16.*` 这类）收窄成不含这些网段的若干条，让站点网段经系统代理进内核、交给喵窝；别的条目原样。
/// 只在设置系统代理那一刻算（不改用户存着的清单，喵窝关掉自然恢复）。用户自己的局域网和站点重叠时那个站点本来就不接入
/// （[meshActiveSites]），这里不会把用户的局域网推进代理。
///
/// 通配只能写前缀，收窄靠十进制前缀：`192.168.*` 去掉 192.168.1.0/24 →
/// `192.168.0.*`、`192.168.10*`…`192.168.19*`（第三段 10–19、100–199）、`192.168.2*`…`192.168.9*`，共 19 条。
/// Windows（ProxyOverride）与安卓（VpnService 的代理排除）都认这种尾部通配。
List<String> meshNarrowBypass(List<String> bypass, List<String> meshRoutes) {
  final holes = meshRoutes.map(Ipv4Cidr.parse).nonNulls.toList();
  if (holes.isEmpty) return bypass;
  final out = <String>[];
  for (final entry in bypass) {
    final m = _octetPattern.firstMatch(entry.trim());
    final octets = m?.group(1)!.split('.').map(int.parse).toList();
    if (octets == null || octets.any((o) => o > 255)) {
      out.add(entry);
      continue;
    }
    var network = 0;
    for (var i = 0; i < 4; i++) {
      network = (network << 8) | (i < octets.length ? octets[i] : 0);
    }
    final range = Ipv4Cidr(network, octets.length * 8);
    final inside = holes.where(range.overlaps).toList();
    if (inside.isEmpty) {
      out.add(entry);
      continue;
    }
    if (inside.any((h) => h.covers(range))) continue; // 整段都是喵窝的：去掉
    out.addAll(_globsExcept(octets, inside));
  }
  return out;
}

/// [prefix]（前 k 段）下、去掉 [holes] 之后剩下的地址，写成尾部通配。
List<String> _globsExcept(List<int> prefix, List<Ipv4Cidr> holes) {
  final k = prefix.length; // 下一段是第 k 段（从 0 数）
  final head = prefix.join('.');
  // 第 k 段的每个取值：完全被洞盖住 / 部分被盖（要往下一段细分）/ 不碰
  final covered = <int>{};
  final partial = <int, List<Ipv4Cidr>>{};
  for (var v = 0; v < 256; v++) {
    var network = 0;
    final octets = [...prefix, v];
    for (var i = 0; i < 4; i++) {
      network = (network << 8) | (i < octets.length ? octets[i] : 0);
    }
    final sub = Ipv4Cidr(network, (k + 1) * 8);
    final hit = holes.where(sub.overlaps).toList();
    if (hit.isEmpty) continue;
    if (hit.any((h) => h.covers(sub))) {
      covered.add(v);
    } else {
      partial[v] = hit;
    }
  }
  final allowed = {for (var v = 0; v < 256; v++) v}..removeAll(covered)..removeAll(partial.keys);
  final out = [for (final g in _decimalGlobs(allowed)) '$head.$g'];
  // 部分被盖的取值往下一段细分（第 4 段没有下一段：只剩单个地址，写成确切地址）
  for (final e in partial.entries) {
    if (k + 1 < 4) {
      out.addAll(_globsExcept([...prefix, e.key], e.value));
    }
  }
  return out;
}

/// 0–255 里 [allowed] 这些取值写成十进制前缀通配：`2*` 同时盖住 2、20–29、200–255；某个前缀下有不允许的取值时，
/// 取值本身允许就写确切的 `v.*`，再往下一位细分。
List<String> _decimalGlobs(Set<int> allowed) {
  final out = <String>[];
  List<int> withPrefix(String s) => [
    for (var v = 0; v < 256; v++)
      if (v.toString().startsWith(s)) v,
  ];
  void walk(String s) {
    final values = withPrefix(s);
    if (values.isEmpty) return;
    if (values.every(allowed.contains)) {
      out.add(values.length == 1 ? '$s.*' : '$s*');
      return;
    }
    final self = int.parse(s);
    if (self < 256 && allowed.contains(self)) out.add('$s.*');
    if (s == '0') return; // 没有前导 0
    for (var d = 0; d < 10; d++) {
      walk('$s$d');
    }
  }

  for (final s in ['0', '1', '2', '3', '4', '5', '6', '7', '8', '9']) {
    walk(s);
  }
  return out;
}
