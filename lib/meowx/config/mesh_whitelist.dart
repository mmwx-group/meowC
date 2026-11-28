// 喵窝白名单直连（规格 MeowX 仓库 Design/meshnet-whitelist-direct.md §B，主控设计稿 §5.5 / §7.2）：
// 主控给喵窝名单里的账号下发「喵窝版」白名单节点（私有字段 `_mmwx-mesh: true`，server 是 100.64.x.y），
// 客户端在喵窝开着时让它们经「喵窝」出站拨号（`dialer-proxy: 喵窝`），不占服务器的 IP 白名单名额。
// 全是纯函数，可单测；状态与 I/O 在 lib/meowx/state/mesh_whitelist.dart。
import 'package:bett_box/models/meow.dart';

import 'mesh_config.dart';
import 'subscription_meta.dart';

/// 订阅里标记喵窝版节点的私有字段（主控只发给 MeowX）
const meshWhitelistField = '_mmwx-mesh';

/// 拉本主控订阅时告诉主控要不要喵窝版节点的请求头
const meshSubscriptionHeader = 'X-MeowX-Mesh';

/// 账号在喵窝名单里：主控说过可用，或者给的原因不是 not_admin（disabled / starting 也算在名单里）。
/// [panelReason] 是上次问主控的回答（null = 没问过 / 已退出登录；'' = 可用）。
bool meshListedAccount(String? panelReason) => panelReason != null && panelReason != 'not_admin';

/// B2 的 on：登录着、账号在喵窝名单里、本机喵窝开着、「白名单节点经喵窝连线」开着。
bool meshWhitelistOn(MeowSettings s) =>
    s.account.token.isNotEmpty && meshListedAccount(s.mesh.panelReason) && s.mesh.enabled && s.mesh.whitelistViaMesh;

/// 这份订阅是不是登录的主控的（只给它带 [meshSubscriptionHeader]，别家机场的订阅不带）：
/// - 订阅地址的主机就是主控的主机（同「退出登录删掉本主控的订阅档」的认法）；
/// - 或者上次拉这份订阅时主控给的实时通道地址（`mmwx-realtime-url`，主控对官方客户端才给）就是登录的主控——
///   主控开了「订阅域名」时订阅挂在别的域名上，靠它认得出；
/// - 没有那个应答头时（老主控、第一次拉），路径是主控订阅地址的样子（`/x/…`、`/api/clash/subscribe`、
///   `/api/user/package-subscribe`、`/api/subscribe`，同 iOS / macOS 认订阅域名的口径）也算。
///   应答头指向别的主控时不算（那是另一台妙妙屋X 主控的订阅）。
/// [panelBase] 是登录的主控地址（没登录为空 → 一律不算）。
bool isOwnPanelSubscription(String url, String panelBase, {String? realtimeBase}) {
  final base = normalizePanelBase(panelBase);
  final uri = Uri.tryParse(url.trim());
  if (base == null || uri == null || uri.host.isEmpty) return false;
  final panelHost = Uri.parse(base).host.toLowerCase().replaceAll('[', '').replaceAll(']', '');
  if (uri.host.toLowerCase() == panelHost) return true;
  if (realtimeBase != null) return realtimeBase == base;
  return isPanelSubscriptionPath(uri.path);
}

/// 主控订阅地址的路径样子（主控的「订阅域名」只放行这几种）。
bool isPanelSubscriptionPath(String path) {
  var p = path.startsWith('/') ? path : '/$path';
  while (p.length > 1 && p.endsWith('/')) {
    p = p.substring(0, p.length - 1);
  }
  return p.startsWith('/x/') || const {'/api/clash/subscribe', '/api/user/package-subscribe', '/api/subscribe'}.contains(p);
}

/// 拉订阅的请求头：本主控的订阅加上 `X-MeowX-Mesh: on|off`（[own] = [isOwnPanelSubscription]），其余原样。
/// 不改传进来的那份；什么都不加时原样返回（可能是 null）。
Map<String, String>? withMeshSubscriptionHeader(Map<String, String>? headers, {required bool own, required bool on}) {
  if (!own) return headers;
  return {...?headers, meshSubscriptionHeader: on ? 'on' : 'off'};
}

/// 节点带着 `_mmwx-mesh: true`（也认字符串 "true"）。
bool isMeshWhitelistNode(Object? proxy) {
  if (proxy is! Map) return false;
  final v = proxy[meshWhitelistField];
  return v == true || (v is String && v.trim().toLowerCase() == 'true');
}

/// 规则的出站（目标）；认不出（格式不对、SUB-RULE 的最后一格是子规则名）返回 null。同内核 `ParseRulePayload`：
/// MATCH 是第二格；逻辑规则（AND / OR / NOT）与正则规则的载荷里有逗号，目标在最后一格（后面跟着 no-resolve / src
/// 这类参数时往前一格）；其它是第三格。
String? ruleTarget(String rule) {
  final parts = rule.split(',');
  if (parts.length < 2) return null;
  final type = parts.first.trim().toUpperCase();
  switch (type) {
    case 'MATCH':
      return parts[1].trim();
    case 'SUB-RULE':
      return null;
    case 'AND' || 'OR' || 'NOT' || 'DOMAIN-REGEX' || 'PROCESS-NAME-REGEX' || 'PROCESS-PATH-REGEX':
      var i = parts.length - 1;
      while (i > 1 && _ruleParams.contains(parts[i].trim().toLowerCase())) {
        i--;
      }
      return parts[i].trim();
    default:
      return parts.length > 2 ? parts[2].trim() : null;
  }
}

const _ruleParams = {'no-resolve', 'src'};

/// 删掉目标在 [names] 里的规则（新列表，不动传进来的那份）；不是字符串的条目原样留着。
List<dynamic> dropRulesTargeting(List<dynamic> rules, Set<String> names) => [
  for (final r in rules)
    if (r is! String || !names.contains(ruleTarget(r))) r,
];

/// [applyMeshWhitelist] 的结果。
class MeshWhitelistPatch {
  const MeshWhitelistPatch({required this.rules, this.viaMesh = const [], this.viaMeshServers = const {}, this.removed = const []});

  /// 改写后的订阅规则（off 时目标是拿掉的节点的已删掉；新列表）
  final List<dynamic> rules;

  /// 经喵窝拨号的节点名（on 时；界面据此给节点画「喵窝」小标）
  final List<String> viaMesh;

  /// 经喵窝拨号的节点名 → 它的 server（喵窝地址 100.64.x.y；小标的气泡据此在内核状态里找这台服务器）
  final Map<String, String> viaMeshServers;

  /// 这次拿掉的节点名（off 时）
  final List<String> removed;
}

/// 运行配置里处理喵窝版节点，就地修改 [rawConfig]（改到的集合都换成新的）：
/// - [on]（喵窝开着且这份配置里有「喵窝」出站）：给这些节点加 `dialer-proxy: 喵窝`，节点自己写了 dialer-proxy 的不覆盖；
/// - 否则：从配置里拿掉它们，代理组里的引用去掉（删空了补 DIRECT，见 [removeProxies]）；rules / sub-rules 里目标是它们的
///   规则（含 AND / OR / NOT）整行删掉、不改成 DIRECT（[dropRulesTargeting]），
///   别留一个一定连不上的节点（主控 off 时本来不发，这是兜底：订阅是 on 时拉的、之后关了喵窝还没重拉成功）；
/// - 两种情况都去掉 `_mmwx-mesh` 字段本身（存着的订阅原文不动）。
/// 不能让主控直接下发 dialer-proxy：喵窝没开时引用一个不存在的出站，内核会拒载整份配置。
MeshWhitelistPatch applyMeshWhitelist(Map<String, dynamic> rawConfig, List<dynamic> rules, {required bool on}) {
  final proxies = rawConfig['proxies'];
  if (proxies is! List || !proxies.any(isMeshWhitelistNode)) {
    return MeshWhitelistPatch(rules: List<dynamic>.of(rules));
  }
  final names = <String>[
    for (final p in proxies)
      if (isMeshWhitelistNode(p) && p['name'] is String) p['name'] as String,
  ];
  if (!on) {
    final removed = names.toSet();
    // 先删掉目标是这些节点的规则（rules 与 sub-rules，含逻辑规则）：留着内核会拒载整份配置；删而不改成 DIRECT，
    // 让流量落到后面的规则。剩下的引用（分组成员、别的节点的 dialer-proxy）交给 removeProxies
    final kept = dropRulesTargeting(rules, removed);
    final subRules = rawConfig['sub-rules'];
    if (subRules is Map) {
      rawConfig['sub-rules'] = {
        for (final e in subRules.entries) e.key: e.value is List ? dropRulesTargeting(e.value as List, removed) : e.value,
      };
    }
    final newRules = removeProxies(rawConfig, kept, removed);
    // 名字不是字符串的那种（坏条目）也一并拿掉
    final left = rawConfig['proxies'];
    if (left is List && left.any(isMeshWhitelistNode)) {
      rawConfig['proxies'] = [for (final p in left) if (!isMeshWhitelistNode(p)) p];
    }
    return MeshWhitelistPatch(rules: newRules, removed: names);
  }
  rawConfig['proxies'] = [
    for (final p in proxies)
      if (isMeshWhitelistNode(p))
        _viaMesh(p as Map)
      else
        p,
  ];
  return MeshWhitelistPatch(
    rules: List<dynamic>.of(rules),
    viaMesh: names,
    viaMeshServers: {
      for (final p in proxies)
        if (isMeshWhitelistNode(p) && p['name'] is String && p['server'] != null) p['name'] as String: p['server'].toString().trim(),
    },
  );
}

Map<String, dynamic> _viaMesh(Map<dynamic, dynamic> p) {
  final out = Map<String, dynamic>.from(p)..remove(meshWhitelistField);
  final dialer = out['dialer-proxy']?.toString().trim() ?? '';
  if (dialer.isEmpty) out['dialer-proxy'] = meshOutboundName;
  return out;
}
