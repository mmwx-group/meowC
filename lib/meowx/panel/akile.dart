import 'dart:convert';

import 'package:bett_box/models/meow.dart';

import 'node_match.dart';

// ---- AkileCDN 白名单（五端同一份规格：MeowX 仓库 Design/akile-whitelist.md） ----
//
// AkileCDN 的转发规则可以开「入口白名单」，只放一个 IPv4。客户端用 Akile 开放接口把本机**直连**出口 IPv4 写进所选规则
// 的入口白名单。查出口 IP、查规则、PUT 都由 Go 核心直连发（core/meow_akile.go）；这里是 Key 的解析 / 脱敏、节点列表、
// 核心回包的解析、界面与日志的文字。

/// 标题（设置开关、子页说明都用它）
const akileTitle = 'AkileCDN 白名单';

/// 节点子页的标题
const akileNodesTitle = 'AkileCDN 节点';

/// 说明（ⓘ 与子页底部，五端同一句）
const akileDescription =
    '把本机直连出口 IPv4 写进所选 AkileCDN 规则的入口白名单。网络变化、回到前台时立刻更新，每 10 分钟检查一次出口 IP、变了才更新。一条规则只能放一个 IP，多台设备都开会互相覆盖。';

/// 开关关着时子页底部的提示
const akileDisabledHint = '「AkileCDN 白名单」开关关着，添加的节点暂不更新。';

/// Key 输入框的提示
const akileKeyHint = '在 AkileCDN 后台「开放接口」里创建 API Key（ak_ 开头）。Key 等同账号权限，只保存在本机。';

const akileKeyInvalidMessage = 'API Key 应以 ak_ 开头';
const akileNodesFullMessage = '最多 $akileMaxNodes 个节点';
const akileAddButton = '从订阅添加节点';
const akilePickRuleTitle = '选择要加白的规则';
const akileNeedKeyMessage = '先填写 API Key';
const akileNoCandidatesMessage = '当前订阅里没有可选的节点';
const akileDuplicateMessage = '这条规则已经添加过';
const akileNeverReported = '还没更新过';

/// 查规则一条都没有时的提示
String akileNoRulesMessage(int port) => '没有监听端口 $port 的规则：确认这个节点是 AkileCDN 的转发、API Key 属于这条规则的账号';

/// 节点个数上限
const akileMaxNodes = 20;

/// 合法的 API Key：`ak_` + 8–200 个 `A–Z a–z 0–9 _ -`
final akileKeyPattern = RegExp(r'^ak_[A-Za-z0-9_-]{8,200}$');

final _headerPrefix = RegExp(r'^x-api-key\s*:\s*', caseSensitive: false);
final _bearerPrefix = RegExp(r'^bearer\s+', caseSensitive: false);

/// 解析用户输入的 Key：去掉首尾空白、开头的 `X-API-Key:` / `Bearer `（不分大小写）后校验。
/// 返回 `(key, null)` 或 `(null, 出错提示)`。
(String?, String?) parseAkileKey(String input) {
  var s = input.trim().replaceFirst(_headerPrefix, '').trim().replaceFirst(_bearerPrefix, '').trim();
  return akileKeyPattern.hasMatch(s) ? (s, null) : (null, akileKeyInvalidMessage);
}

/// 存着的 Key 合不合法（不合法当作没有 Key：不上报、不能添加节点）
bool isValidAkileKey(String key) => akileKeyPattern.hasMatch(key);

/// 脱敏写法：`ak_••••<后 4 位>`。
String maskAkileKey(String key) {
  final k = key.trim();
  final tail = k.length > 4 ? k.substring(k.length - 4) : k;
  return 'ak_••••$tail';
}

final _keyLike = RegExp(r'ak_[A-Za-z0-9_-]{8,200}');

/// 把文字里的 Key（原样出现的，以及任何像 Key 的串）换成脱敏写法。写日志 / 界面前都过一遍。
String redactAkile(String text, [String key = '']) {
  var out = key.isEmpty ? text : text.replaceAll(key, maskAkileKey(key));
  return out.replaceAllMapped(_keyLike, (m) => maskAkileKey(m[0]!));
}

/// 加一个节点：按规则去重 + 上限。返回 null = 可以加，否则是出错提示。
String? checkNewAkileNode(List<MeowAkileNode> existing, int ruleId) {
  if (existing.any((n) => n.ruleId == ruleId)) return akileDuplicateMessage;
  if (existing.length >= akileMaxNodes) return akileNodesFullMessage;
  return null;
}

/// 要上报的节点：存进来时已校验，这里兜底——规则 ID 不合法的跳过、按规则去重、最多 [akileMaxNodes] 个，保持顺序。
List<MeowAkileNode> akileReportNodes(List<MeowAkileNode> nodes) {
  final seen = <int>{};
  final out = <MeowAkileNode>[];
  for (final n in nodes) {
    if (n.ruleId <= 0 || !seen.add(n.ruleId)) continue;
    out.add(n);
    if (out.length >= akileMaxNodes) break;
  }
  return out;
}

/// 节点行的第二行：`规则 #<id>[ · <label>] · 端口 <port>`
String akileNodeDetail(MeowAkileNode n) =>
    ['规则 #${n.ruleId}', if (n.label.isNotEmpty) n.label, '端口 ${n.port}'].join(' · ');

/// 订阅里可以拿来加白的节点（选节点那一步列的）。
class AkileCandidate {
  const AkileCandidate({required this.name, required this.type, required this.server, required this.port});

  final String name;
  final String type;
  final String server;
  final int port;

  /// `server:port`（IPv6 加方括号）
  String get address => server.contains(':') ? '[$server]:$port' : '$server:$port';

  @override
  bool operator ==(Object other) =>
      other is AkileCandidate &&
      other.name == name &&
      other.type == type &&
      other.server == server &&
      other.port == port;

  @override
  int get hashCode => Object.hash(name, type, server, port);

  @override
  String toString() => '$name ($type $address)';
}

/// 当前订阅里可选的节点：只取订阅 `proxies` 里有 type / server / port 的（代理组、DIRECT / REJECT 不在里面，
/// `type: tailscale` 这类没有 server / port 的认不出键、也不列），保持订阅里的顺序。
/// [keys] 是应用配置时记下的「节点名 → type / server / port」（见 node_match.dart 的 [captureNodeKeys]）。
List<AkileCandidate> akileCandidates(Map<String, NodeMatchKey?> keys) => [
  for (final e in keys.entries)
    if (e.value case final k? when k.type != 'direct' && k.type != 'reject')
      AkileCandidate(name: e.key, type: k.type, server: k.server, port: k.port),
];

/// 搜索：节点名或 server:port 里含有关键字（不分大小写）。
List<AkileCandidate> filterAkileCandidates(List<AkileCandidate> all, String query) {
  final q = query.trim().toLowerCase();
  if (q.isEmpty) return all;
  return [
    for (final c in all)
      if (c.name.toLowerCase().contains(q) || c.address.toLowerCase().contains(q)) c,
  ];
}

// ---- 核心回包 ----

/// 查规则得到的一条（核心按规格 §1.1 宽松解析过，再按端口过滤过）。
class AkileRule {
  const AkileRule({required this.id, this.entryWhitelist = '', this.summary = '', this.nodeId = ''});

  final int id;
  final String entryWhitelist;

  /// 说明文字（name / remark / note / description / node_name / target 里第一个非空的），加入后存成节点的 label
  final String summary;
  final String nodeId;

  /// 选规则时的一行：`规则 #<id> · <说明> · 节点 <node_id> · 当前白名单 <entry_whitelist 或「未设置」>`
  String get line => [
    '规则 #$id',
    if (summary.isNotEmpty) summary,
    if (nodeId.isNotEmpty) '节点 $nodeId',
    '当前白名单 ${entryWhitelist.isEmpty ? '未设置' : entryWhitelist}',
  ].join(' · ');

  @override
  bool operator ==(Object other) =>
      other is AkileRule &&
      other.id == id &&
      other.entryWhitelist == entryWhitelist &&
      other.summary == summary &&
      other.nodeId == nodeId;

  @override
  int get hashCode => Object.hash(id, entryWhitelist, summary, nodeId);
}

/// 查规则的结果：[error] 不为 null 时是界面上的出错文字（已脱敏）。
class AkileRulesLookup {
  const AkileRulesLookup({this.rules = const [], this.error});

  final List<AkileRule> rules;
  final String? error;
}

Object? _decode(String raw) {
  try {
    return raw.isEmpty ? null : json.decode(raw);
  } on FormatException {
    return null;
  }
}

int? _int(Object? v) => switch (v) {
  int i => i,
  num n when n == n.roundToDouble() => n.toInt(),
  String s => int.tryParse(s.trim()),
  _ => null,
};

String _str(Object? v) => v == null ? '' : v.toString().trim();

/// 解析核心 `meowAkile`（op=rules）的回包：`{rules:[{id, entry_whitelist, summary, node_id, listen_port}], kind?, error?}`。
AkileRulesLookup parseAkileRules(String raw, {String key = ''}) {
  final decoded = _decode(raw);
  if (decoded is! Map) return const AkileRulesLookup(error: '核心无响应');
  final error = _str(decoded['error']);
  if (error.isNotEmpty) return AkileRulesLookup(error: redactAkile(error, key));
  final list = decoded['rules'];
  return AkileRulesLookup(
    rules: [
      if (list is List)
        for (final r in list)
          if (r is Map && _int(r['id']) != null)
            AkileRule(
              id: _int(r['id'])!,
              entryWhitelist: _str(r['entry_whitelist']),
              summary: redactAkile(_str(r['summary']), key),
              nodeId: _str(r['node_id']),
            ),
    ],
  );
}

enum AkileResultKind {
  /// 写进去了（changed = true）
  updated,

  /// 本来就是这个 IP（changed = false）
  unchanged,
  invalidKey,
  notFound,
  rateLimited,
  failed;

  static AkileResultKind of(String s) => switch (s) {
    'updated' => updated,
    'unchanged' => unchanged,
    'invalid_key' => invalidKey,
    'not_found' => notFound,
    'rate_limited' => rateLimited,
    _ => failed,
  };
}

/// 一个节点最近一次上报的结论（只在内存里：界面的「上一次结果」、定时轮判断 IP 变没变）。
class AkileResult {
  const AkileResult({required this.kind, this.ip = '', this.previous = '', this.error = '', required this.at});

  final AkileResultKind kind;

  /// 写进去的 IP（成功时）
  final String ip;

  /// 写之前的白名单（成功时，可能为空）
  final String previous;

  /// 失败原因（界面文字，已脱敏）
  final String error;
  final DateTime at;

  bool get ok => kind == AkileResultKind.updated || kind == AkileResultKind.unchanged;

  /// 「上一次成功写入的 IP」：失败时为 null（下一轮定时一定 PUT）
  String? get okIp => ok && ip.isNotEmpty ? ip : null;

  /// 列表行里的文字：`已更新为 <IP> · 时:分` / `已是 <IP> · 时:分` / `<原因> · 时:分`。
  String get summary {
    String two(int n) => n.toString().padLeft(2, '0');
    final time = '${two(at.hour)}:${two(at.minute)}';
    return switch (kind) {
      AkileResultKind.updated => '已更新为 $ip · $time',
      AkileResultKind.unchanged => '已是 $ip · $time',
      _ => '$error · $time',
    };
  }

  /// 日志一行：`AkileCDN 白名单 <节点名>（规则 #<id>）：已更新 198.51.100.1 → 203.0.113.10` / `：已是 203.0.113.10` /
  /// `：失败（<原因>）`。
  String logLine(String name, int ruleId, {String key = ''}) {
    final head = '$akileTitle $name（规则 #$ruleId）';
    final tail = switch (kind) {
      AkileResultKind.updated => previous.isEmpty ? '已更新为 $ip' : '已更新 $previous → $ip',
      AkileResultKind.unchanged => '已是 $ip',
      _ => '失败（$error）',
    };
    return redactAkile('$head：$tail', key);
  }

  @override
  bool operator ==(Object other) =>
      other is AkileResult &&
      other.kind == kind &&
      other.ip == ip &&
      other.previous == previous &&
      other.error == error &&
      other.at == at;

  @override
  int get hashCode => Object.hash(kind, ip, previous, error, at);
}

/// 一轮上报的结果（核心 `meowAkile` op=report 的回包解析后）。
class AkileReport {
  const AkileReport({
    this.ip = '',
    this.ipError = '',
    this.results = const {},
    this.skipped = const {},
    this.error = '',
  });

  /// 本次查到的出口 IP（查不到为空）
  final String ip;

  /// 查不到出口 IP 的原因（只进日志）
  final String ipError;

  /// 规则 ID → 结论（定时轮里跳过的不在里面）
  final Map<int, AkileResult> results;

  /// 定时轮里因为 IP 没变跳过的规则 ID（结果保持不变、不刷新时间）
  final Set<int> skipped;

  /// 整轮没能开始（参数 / Key 不合法、核心无响应）
  final String error;
}

/// 解析核心的回包：`{ip, ip_error, results:[{rule_id, ok, kind, ip, previous, error}], error}`。
/// [nodes] 里有、回包里没有的节点记「核心无响应」。
AkileReport parseAkileReport(String raw, List<MeowAkileNode> nodes, {String key = '', DateTime? at}) {
  final when = at ?? DateTime.now();
  AkileResult failed(String reason) => AkileResult(kind: AkileResultKind.failed, error: reason, at: when);
  final decoded = _decode(raw);
  if (decoded is! Map) {
    return AkileReport(error: '核心无响应', results: {for (final n in nodes) n.ruleId: failed('核心无响应')});
  }
  final error = redactAkile(_str(decoded['error']), key);
  if (error.isNotEmpty) {
    return AkileReport(error: error, results: {for (final n in nodes) n.ruleId: failed(error)});
  }
  final byId = <int, Map>{};
  final list = decoded['results'];
  if (list is List) {
    for (final r in list) {
      if (r is! Map) continue;
      final id = _int(r['rule_id']);
      if (id != null) byId[id] = r;
    }
  }
  final results = <int, AkileResult>{};
  final skipped = <int>{};
  for (final n in nodes) {
    final r = byId[n.ruleId];
    if (r == null) {
      results[n.ruleId] = failed('核心无响应');
      continue;
    }
    final kindText = _str(r['kind']);
    if (kindText == 'skipped') {
      skipped.add(n.ruleId);
      continue;
    }
    final kind = AkileResultKind.of(kindText);
    results[n.ruleId] = AkileResult(
      kind: kind,
      ip: _str(r['ip']),
      previous: _str(r['previous']),
      error: kind == AkileResultKind.updated || kind == AkileResultKind.unchanged
          ? ''
          : redactAkile(_str(r['error']).isEmpty ? '失败' : _str(r['error']), key),
      at: when,
    );
  }
  return AkileReport(
    ip: _str(decoded['ip']),
    ipError: redactAkile(_str(decoded['ip_error']), key),
    results: results,
    skipped: skipped,
  );
}
