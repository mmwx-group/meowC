import 'dart:convert';

/// 订阅响应头：`profile-title`（可带 `base64:` 前缀）→ 档案名；`profile-update-interval`（小时，默认 24）。
String? subscriptionTitle(String? header) {
  if (header == null) return null;
  var v = header.trim();
  if (v.isEmpty) return null;
  if (v.toLowerCase().startsWith('base64:')) {
    try {
      v = utf8.decode(base64.decode(base64.normalize(v.substring(7).trim())));
    } catch (_) {
      return null;
    }
  }
  v = v.trim();
  return v.isEmpty ? null : v;
}

Duration subscriptionUpdateInterval(String? header, {int defaultHours = 24}) {
  final h = int.tryParse((header ?? '').trim());
  if (h == null || h <= 0) return Duration(hours: defaultHours);
  return Duration(hours: h);
}

/// 有的订阅服务看 UA 里有没有 `clash` 决定给 Clash 配置还是「通用订阅」（base64 的分享链接）。
/// 我们的 UA（`mihomo/1.19.0 MeowX/…`，见 PackageInfoExtension.ua）里没有，这类订阅就回通用订阅，内核读不了。
/// `clash.meta` 同时带 clash / meta 两个关键字，这类服务认得出、给的是 Meta 版配置。
const clashCompatUa = 'clash.meta';

const subscriptionShareLinkMessage = '订阅返回的是通用订阅（vmess:// 等分享链接的列表），不是 Clash 配置，暂不支持导入；请换用 Clash 格式的订阅链接';

/// 拉订阅：先用 App 自己的 UA（[get] 收到 null），妙妙屋X 主控认 `MeowX/` 下发专属节点；回的是通用订阅就换 [clashCompatUa]
/// 再要一次。还是通用订阅（只发分享链接的源）就报明白，不把「yaml: unmarshal errors」丢给用户。
Future<T> fetchClashSubscription<T>(Future<T> Function(String? userAgent) get, List<int> Function(T response) bytesOf) async {
  final first = await get(null);
  if (!isShareLinkSubscription(bytesOf(first))) return first;
  final retry = await get(clashCompatUa);
  if (!isShareLinkSubscription(bytesOf(retry))) return retry;
  throw subscriptionShareLinkMessage;
}

const _shareLinkSchemes = {
  'vmess', 'vless', 'ss', 'ssr', 'trojan', 'hysteria', 'hysteria2', 'hy2', 'tuic', 'anytls', 'wireguard', 'socks5', 'mieru',
};

/// 订阅内容是「通用订阅」：一行一个分享链接（vmess:// vless:// ss:// …），整段 base64 编码或明文都算。Clash YAML 不算。
bool isShareLinkSubscription(List<int> bytes) {
  final text = utf8.decode(bytes, allowMalformed: true).trim();
  if (text.isEmpty) return false;
  return _mostlyShareLinks(text) || _mostlyShareLinks(_tryBase64(text) ?? '');
}

/// 至少一半的非空行是分享链接（容许夹杂几行别的，比如有的订阅在开头放 `STATUS=…`）。
bool _mostlyShareLinks(String text) {
  final lines = [for (final l in const LineSplitter().convert(text)) if (l.trim().isNotEmpty) l.trim()];
  if (lines.isEmpty) return false;
  final links = lines.where((l) {
    final i = l.indexOf('://');
    return i > 0 && _shareLinkSchemes.contains(l.substring(0, i).toLowerCase());
  }).length;
  return links > 0 && links * 2 >= lines.length;
}

/// 整段（忽略空白）是 base64（标准或 URL 安全字母表、可缺 `=`）就解出来，否则 null。
String? _tryBase64(String text) {
  final compact = text.replaceAll(RegExp(r'\s'), '');
  if (!RegExp(r'^[A-Za-z0-9+/_-]+=*$').hasMatch(compact)) return null;
  try {
    return utf8.decode(base64.decode(base64.normalize(compact.replaceAll('-', '+').replaceAll('_', '/'))), allowMalformed: true);
  } on FormatException {
    return null;
  }
}
