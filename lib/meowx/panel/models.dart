// 面板返回的数据模型与纯解析函数（可单测）。
import 'unlock_catalog.dart';

/// 「我的订阅」条目。
class RemoteSubscription {
  const RemoteSubscription({
    required this.name,
    required this.filename,
    required this.subscriptionPath,
    this.expireAt,
    this.trafficUsed,
    this.trafficTotal,
  });

  final String name;
  final String filename;
  final String subscriptionPath;
  final DateTime? expireAt;

  /// 旧面板缺失 → null
  final int? trafficUsed, trafficTotal;

  /// 顶层数组或 `subscriptions | items | data` 包裹
  static List<RemoteSubscription> parseList(dynamic json) {
    final list = switch (json) {
      List l => l,
      Map m => (m['subscriptions'] ?? m['items'] ?? m['data']) is List ? (m['subscriptions'] ?? m['items'] ?? m['data']) as List : const [],
      _ => const [],
    };
    return [
      for (final e in list)
        if (e is Map)
          RemoteSubscription(
            name: e['name']?.toString() ?? e['filename']?.toString() ?? '订阅',
            filename: e['filename']?.toString() ?? '',
            subscriptionPath: e['subscription_path']?.toString() ?? '',
            expireAt: DateTime.tryParse(e['expire_at']?.toString() ?? ''),
            trafficUsed: _int(e['traffic_used']),
            trafficTotal: _int(e['traffic_total']),
          ),
    ];
  }

  /// 下载地址：短链 `base + subscription_path` 优先，回退 `/api/clash/subscribe?token=&filename=&t=clash`
  String downloadUrl(String base, {required String subscriptionToken}) {
    final b = base.endsWith('/') ? base.substring(0, base.length - 1) : base;
    if (subscriptionPath.isNotEmpty) {
      return subscriptionPath.startsWith('/') ? '$b$subscriptionPath' : '$b/$subscriptionPath';
    }
    final q = Uri(queryParameters: {'token': subscriptionToken, 'filename': filename, 't': 'clash'}).query;
    return '$b/api/clash/subscribe?$q';
  }
}

int? _int(dynamic v) => switch (v) {
  int i => i,
  num n => n.toInt(),
  String s => int.tryParse(s),
  _ => null,
};

/// 登录结果：拿到 token，或需要二步验证。
sealed class LoginResult {
  const LoginResult();
}

class LoginSuccess extends LoginResult {
  const LoginSuccess({required this.token, required this.username, required this.nickname, required this.avatarUrl});
  final String token, username, nickname, avatarUrl;

  static LoginSuccess? tryParse(Map<String, dynamic> json) {
    final token = json['token']?.toString();
    if (token == null || token.isEmpty) return null;
    final username = json['username']?.toString() ?? '';
    return LoginSuccess(
      token: token,
      username: username,
      nickname: (json['nickname']?.toString() ?? '').isNotEmpty ? json['nickname'].toString() : username,
      avatarUrl: json['avatar_url']?.toString() ?? '',
    );
  }
}

class LoginNeeds2FA extends LoginResult {
  const LoginNeeds2FA(this.twoFactorToken);
  final String twoFactorToken;
}

/// 节点回程奖牌。
class ReturnRoute {
  const ReturnRoute({required this.carrier, this.region, required this.routeType, required this.gold});
  final String carrier;
  final String? region;
  final String routeType;
  final bool gold;
}

class NodeMedal {
  const NodeMedal({required this.name, required this.medal, required this.routes});
  final String name;

  /// gold | silver
  final String medal;
  final List<ReturnRoute> routes;

  static Map<String, NodeMedal> parse(dynamic json) {
    if (json is! Map || json['success'] != true || json['nodes'] is! List) return const {};
    final out = <String, NodeMedal>{};
    for (final n in json['nodes'] as List) {
      if (n is! Map) continue;
      final name = n['name']?.toString() ?? '';
      final medal = n['medal']?.toString() ?? '';
      if (name.isEmpty || medal.isEmpty) continue;
      out[name] = NodeMedal(
        name: name,
        medal: medal,
        routes: [
          for (final r in (n['routes'] is List ? n['routes'] as List : const []))
            if (r is Map)
              ReturnRoute(
                carrier: r['carrier']?.toString() ?? '',
                region: r['region']?.toString(),
                routeType: r['route_type']?.toString() ?? '',
                gold: r['gold'] == true,
              ),
        ],
      );
    }
    return out;
  }
}

/// 深链解析：`miaomiaowu://login?host=<base>&code=<一次性码>`（host 缺 scheme 补 https）。
({String base, String code})? parseLoginLink(Uri uri) {
  if (uri.scheme != 'miaomiaowu' || uri.host != 'login') return null;
  var host = uri.queryParameters['host'] ?? '';
  final code = uri.queryParameters['code'] ?? '';
  if (host.isEmpty || code.isEmpty) return null;
  if (!host.startsWith('http://') && !host.startsWith('https://')) host = 'https://$host';
  if (host.endsWith('/')) host = host.substring(0, host.length - 1);
  return (base: host, code: code);
}

/// 主控开了哪些「节点附加信息」功能：没开的既不调接口也不显示图标。
class PanelFeatures {
  const PanelFeatures({this.returnRoutes = false, this.unlockCheck = false});
  final bool returnRoutes, unlockCheck;

  static PanelFeatures parse(dynamic json) {
    if (json is! Map || json['success'] != true) return const PanelFeatures();
    return PanelFeatures(returnRoutes: json['return_routes'] == true, unlockCheck: json['unlock_check'] == true);
  }
}

/// 单项解锁结论。
class UnlockEntry {
  const UnlockEntry({required this.service, required this.status, this.region});
  final String service, status;
  final String? region;

  UnlockServiceMeta get meta => unlockServiceMeta(service);
  bool get unlocked => isUnlocked(status);

  /// 行内状态文本：普通服务「已解锁 · HK」；信息类服务 yes 时只显示 region。
  String get statusText {
    if (meta.info && status == 'yes') return (region?.isNotEmpty ?? false) ? region! : '—';
    final label = unlockStatusMeta(status).label;
    return (region?.isNotEmpty ?? false) ? '$label · $region' : label;
  }
}

/// 解锁徽标三态：全部解锁 / 部分解锁 / 一个都没解锁（三端同一套）。
enum UnlockLevel {
  full('全部解锁'),
  partial('部分解锁'),
  none('未解锁');

  const UnlockLevel(this.label);
  final String label;
}

/// 徽标 / 头行 / 分类标签共用口径（与 iOS 一致）：只数有「解锁 / 未解锁」二值结论的服务，
/// 信息类（Apple 地区、Steam 货币、CDN…）的 yes 只表示测到了，不进分子分母；全是信息类时退回按全部条目数。
class UnlockSummary {
  const UnlockSummary({required this.unlocked, required this.total});
  final int unlocked, total;

  static UnlockSummary of(List<UnlockEntry> entries) {
    final checkable = entries.where((e) => !e.meta.info).toList();
    final pool = checkable.isEmpty ? entries : checkable;
    return UnlockSummary(unlocked: pool.where((e) => e.unlocked).length, total: pool.length);
  }

  UnlockLevel get level {
    if (total > 0 && unlocked == total) return UnlockLevel.full;
    return unlocked > 0 ? UnlockLevel.partial : UnlockLevel.none;
  }
}

/// 一个节点的解锁结论（按目录顺序）。
class NodeUnlocks {
  const NodeUnlocks({required this.name, required this.entries});
  final String name;
  final List<UnlockEntry> entries;

  int get unlockedCount => entries.where((e) => e.unlocked).length;
  UnlockSummary get summary => UnlockSummary.of(entries);
  UnlockLevel get level => summary.level;

  /// 按分类分组，组内保持目录顺序；目录里没有的 key 归「其他」。
  Map<UnlockCategory, List<UnlockEntry>> get grouped {
    final sorted = [...entries]..sort((a, b) => _orderOf(a.service).compareTo(_orderOf(b.service)));
    final out = {for (final c in UnlockCategory.values) c: <UnlockEntry>[]};
    for (final e in sorted) {
      out[e.meta.category]!.add(e);
    }
    return out;
  }

  static int _orderOf(String key) {
    final i = unlockServices.indexWhere((s) => s.key == key);
    return i == -1 ? 999 : i;
  }

  static Map<String, NodeUnlocks> parse(dynamic json) {
    if (json is! Map || json['success'] != true || json['nodes'] is! List) return const {};
    final out = <String, NodeUnlocks>{};
    for (final n in json['nodes'] as List) {
      if (n is! Map) continue;
      final name = n['name']?.toString() ?? '';
      final list = n['unlocks'];
      if (name.isEmpty || list is! List) continue;
      final entries = [
        for (final u in list)
          if (u is Map && (u['service']?.toString().isNotEmpty ?? false))
            UnlockEntry(service: u['service'].toString(), status: u['status']?.toString() ?? 'failed', region: u['region']?.toString()),
      ];
      if (entries.isNotEmpty) out[name] = NodeUnlocks(name: name, entries: entries);
    }
    return out;
  }
}
