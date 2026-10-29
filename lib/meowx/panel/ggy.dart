import 'dart:convert';

// ---- GGY（咕咕云）客户端 IP 加白（五端同一套规则：iOS / macOS / meowC / OpenWrt） ----
//
// GGY 腾讯云 ECS 防火墙插件的白名单分享链接：谁打开就把谁的公网 IP 加进那台服务器的防火墙白名单。
// 客户端用直连出口定期 GET 一次；token 只有用户自己填的，没有主控下发，也不加分流规则（与 po0 不同）。

/// 设置里「GGY 加白」开关的说明（三端同一句）
const ggyDescription = '把本机出口 IP 上报到 GGY（咕咕云）服务器的防火墙白名单：填分享链接里的 token（也可以直接粘贴整条链接），每 10 分钟及网络变化时自动加白；上报走直连。';

const ggyTokenEmptyMessage = '请填写 token';
const ggyTokenInvalidMessage = 'token 格式不对';
const ggyTokenDuplicateMessage = '这个 token 已经添加过';
const ggyTokensFullMessage = '最多添加 $ggyMaxTokens 个 token';

/// token 个数上限
const ggyMaxTokens = 20;

/// 去掉首尾空白后：只含 `A–Z a–z 0–9 _ -`，长度 8–200。不强制前缀（实际样例以 `ctecsfw_` 开头）。
final ggyTokenPattern = RegExp(r'^[A-Za-z0-9_-]{8,200}$');

final _tokenParam = RegExp(r'(?:^|[?&])token=([^&#\s]*)');

/// 从输入里取 token：裸 token，或者整条分享链接（含 `token=` 的都按链接处理，取查询串里 `token` 的值）。
/// 返回 `(token, null)` 或 `(null, 出错提示)`。
(String?, String?) parseGgyToken(String input) {
  var s = input.trim();
  if (s.isEmpty) return (null, ggyTokenEmptyMessage);
  if (s.contains('token=')) {
    // 合法 token 只含 URL 安全字符，链接里不会被编码：取出来原样校验（带 % 的自然不合法）
    final m = _tokenParam.firstMatch(s);
    if (m == null) return (null, ggyTokenInvalidMessage);
    s = m[1]!;
  }
  return ggyTokenPattern.hasMatch(s) ? (s, null) : (null, ggyTokenInvalidMessage);
}

/// 规范化 token；不合法返回 null。
String? normalizeGgyToken(String input) => parseGgyToken(input).$1;

/// 添加一个 token：解析 + 去重（按规范化后的字符串）+ 上限。返回 `(token, null)` 或 `(null, 出错提示)`。
(String?, String?) checkNewGgyToken(List<String> existing, String input) {
  final (token, err) = parseGgyToken(input);
  if (err != null) return (null, err);
  if (existing.any((t) => normalizeGgyToken(t) == token)) return (null, ggyTokenDuplicateMessage);
  if (existing.length >= ggyMaxTokens) return (null, ggyTokensFullMessage);
  return (token, null);
}

/// 要上报的 token：存进来时已校验，这里兜底——不合法的跳过、去重、最多 [ggyMaxTokens] 个，保持顺序。
List<String> ggyReportTokens(List<String> tokens) {
  final out = <String>[];
  for (final t in tokens) {
    final n = normalizeGgyToken(t);
    if (n != null && !out.contains(n)) out.add(n);
    if (out.length >= ggyMaxTokens) break;
  }
  return out;
}

/// token 的脱敏写法：含 `_` 时 `<第一个 _ 及之前>••••<后 4 位>`（如 `ctecsfw_••••AAAA`），否则 `••••<后 4 位>`。
String maskGgyToken(String token) {
  final t = token.trim();
  final tail = t.length > 4 ? t.substring(t.length - 4) : t;
  final underscore = t.indexOf('_');
  return underscore < 0 ? '••••$tail' : '${t.substring(0, underscore + 1)}••••$tail';
}

/// 上报地址（token 只含安全字符，不必再编码）。
String ggyReportUrl(String token) => 'https://www.guguyun.com/cany_tencentecs/firewall/whitelist?token=$token';

final _urlToken = RegExp(r'token=([A-Za-z0-9_-]+)');

/// 把一段文字（上报地址、核心回的错误——Go 的 url.Error 带整个 url、GGY 的应答）里的 token 换成脱敏写法：
/// 先换 `token=<…>`，再换 [tokens] 里原样出现的。写日志 / 界面前都过一遍。
String redactGgy(String text, [Iterable<String> tokens = const []]) {
  var out = text.replaceAllMapped(_urlToken, (m) => 'token=${maskGgyToken(m[1]!)}');
  for (final t in tokens) {
    if (t.isNotEmpty) out = out.replaceAll(t, maskGgyToken(t));
  }
  return out;
}

enum GgyResultKind {
  ok,

  /// HTTP 200 + `status` 400 + msg 含「无效」或「失效」：分享链接无效或已失效，要到 GGY 重新生成
  tokenInvalid,
  failed,
}

/// 一次上报的结论（界面显示「上一次结果」、写日志）。
class GgyResult {
  const GgyResult({required this.kind, this.reason = '', this.note = '', required this.at});

  final GgyResultKind kind;

  /// 失败原因（成功时是 GGY 应答里的 msg，可能为空）
  final String reason;

  /// 应答没有 status 字段 / 解析不出时记下的应答开头 160 字节（以后好对照），只进日志
  final String note;
  final DateTime at;

  bool get ok => kind == GgyResultKind.ok;

  /// 判断核心回来的一条结果：[status] 是 HTTP 状态码（连不上时为 0、[error] 是原因），[body] 是应答原文。
  /// HTTP 200 且 body 是 JSON 对象时看里面的 `status`：200（数字或字符串）成功；别的值失败、原因用 msg（为空用
  /// `status <值>`），400 且 msg 含「无效」/「失效」归为 token 无效；没有 `status` 字段当作成功、记下应答开头。
  /// 不是 JSON 对象的算失败（应答无法解析）。
  static GgyResult judge({required int status, String body = '', String error = '', DateTime? at}) {
    final when = at ?? DateTime.now();
    if (error.isNotEmpty) return GgyResult(kind: GgyResultKind.failed, reason: error, at: when);
    if (status != 200) return GgyResult(kind: GgyResultKind.failed, reason: 'HTTP $status', at: when);
    Object? decoded;
    try {
      decoded = json.decode(body);
    } on FormatException {
      decoded = null;
    }
    if (decoded is! Map) {
      return GgyResult(kind: GgyResultKind.failed, reason: '应答无法解析', note: _head(body), at: when);
    }
    final msg = decoded['msg']?.toString().trim() ?? '';
    if (!decoded.containsKey('status')) {
      return GgyResult(kind: GgyResultKind.ok, reason: msg, note: _head(body), at: when);
    }
    final code = decoded['status'];
    // 200 / 200.0 / "200" 一样看待
    final text = switch (code) {
      double d when d.isFinite && d.abs() < 1e15 && d == d.roundToDouble() => '${d.toInt()}',
      _ => '${code ?? 'null'}'.trim(),
    };
    if (text == '200') return GgyResult(kind: GgyResultKind.ok, reason: msg, at: when);
    final invalid = text == '400' && (msg.contains('无效') || msg.contains('失效'));
    return GgyResult(
      kind: invalid ? GgyResultKind.tokenInvalid : GgyResultKind.failed,
      reason: msg.isEmpty ? 'status $text' : msg,
      at: when,
    );
  }

  /// 应答开头 160 字节（按 UTF-8 截，截断处落在多字节字符中间就往前退到字符开头）
  static String _head(String body) {
    final bytes = utf8.encode(body);
    if (bytes.length <= 160) return body;
    var end = 160;
    while (end > 0 && (bytes[end] & 0xC0) == 0x80) {
      end--;
    }
    return utf8.decode(bytes.sublist(0, end));
  }

  /// 日志一行：`GGY 加白 <脱敏 token>：成功` / `GGY 加白 <脱敏 token>：失败（<原因>）`。
  /// 成功时 GGY 回了 msg 就原样带上（成功应答还没实测过，方便以后对照）；没有 status 字段的带上应答开头。token 一律脱敏。
  String logLine(String token) {
    final name = maskGgyToken(token);
    final String line;
    if (ok) {
      final extra = [if (reason.isNotEmpty) reason, if (note.isNotEmpty) '应答没有 status：$note'];
      line = 'GGY 加白 $name：成功${extra.isEmpty ? '' : '（${extra.join('；')}）'}';
    } else {
      line = 'GGY 加白 $name：失败（$reason${note.isEmpty ? '' : '：$note'}）';
    }
    return redactGgy(line, [token]);
  }

  /// 列表行里「上一次结果」的文字。
  String get summary {
    String two(int n) => n.toString().padLeft(2, '0');
    return switch (kind) {
      GgyResultKind.ok => '成功 · ${two(at.hour)}:${two(at.minute)}',
      GgyResultKind.tokenInvalid => 'token 无效或已失效',
      GgyResultKind.failed => '失败：$reason',
    };
  }
}

/// 一次上报的核心结果（与 po0 同一个 `meowPo0Report` 通道，见 core/meow_ggy.go）：`[{url, status, body, error}]`。
/// 按 url 认回是哪个 token；返回 token → 结论。
Map<String, GgyResult> parseGgyReport(String raw, List<String> tokens, {DateTime? at}) {
  final dynamic decoded;
  try {
    decoded = raw.isEmpty ? null : json.decode(raw);
  } on FormatException {
    return const {};
  }
  if (decoded is! List) return const {};
  final byUrl = {for (final t in tokens) ggyReportUrl(t): t};
  final out = <String, GgyResult>{};
  for (final r in decoded) {
    if (r is! Map) continue;
    final token = byUrl[r['url']?.toString() ?? ''];
    if (token == null) continue;
    final status = r['status'];
    out[token] = GgyResult.judge(
      status: status is num ? status.toInt() : int.tryParse('$status') ?? 0,
      body: r['body']?.toString() ?? '',
      error: redactGgy((r['error']?.toString() ?? '').replaceFirst(_urlErrorPrefix, ''), tokens),
      at: at,
    );
  }
  return out;
}

/// Go 的 url.Error 写成 `Get "<整个上报地址>": <原因>`：地址对用户没用，只留原因
final _urlErrorPrefix = RegExp(r'^[A-Za-z]+ "[^"]*": ');
