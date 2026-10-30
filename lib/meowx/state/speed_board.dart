import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

import 'speed_test.dart';

// MeowX 测速榜（规格 miaomiaowuC/Design/speedtest-board.md §2 / §3 / §5.2 / §6，与 iOS / macOS 同一套）：
// 测完、用户同意时把结果上传到许可证服务，拿回结果链接、「超越了 x%」与删除凭据，存进本机测速记录。
// 上传请求由 Go 核心经**测速用的同一个出站**发（ActionMethod.meowSpeedTestBoard，见 core/Clash.Meta/component/speedtest/board.go）：
// 服务端按来源 IP 判出口归属。已登录主控时先经主控的加密 RPC 要一张上传凭证（凭证绑定正文的 sha256），拿不到就匿名传。

/// 许可证服务（上传 / 删除）与公开的测速榜页面
const kSpeedBoardApi = 'https://license.miaomiaowux.com';
const kSpeedBoardPage = 'https://speed.meowx.net/board';

/// 联调：`--dart-define=MEOWX_SPEEDTEST_API=http://localhost:12890` 换服务地址（只有这时允许 http），上传强制走 DIRECT；
/// `--dart-define=MEOWX_SPEEDTEST_CF_IP=1.1.1.9` 再加一个 `CF-Connecting-IP` 头模拟出口（生产由 Cloudflare 填）。正式包不带这两个。
const _apiOverride = String.fromEnvironment('MEOWX_SPEEDTEST_API');
const _cfIpOverride = String.fromEnvironment('MEOWX_SPEEDTEST_CF_IP');

/// 测速榜的服务地址与联调开关。
@immutable
class SpeedBoardEndpoint {
  const SpeedBoardEndpoint({this.base = kSpeedBoardApi, this.override = false, this.connectingIp});

  /// 去掉结尾斜杠的服务地址
  final String base;

  /// 联调地址：上传强制走 DIRECT、允许 http、测速榜页面也在这台
  final bool override;

  /// 联调时模拟的出口 IP（`CF-Connecting-IP`）
  final String? connectingIp;

  /// 按编译时的 define 定；override 地址不是 http(s) 就当没设
  static SpeedBoardEndpoint fromEnvironment({String api = _apiOverride, String cfIp = _cfIpOverride}) {
    final raw = api.trim();
    final uri = Uri.tryParse(raw);
    if (raw.isEmpty || uri == null || (uri.scheme != 'http' && uri.scheme != 'https') || uri.host.isEmpty) {
      return const SpeedBoardEndpoint();
    }
    return SpeedBoardEndpoint(
      base: raw.replaceAll(RegExp(r'/+$'), ''),
      override: true,
      connectingIp: cfIp.trim().isEmpty ? null : cfIp.trim(),
    );
  }

  String get resultsUrl => '$base/api/v2/speedtest/results';
  String deleteUrl(String id) => '$resultsUrl/${Uri.encodeComponent(id)}';

  /// 「测速榜 ›」打开的页面
  String get boardPage => override ? '$base/board' : kSpeedBoardPage;

  /// 正式地址只认 https；联调地址按它自己的协议
  bool allows(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null) return false;
    return uri.scheme == 'https' || (override && uri.scheme == 'http');
  }
}

/// 节点协议的规格码（§2：配置里节点 `type` 的小写，`ss` `vless` `hysteria2`…）。核心的 proxies 里 type 是 mihomo 的写法
/// （「Vless」「Shadowsocks」「Socks5」），旧记录里只存了显示名（「VLESS」「Shadowsocks」），三种都认；不合规格的字符去掉，
/// 什么都不剩回 null。
String? speedBoardProtocolCode(String? type) {
  final t = type?.trim().toLowerCase() ?? '';
  if (t.isEmpty) return null;
  final code = switch (t) {
    'shadowsocks' => 'ss',
    'shadowsocksr' => 'ssr',
    'socks' => 'socks5',
    _ => t,
  }.replaceAll(RegExp(r'[^a-z0-9_-]'), '');
  if (code.isEmpty) return null;
  return code.length > 32 ? code.substring(0, 32) : code;
}

/// 本机网络的规格码（§2）：测速记录里存的是显示名（speed_test_network.dart）
String? speedBoardNetworkCode(String? label) => switch (label) {
  'Wi-Fi' => 'wifi',
  '5G' => '5g',
  '4G' => '4g',
  '3G' => '3g',
  '2G' => '2g',
  '移动数据' => 'cellular',
  '有线网络' => 'wired',
  _ => null,
};

/// 本机随机 UUID v4（小写，install_id）
String newSpeedBoardInstallId([Random? random]) {
  final r = random ?? Random.secure();
  final b = List<int>.generate(16, (_) => r.nextInt(256));
  b[6] = (b[6] & 0x0f) | 0x40;
  b[8] = (b[8] & 0x3f) | 0x80;
  final h = b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
  return '${h.substring(0, 8)}-${h.substring(8, 12)}-${h.substring(12, 16)}-${h.substring(16, 20)}-${h.substring(20)}';
}

/// 「超越了 x%」（服务端上传时算好，之后不变）
@immutable
class SpeedBoardPercentile {
  const SpeedBoardPercentile({required this.value, required this.scope, required this.samples});

  /// 0–100
  final int value;

  /// 「近 30 天 · 经节点 · 多线程」
  final String scope;

  /// 比较了多少次测速
  final int samples;

  /// 「近 30 天 · 经节点 · 多线程 · 2,431 次」
  String get scopeLine => [if (scope.isNotEmpty) scope, '${_thousands(samples)} 次'].join(' · ');

  static SpeedBoardPercentile? fromJson(Object? j) {
    if (j is! Map) return null;
    final value = j['value'];
    if (value is! num) return null;
    return SpeedBoardPercentile(
      value: value.round().clamp(0, 100),
      scope: j['scope'] is String ? j['scope'] as String : '',
      samples: (j['samples'] as num?)?.toInt() ?? 0,
    );
  }

  Map<String, Object?> toJson() => {'value': value, 'scope': scope, 'samples': samples};

  @override
  bool operator ==(Object other) =>
      other is SpeedBoardPercentile && other.value == value && other.scope == scope && other.samples == samples;

  @override
  int get hashCode => Object.hash(value, scope, samples);
}

String _thousands(int v) {
  final s = v.abs().toString();
  final out = StringBuffer(v < 0 ? '-' : '');
  for (var i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 == 0) out.write(',');
    out.write(s[i]);
  }
  return out.toString();
}

enum SpeedBoardStatus { uploading, uploaded, failed }

/// 一条测速记录在测速榜上的状态（存进本机记录的 `board` 字段；旧记录没有 = 没传过）。
/// 上传成功：[id] / [url] / [deleteToken]，可能带 [percentile]（样本不够时为 null）、[provider]（认不出时为 null）；
/// 失败：[error] 给人看的原因，[retryable] 能不能重试（400 = 服务端不收，不重试），[retryAt] 429 时按 Retry-After 算的最早重试时间。
@immutable
class SpeedBoardEntry {
  const SpeedBoardEntry({
    required this.status,
    this.id,
    this.url,
    this.deleteToken,
    this.percentile,
    this.provider,
    this.attributed = false,
    this.error,
    this.retryable = true,
    this.retryAt,
  });

  static const uploading = SpeedBoardEntry(status: SpeedBoardStatus.uploading);

  final SpeedBoardStatus status;
  final String? id, url, deleteToken;
  final SpeedBoardPercentile? percentile;

  /// 服务端认出来的服务商名
  final String? provider;

  /// 走了主控凭证（结果归到主控的许可证名下）
  final bool attributed;

  final String? error;
  final bool retryable;
  final DateTime? retryAt;

  bool get isUploaded => status == SpeedBoardStatus.uploaded && id != null && url != null;
  bool get isUploading => status == SpeedBoardStatus.uploading;
  bool get isFailed => status == SpeedBoardStatus.failed;

  /// 结果链接去掉协议头（「speed.meowx.net/r/7Kq2Xp」，界面与分享图上显示的写法）
  String? get shortUrl => url?.replaceFirst(RegExp(r'^https?://'), '');

  /// 429 之后还要等多久；不用等 null
  Duration? waitBeforeRetry(DateTime now) {
    final at = retryAt;
    if (at == null || !at.isAfter(now)) return null;
    return at.difference(now);
  }

  static SpeedBoardEntry failure(String error, {bool retryable = true, DateTime? retryAt}) =>
      SpeedBoardEntry(status: SpeedBoardStatus.failed, error: error, retryable: retryable, retryAt: retryAt);

  Map<String, Object?> toJson() => {
    'status': status.name,
    'id': ?id,
    'url': ?url,
    'deleteToken': ?deleteToken,
    'percentile': ?percentile?.toJson(),
    'provider': ?provider,
    if (attributed) 'attributed': true,
    'error': ?error,
    if (!retryable) 'retryable': false,
    'retryAt': ?(retryAt == null ? null : retryAt!.millisecondsSinceEpoch / 1000),
  };

  /// 认不出返回 null（当作没传过）；存盘时还在上传中（App 被关掉了）读回来算失败、可重试
  static SpeedBoardEntry? fromJson(Object? j) {
    if (j is! Map) return null;
    String? s(String key) => j[key] is String && (j[key] as String).isNotEmpty ? j[key] as String : null;
    final status = SpeedBoardStatus.values.where((e) => e.name == j['status']).firstOrNull;
    switch (status) {
      case null:
        return null;
      case SpeedBoardStatus.uploading:
        return failure('上传没有完成');
      case SpeedBoardStatus.uploaded:
        if (s('id') == null || s('url') == null) return null;
      case SpeedBoardStatus.failed:
        break;
    }
    final retryAt = j['retryAt'];
    return SpeedBoardEntry(
      status: status,
      id: s('id'),
      url: s('url'),
      deleteToken: s('deleteToken'),
      percentile: SpeedBoardPercentile.fromJson(j['percentile']),
      provider: s('provider'),
      attributed: j['attributed'] == true,
      error: s('error'),
      retryable: j['retryable'] != false,
      retryAt: retryAt is num ? DateTime.fromMillisecondsSinceEpoch((retryAt * 1000).round()) : null,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is SpeedBoardEntry &&
      other.status == status &&
      other.id == id &&
      other.url == url &&
      other.deleteToken == deleteToken &&
      other.percentile == percentile &&
      other.provider == provider &&
      other.attributed == attributed &&
      other.error == error &&
      other.retryable == retryable &&
      other.retryAt == retryAt;

  @override
  int get hashCode =>
      Object.hash(status, id, url, deleteToken, percentile, provider, attributed, error, retryable, retryAt);
}

/// 上传正文里的客户端信息
@immutable
class SpeedBoardClientInfo {
  const SpeedBoardClientInfo({required this.platform, required this.version});

  /// android / windows
  final String platform;
  final String version;
}

/// 这条记录能不能上传；能 = null，否则是原因（界面上「上传这条」不出现）。只传测完的（§3）。
String? speedBoardBlocker(SpeedTestRecord r) {
  if (r.failed) return '失败的测速不上传';
  if (r.downloadMbps == null) return '没有下载结果';
  if (!r.isDirect && r.boardProtocol == null) return '这条记录没有节点协议';
  return null;
}

double _round2(double v) => (v * 100).roundToDouble() / 100;
double? _round2n(double? v) => v == null ? null : _round2(v);

/// RFC3339（UTC、到秒）：「2026-10-29T15:42:10Z」
String speedBoardTime(DateTime t) {
  final u = t.toUtc();
  String two(int v) => v.toString().padLeft(2, '0');
  return '${u.year.toString().padLeft(4, '0')}-${two(u.month)}-${two(u.day)}T${two(u.hour)}:${two(u.minute)}:${two(u.second)}Z';
}

/// 组上传正文（§3，字段 snake_case）。不传节点名、IP、主控地址、账号。
Map<String, Object?> speedBoardBody(SpeedTestRecord r, {required String installId, required SpeedBoardClientInfo client}) {
  final hasUpload = r.source.hasUpload && r.uploadMbps != null;
  final e = r.exit;
  return {
    'v': 1,
    'client': {'app': 'MeowX', 'platform': client.platform, 'version': client.version, 'install_id': installId},
    'test': {
      'source': r.source.name,
      'connections': r.connections,
      'mode': r.isDirect ? 'direct' : 'node',
      'protocol': r.isDirect ? null : r.boardProtocol,
      'network': speedBoardNetworkCode(r.network),
      'latency_ms': r.latencyMs,
      'download_mbps': _round2n(r.downloadMbps),
      'upload_mbps': hasUpload ? _round2n(r.uploadMbps) : null,
      'download_peak_mbps': _round2n(r.downloadPeakMbps),
      'upload_peak_mbps': hasUpload ? _round2n(r.uploadPeakMbps) : null,
      'download_samples': [for (final v in r.downloadSamples.take(SpeedTestHistory.maxSamples)) _round2(v)],
      'upload_samples': hasUpload ? [for (final v in r.uploadSamples.take(SpeedTestHistory.maxSamples)) _round2(v)] : const [],
      'bytes_used': r.bytesUsed,
      // 旧记录没记时长：按每段 10 秒、加测延迟约 1.5 秒估（同 iOS；服务端只拿它粗核「用量 ≈ 速率 × 时长」，3 倍以内都算对）
      'duration_ms': r.durationMs ?? ((r.source.hasUpload ? 20000 : 10000) + 1500),
      'server': r.server,
      'finished_at': speedBoardTime(r.date),
    },
    'claimed_exit': e == null ? null : {'asn': e.asn, 'org': e.org, 'country': e.country},
  };
}

/// 正文字节：编一次就定下来，申请凭证（sha256）与上传用同一份，之后别再改
Uint8List speedBoardBytes(Map<String, Object?> body) => Uint8List.fromList(utf8.encode(json.encode(body)));

/// payload_hash：sha256(正文字节) 的 64 位小写 hex
String speedBoardHash(List<int> bytes) => sha256.convert(bytes).toString();

/// 核心 meowSpeedTestBoard 回的结果（component/speedtest 的 BoardResponse）
@immutable
class SpeedBoardHttp {
  const SpeedBoardHttp({this.status = 0, this.retryAfter, this.body = '', this.error, this.noProxy = false});

  /// HTTP 状态码；0 = 没拿到应答
  final int status;
  final String? retryAfter, error;
  final String body;
  final bool noProxy;

  /// 旧核心不认识这个方法时回 null / 空串 → null
  static SpeedBoardHttp? parse(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    try {
      final j = json.decode(raw);
      if (j is! Map) return null;
      String? s(String key) => j[key] is String && (j[key] as String).isNotEmpty ? j[key] as String : null;
      return SpeedBoardHttp(
        status: (j['status'] as num?)?.toInt() ?? 0,
        retryAfter: s('retryAfter'),
        body: s('body') ?? '',
        error: s('error'),
        noProxy: j['noProxy'] == true,
      );
    } catch (_) {
      return null;
    }
  }

  Map<String, Object?>? get bodyJson {
    try {
      final j = json.decode(body);
      return j is Map ? j.cast<String, Object?>() : null;
    } catch (_) {
      return null;
    }
  }

  /// 服务端的错误码（{"code": …}）
  String? get code => bodyJson?['code'] is String ? bodyJson!['code'] as String : null;
}

/// Retry-After：秒数或 HTTP 日期；认不出给 10 分钟（同服务端的限流窗口）
Duration speedBoardRetryAfter(String? value, {DateTime? now}) {
  const fallback = Duration(minutes: 10);
  final v = value?.trim() ?? '';
  if (v.isEmpty) return fallback;
  final seconds = int.tryParse(v);
  if (seconds != null) return Duration(seconds: seconds.clamp(1, 86400));
  try {
    final at = HttpDateParser.parse(v);
    final wait = at.difference(now ?? DateTime.now());
    return wait.isNegative ? const Duration(seconds: 1) : wait;
  } catch (_) {
    return fallback;
  }
}

/// RFC 7231 的 IMF-fixdate（「Wed, 21 Oct 2026 07:28:00 GMT」），只认这一种
abstract final class HttpDateParser {
  static const _months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

  static DateTime parse(String v) {
    final m = RegExp(r'^\w{3}, (\d{2}) (\w{3}) (\d{4}) (\d{2}):(\d{2}):(\d{2}) GMT$').firstMatch(v.trim());
    if (m == null) throw FormatException('不是 HTTP 日期', v);
    final month = _months.indexOf(m.group(2)!);
    if (month < 0) throw FormatException('月份不对', v);
    return DateTime.utc(int.parse(m.group(3)!), month + 1, int.parse(m.group(1)!), int.parse(m.group(4)!),
        int.parse(m.group(5)!), int.parse(m.group(6)!));
  }
}

/// 上传的应答 → 记录里的状态（§5.2 / §5.2.1）。401 由 [SpeedBoardUploader] 先去掉凭证重传一次，到这里还是 401 算可重试的失败。
SpeedBoardEntry speedBoardUploadOutcome(SpeedBoardHttp? r, {required bool attributed, DateTime? now}) {
  if (r == null) return SpeedBoardEntry.failure('内核版本过旧，重启 App 后再试');
  if (r.noProxy) return SpeedBoardEntry.failure('测速用的节点已不在当前配置里');
  if (r.status == 0) return SpeedBoardEntry.failure(r.error == null ? '连不上测速榜' : '连不上测速榜：${r.error}');
  final j = r.bodyJson;
  if (r.status == 200) {
    String? s(String key) => j?[key] is String && (j![key] as String).isNotEmpty ? j[key] as String : null;
    final id = s('id'), url = s('url'), token = s('delete_token');
    if (id == null || url == null) return SpeedBoardEntry.failure('测速榜的应答无法解析');
    final provider = j?['provider'];
    return SpeedBoardEntry(
      status: SpeedBoardStatus.uploaded,
      id: id,
      url: url,
      deleteToken: token,
      percentile: SpeedBoardPercentile.fromJson(j?['percentile']),
      provider: provider is Map && provider['name'] is String && (provider['name'] as String).isNotEmpty
          ? provider['name'] as String
          : null,
      attributed: j?['attributed'] is bool ? j!['attributed'] as bool : attributed,
    );
  }
  if (r.status == 400) return SpeedBoardEntry.failure('测速榜没有收下这条结果', retryable: false);
  if (r.status == 429) {
    final wait = speedBoardRetryAfter(r.retryAfter, now: now);
    return SpeedBoardEntry.failure('上传太频繁', retryAt: (now ?? DateTime.now()).add(wait));
  }
  if (r.status >= 500) return SpeedBoardEntry.failure('测速榜暂时不可用（HTTP ${r.status}）');
  return SpeedBoardEntry.failure('上传失败（HTTP ${r.status}）');
}

/// 删除的结果
sealed class SpeedBoardDeleteResult {
  const SpeedBoardDeleteResult();
}

/// 删掉了（或者服务端那边本来就没有了）：清掉本机记录里的远端字段
final class SpeedBoardDeleted extends SpeedBoardDeleteResult {
  const SpeedBoardDeleted();
}

final class SpeedBoardDeleteFailed extends SpeedBoardDeleteResult {
  const SpeedBoardDeleteFailed(this.message);
  final String message;
}

/// 删除的应答（§5.2.1）：200（含已删过）/ 404 都算删掉了；403 删除凭据不对
SpeedBoardDeleteResult speedBoardDeleteOutcome(SpeedBoardHttp? r) {
  if (r == null) return const SpeedBoardDeleteFailed('内核版本过旧，重启 App 后再试');
  if (r.status == 200 || r.status == 404) return const SpeedBoardDeleted();
  if (r.status == 0) return SpeedBoardDeleteFailed(r.error == null ? '连不上测速榜' : '连不上测速榜：${r.error}');
  if (r.status == 403) return const SpeedBoardDeleteFailed('删除凭据不对');
  if (r.status == 429) return const SpeedBoardDeleteFailed('请求太频繁，稍后再试');
  return SpeedBoardDeleteFailed('删除失败（HTTP ${r.status}）');
}

/// 调核心 meowSpeedTestBoard（参数 JSON → 回 BoardResponse 的 JSON；旧核心回 null）
typedef SpeedBoardSend = Future<String?> Function(String data);

/// 申请上传凭证（已登录主控时经加密 RPC，§4）；拿不到回 null，不抛
typedef SpeedBoardGrant = Future<String?> Function(String payloadHash);

/// 上传 / 删除一条记录。每次上传都重新组正文、重新要凭证（凭证只有 5 分钟、一次性）。
class SpeedBoardUploader {
  SpeedBoardUploader({required this.send, this.grant, SpeedBoardEndpoint? endpoint, this.now})
    : endpoint = endpoint ?? SpeedBoardEndpoint.fromEnvironment();

  final SpeedBoardSend send;
  SpeedBoardGrant? grant;
  final SpeedBoardEndpoint endpoint;
  final DateTime Function()? now;

  static const grantTimeout = Duration(seconds: 10);

  /// 走哪个出站：测速用的那个；联调地址一律 DIRECT（本机服务经节点到不了）
  String proxyFor(SpeedTestRecord r) => endpoint.override ? kSpeedTestDirect : r.outbound;

  Map<String, String> _headers(Map<String, String> extra) => {
    ...extra,
    if (endpoint.connectingIp != null) 'CF-Connecting-IP': endpoint.connectingIp!,
  };

  Future<SpeedBoardHttp?> _request(String proxy, String method, String url, Map<String, String> headers, [Uint8List? body]) async {
    String? raw;
    try {
      raw = await send(json.encode({
        'proxy': proxy,
        'method': method,
        'url': url,
        'headers': _headers(headers),
        if (body != null) 'body': base64.encode(body),
      }));
    } catch (_) {
      raw = null;
    }
    return SpeedBoardHttp.parse(raw);
  }

  Future<SpeedBoardEntry> upload(SpeedTestRecord r, {required String installId, required SpeedBoardClientInfo client}) async {
    final blocker = speedBoardBlocker(r);
    if (blocker != null) return SpeedBoardEntry.failure(blocker, retryable: false);
    final url = endpoint.resultsUrl;
    if (!endpoint.allows(url)) return SpeedBoardEntry.failure('测速榜地址无效', retryable: false);
    final bytes = speedBoardBytes(speedBoardBody(r, installId: installId, client: client));
    final hash = speedBoardHash(bytes);
    String? token;
    try {
      token = await grant?.call(hash).timeout(grantTimeout);
    } catch (_) {
      token = null;
    }
    final proxy = proxyFor(r);
    const type = {'Content-Type': 'application/json'};
    var resp = await _request(proxy, 'POST', url, {...type, 'X-MeowX-Speed-Grant': ?token}, bytes);
    var attributed = token != null;
    // 凭证验不过（过期 / 用过 / 不符）：去掉凭证匿名再传一次（这一次不占限流名额，§5.2.1）
    if (resp?.status == 401 && token != null) {
      attributed = false;
      resp = await _request(proxy, 'POST', url, type, bytes);
    }
    return speedBoardUploadOutcome(resp, attributed: attributed, now: now?.call());
  }

  /// 删除：经这条记录测速用的出站发（它已不在当前配置里就走 DIRECT）
  Future<SpeedBoardDeleteResult> delete(SpeedTestRecord r) async {
    final b = r.board;
    if (b == null || !b.isUploaded) return const SpeedBoardDeleted();
    final token = b.deleteToken;
    if (token == null) return const SpeedBoardDeleteFailed('这条记录没有删除凭据');
    final url = endpoint.deleteUrl(b.id!);
    if (!endpoint.allows(url)) return const SpeedBoardDeleteFailed('测速榜地址无效');
    final headers = {'X-MeowX-Delete-Token': token};
    var resp = await _request(proxyFor(r), 'DELETE', url, headers);
    if (resp?.noProxy == true) resp = await _request(kSpeedTestDirect, 'DELETE', url, headers);
    return speedBoardDeleteOutcome(resp);
  }
}
