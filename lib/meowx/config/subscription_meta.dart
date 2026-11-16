// 主控实时通道与订阅自动更新的纯逻辑（规格 MeowX 仓库 Design/entry-realtime.md §2.3 / §3.2 / §3.3）。
// 只放纯函数与值类型：拉订阅时记下的应答头、该连哪些主控、一条订阅变更要重拉哪些订阅档。状态与 I/O 在 state/realtime_sync.dart。

/// 主控地址的规范写法：`scheme://host[:port]`，host 小写，去掉路径、查询与结尾斜杠；不写 scheme 按 https。
/// 与内核 panelrt.NormalizeBase 同一口径（内核回调里的 base 就是我们交过去的这个字符串）。地址无效回 null。
String? normalizePanelBase(String? raw) {
  var s = (raw ?? '').trim();
  if (s.isEmpty) return null;
  if (!s.contains('://')) s = 'https://$s';
  final uri = Uri.tryParse(s);
  if (uri == null || uri.host.isEmpty) return null;
  final scheme = uri.scheme.toLowerCase();
  if (scheme != 'https' && scheme != 'http') return null;
  var host = uri.host.toLowerCase();
  // Dart 的 Uri 把 IPv6 的方括号去掉了，拼回去
  if (host.contains(':')) host = '[$host]';
  final port = uri.hasPort ? ':${uri.port}' : '';
  return '$scheme://$host$port';
}

/// 订阅地址的主机名（小写，没有返回空串）。
String subscriptionHost(String url) => (Uri.tryParse(url.trim())?.host ?? '').toLowerCase();

/// 拉订阅时主控给的应答头（只有妙妙屋X 主控对官方客户端才给，§2.3 / §3.2）。
/// **订阅键只认应答头**，不从地址猜；旧主控没有这些头时 [key] 为空：这份订阅只在不带 subs 的推送时更新。
class SubscriptionMeta {
  const SubscriptionMeta({
    required this.url,
    this.key = '',
    this.rev = '',
    this.realtimeUrl = '',
    this.realtime = '',
    this.updatedAt = 0,
  });

  /// 拉的那个订阅地址（档案的 url；换了地址的档案旧记录作废）
  final String url;

  /// `mmwx-sub-key`：主控给的订阅键（如 `pkg:12`、`file:alice.yaml`）
  final String key;

  /// `mmwx-sub-rev`：这次拉到的渲染指纹
  final String rev;

  /// `mmwx-realtime-url`：实时通道所在的主控（订阅域名与主控不同时也是主控地址）
  final String realtimeUrl;

  /// `mmwx-realtime`：只读通道凭证（不透明字符串，原样存、原样用）
  final String realtime;

  /// 记下的时间（毫秒）
  final int updatedAt;

  /// 规范化后的实时通道主控地址；没给或无效为 null。
  String? get realtimeBase => normalizePanelBase(realtimeUrl);

  bool get hasRealtimeCredential => realtime.isNotEmpty && realtimeBase != null;

  /// 从应答头取（[header] 按名字取第一个值，大小写不敏感由调用方保证）。
  factory SubscriptionMeta.fromHeaders(String url, String? Function(String name) header, {required int now}) {
    String h(String name) => (header(name) ?? '').trim();
    return SubscriptionMeta(
      url: url,
      key: h('mmwx-sub-key'),
      rev: h('mmwx-sub-rev'),
      realtimeUrl: h('mmwx-realtime-url'),
      realtime: h('mmwx-realtime'),
      updatedAt: now,
    );
  }

  factory SubscriptionMeta.fromJson(Map<String, dynamic> j) => SubscriptionMeta(
    url: j['url']?.toString() ?? '',
    key: j['key']?.toString() ?? '',
    rev: j['rev']?.toString() ?? '',
    realtimeUrl: j['realtimeUrl']?.toString() ?? '',
    realtime: j['realtime']?.toString() ?? '',
    updatedAt: (j['updatedAt'] as num?)?.toInt() ?? 0,
  );

  Map<String, dynamic> toJson() => {
    'url': url,
    if (key.isNotEmpty) 'key': key,
    if (rev.isNotEmpty) 'rev': rev,
    if (realtimeUrl.isNotEmpty) 'realtimeUrl': realtimeUrl,
    if (realtime.isNotEmpty) 'realtime': realtime,
    'updatedAt': updatedAt,
  };

  @override
  bool operator ==(Object other) =>
      other is SubscriptionMeta &&
      other.url == url &&
      other.key == key &&
      other.rev == rev &&
      other.realtimeUrl == realtimeUrl &&
      other.realtime == realtime &&
      other.updatedAt == updatedAt;

  @override
  int get hashCode => Object.hash(url, key, rev, realtimeUrl, realtime, updatedAt);
}

/// 一份订阅档（只取规划要用的几项，免得纯逻辑依赖 Bettbox 的 Profile）。
class SubscriptionProfileRef {
  const SubscriptionProfileRef({required this.id, required this.url, this.meta});

  final String id;
  final String url;

  /// 这个版本拉这份订阅时记下的应答头；null = 这个版本还没拉过它（升级前导入的）
  final SubscriptionMeta? meta;

  /// 记录还作数：拉的是现在这个地址
  SubscriptionMeta? get currentMeta => meta != null && meta!.url == url ? meta : null;
}

/// 已登录的主控（地址规范化过）；没登录为 null。
class PanelLogin {
  const PanelLogin({required this.base, required this.token});

  final String base;
  final String token;

  String get host => (Uri.tryParse(base)?.host ?? '').toLowerCase();

  static PanelLogin? of(String host, String token) {
    final base = normalizePanelBase(host);
    if (base == null || token.trim().isEmpty) return null;
    return PanelLogin(base: base, token: token.trim());
  }
}

/// 这份订阅档归哪个主控（实时通道的 base，内核回调里的 base 与它比）：
/// 已登录的主控（订阅里给的通道主控就是它，或订阅地址的主机就是它）→ 它；否则订阅给的通道主控；再否则订阅地址的源。
String? panelBaseOf(SubscriptionProfileRef p, PanelLogin? login) {
  final rt = p.currentMeta?.realtimeBase;
  final urlBase = normalizePanelBase(p.url);
  if (login != null && (rt == login.base || (urlBase != null && subscriptionHost(p.url) == login.host))) {
    return login.base;
  }
  return rt ?? urlBase;
}

/// 一条实时通道（交给内核 panelrt.Configure 的 {base, token | rt}）。
class RealtimeChannelPlan {
  const RealtimeChannelPlan.token(this.base, this.token) : rt = '';
  const RealtimeChannelPlan.rt(this.base, this.rt) : token = '';

  final String base;
  final String token;
  final String rt;

  Map<String, String> toJson() => {'base': base, if (token.isNotEmpty) 'token': token, if (rt.isNotEmpty) 'rt': rt};

  @override
  bool operator ==(Object other) => other is RealtimeChannelPlan && other.base == base && other.token == token && other.rt == rt;

  @override
  int get hashCode => Object.hash(base, token, rt);

  @override
  String toString() => 'RealtimeChannelPlan($base, ${token.isNotEmpty ? 'token' : 'rt'})';
}

/// 一份订阅的 rev（告诉内核「这份我手上就是这个 rev」，主控说一样的就不再通知）。
class SubRevNote {
  const SubRevNote(this.base, this.key, this.rev);

  final String base;
  final String key;
  final String rev;

  Map<String, String> toJson() => {'base': base, 'key': key, 'rev': rev};

  @override
  bool operator ==(Object other) => other is SubRevNote && other.base == base && other.key == key && other.rev == rev;

  @override
  int get hashCode => Object.hash(base, key, rev);
}

class RealtimePlan {
  const RealtimePlan({required this.channels, required this.subs});

  final List<RealtimeChannelPlan> channels;
  final List<SubRevNote> subs;

  Set<String> get bases => {for (final c in channels) c.base};
}

/// 该连哪些主控（§2.3）：
/// - 登录了主控：用会话 token 连它（同一主控既有登录态又有 rt 时只连这一条）；
/// - 没登录的主控、订阅应答里给了只读凭证的：**一个主控一条**（主控每个用户最多 16 条连接），优先用当前在用的那份订阅的凭证，
///   其次最近拉过的那份。rt 只覆盖它绑定的那份订阅：同一主控的其它订阅收不到入口与订阅推送，靠各自的定时更新。
/// [subs] 是手上各订阅的 rev（交给内核，见 [SubRevNote]）。
RealtimePlan planRealtime({
  required PanelLogin? login,
  required List<SubscriptionProfileRef> profiles,
  required String? currentProfileId,
}) {
  final channels = <RealtimeChannelPlan>[];
  if (login != null) channels.add(RealtimeChannelPlan.token(login.base, login.token));
  final byBase = <String, SubscriptionProfileRef>{};
  final subs = <SubRevNote>[];
  for (final p in profiles) {
    final meta = p.currentMeta;
    if (meta == null) continue;
    final base = panelBaseOf(p, login);
    if (base != null && meta.key.isNotEmpty && meta.rev.isNotEmpty) subs.add(SubRevNote(base, meta.key, meta.rev));
    if (!meta.hasRealtimeCredential || base == null || base == login?.base) continue;
    final prev = byBase[base];
    if (prev == null) {
      byBase[base] = p;
      continue;
    }
    final pIsCurrent = p.id == currentProfileId;
    final prevIsCurrent = prev.id == currentProfileId;
    if (pIsCurrent && !prevIsCurrent || pIsCurrent == prevIsCurrent && meta.updatedAt > prev.currentMeta!.updatedAt) {
      byBase[base] = p;
    }
  }
  final bases = byBase.keys.toList()..sort();
  for (final base in bases) {
    channels.add(RealtimeChannelPlan.rt(base, byBase[base]!.currentMeta!.realtime));
  }
  return RealtimePlan(channels: channels, subs: subs);
}

/// 内核记下的一条订阅变更（待更新队列里的一项：主控 [base] 上键为 [key] 的订阅现在是 [rev]；[key] 为空 = 这个主控来的全部订阅）。
class SubChange {
  const SubChange({required this.base, required this.key, required this.rev, this.at = 0});

  final String base;
  final String key;
  final String rev;
  final int at;

  factory SubChange.fromJson(Map<String, dynamic> j) => SubChange(
    base: j['base']?.toString() ?? '',
    key: j['key']?.toString() ?? '',
    rev: j['rev']?.toString() ?? '',
    at: (j['at'] as num?)?.toInt() ?? 0,
  );

  Map<String, dynamic> toJson() => {'base': base, 'key': key, 'rev': rev};

  @override
  bool operator ==(Object other) => other is SubChange && other.base == base && other.key == key && other.rev == rev;

  @override
  int get hashCode => Object.hash(base, key, rev);

  @override
  String toString() => 'SubChange($base, ${key.isEmpty ? '*' : key}, $rev)';
}

/// 一条订阅变更要重拉哪些订阅档（§3.3），只看这个主控来的、有订阅地址的档：
/// - 带键：记下的键相同、rev 不同（或没记 rev）的；另外这个版本还没拉过的档（升级前导入的，不知道它的键）也重拉一次，
///   拉完就记下了键，之后按键认；
/// - 不带键（旧主控的 subscription_changed）：这个主控来的全部订阅档。
List<String> profilesToRefresh(SubChange change, List<SubscriptionProfileRef> profiles, PanelLogin? login) {
  final out = <String>[];
  for (final p in profiles) {
    if (p.url.trim().isEmpty || !p.url.trim().toLowerCase().startsWith('http')) continue;
    if (panelBaseOf(p, login) != change.base) continue;
    if (change.key.isEmpty) {
      out.add(p.id);
      continue;
    }
    final meta = p.currentMeta;
    if (meta == null) {
      out.add(p.id);
      continue;
    }
    if (meta.key != change.key) continue;
    if (meta.rev.isEmpty || change.rev.isEmpty || meta.rev != change.rev) out.add(p.id);
  }
  return out;
}

/// 推送触发的重拉带的请求头（§3.3）：主控据此不发「订阅已拉取」通知、短链限速不计数。
const pushRefreshHeaders = {'mmwx-refresh': 'push'};

/// 同一份订阅推送触发的重拉至少隔这么久（§3.3；内核那边对通知也有同样的节流，这里管的是同一档被几条变更同时点到）。
const pushRefreshMinInterval = Duration(seconds: 30);

/// 重拉失败后的重试间隔：1、2、4… 分钟，封顶 30 分钟。
Duration pushRetryDelay(int failures) {
  final minutes = 1 << (failures.clamp(0, 5));
  return Duration(minutes: minutes > 30 ? 30 : minutes);
}
