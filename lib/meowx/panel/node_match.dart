import 'package:flutter/foundation.dart';

/// 认节点的第二把钥匙：订阅里这个节点的 type / server / port（type、server 归一成小写）。
///
/// 奖牌 / 解锁一直按**节点名**逐字匹配主控的回包。但主控的套餐订阅会给节点改名（套餐内名称、倍率前缀「2」、
/// 流量 / 到期尾缀、重名追加 (n)），尾缀还随用量与日期变，名字对不上图标就不显示。主控因此在回包里多带这三项
/// （与它「外部订阅同步」按 类型:服务器:端口 认节点是同一个思路），客户端名字对不上时退到它。与 iOS / macOS 端同一套规则。
@immutable
class NodeMatchKey {
  const NodeMatchKey._(this.type, this.server, this.port);

  final String type;
  final String server;
  final int port;

  /// 三项都得有才成键；旧主控的回包不带，返回 null（只按名字认）。
  static NodeMatchKey? of({Object? type, Object? server, Object? port}) {
    final t = (type?.toString() ?? '').trim().toLowerCase();
    final s = (server?.toString() ?? '').trim().toLowerCase();
    final p = port is int ? port : (port is num ? port.toInt() : int.tryParse(port?.toString().trim() ?? '') ?? 0);
    if (t.isEmpty || s.isEmpty || p <= 0) return null;
    return NodeMatchKey._(t, s, p);
  }

  /// 订阅里的一个节点（clash 的 proxy 映射）。mieru 只写 `port-range` 时没有 `port`：取范围起点
  /// （主控给的也是范围的第一个端口）。
  static NodeMatchKey? ofProxy(Map<dynamic, dynamic> proxy) {
    Object? port = proxy['port'];
    if (port == null || port.toString().trim().isEmpty || port.toString().trim() == '0') {
      port = proxy['port-range']?.toString().split('-').first;
    }
    return of(type: proxy['type'], server: proxy['server'], port: port);
  }

  @override
  bool operator ==(Object other) => other is NodeMatchKey && other.type == type && other.server == server && other.port == port;

  @override
  int get hashCode => Object.hash(type, server, port);

  @override
  String toString() => '$type:$server:$port';
}

/// 当前订阅里各节点的键（节点名 → 键，认不出键的节点值为 null）。应用配置时由 [captureNodeKeys] 更新。
final localNodeKeys = ValueNotifier<Map<String, NodeMatchKey?>>(const {});

/// 从要交给内核的那份配置里记下各节点的键。在 Bettbox 的 `patchRawConfig` 里调（那里手上正好是解析好的整份配置）。
/// 节点没变就不通知——这个函数每次应用配置都会跑。
void captureNodeKeys(Map<String, dynamic> rawConfig) {
  final proxies = rawConfig['proxies'];
  final next = <String, NodeMatchKey?>{};
  if (proxies is List) {
    for (final p in proxies) {
      if (p is! Map) continue;
      final name = p['name']?.toString() ?? '';
      if (name.isNotEmpty) next[name] = NodeMatchKey.ofProxy(p);
    }
  }
  if (!mapEquals(next, localNodeKeys.value)) localNodeKeys.value = next;
}

/// 给本地每个节点找主控那边对应的条目，返回「本地节点名 → 条目」。没找到的不在结果里。
///
/// 1. 名字相同的优先（旧主控、普通订阅都走这条）；同名有多条（一个名字下几个协议）时取键也相同的那条，
///    没有就取最后一条（与按名字建索引时「后写的生效」一致）。
/// 2. 名字对不上，按键找：
///    - 只有一条同键的，就是它；
///    - 同键有多条（同一个 443 靠 SNI 分流的几个入站、父节点与它的路由出站子节点）：改名多半只是在原名前后
///      加东西，挑原名包含在本地名字里的那条，有几条就取原名最长的；
///    - 还挑不出：几条的内容都一样就用第一条，不一样就**不显示**——宁可没有图标，也不显示别的节点的结论。
Map<String, T> resolveNodeExtras<T>({
  required Map<String, NodeMatchKey?> locals,
  required List<T> entries,
  required String Function(T) nameOf,
  required NodeMatchKey? Function(T) keyOf,
  required bool Function(T, T) samePayload,
}) {
  if (locals.isEmpty || entries.isEmpty) return const {};
  final byName = <String, List<T>>{};
  final byKey = <NodeMatchKey, List<T>>{};
  for (final e in entries) {
    byName.putIfAbsent(nameOf(e), () => []).add(e);
    final key = keyOf(e);
    if (key != null) byKey.putIfAbsent(key, () => []).add(e);
  }
  final resolved = <String, T>{};
  locals.forEach((name, key) {
    final sameName = byName[name];
    if (sameName != null && sameName.isNotEmpty) {
      T pick = sameName.last;
      if (key != null) {
        for (final e in sameName) {
          if (keyOf(e) == key) pick = e;
        }
      }
      resolved[name] = pick;
      return;
    }
    final candidates = key == null ? null : byKey[key];
    if (candidates == null || candidates.isEmpty) return;
    if (candidates.length == 1) {
      resolved[name] = candidates.first;
      return;
    }
    final contained = [
      for (final e in candidates)
        if (nameOf(e).isNotEmpty && name.contains(nameOf(e))) e,
    ];
    if (contained.isNotEmpty) {
      final longest = contained.map((e) => nameOf(e).length).reduce((a, b) => a > b ? a : b);
      final best = [
        for (final e in contained)
          if (nameOf(e).length == longest) e,
      ];
      if (best.length == 1 || best.skip(1).every((e) => samePayload(e, best.first))) {
        resolved[name] = best.first;
        return;
      }
    }
    if (candidates.skip(1).every((e) => samePayload(e, candidates.first))) resolved[name] = candidates.first;
  });
  return resolved;
}

/// 界面按本地节点名查用的表：按名字的索引，加上名字对不上、靠键认出来的那些。普通订阅下就是 [byName] 本身。
Map<String, T> nodeExtrasForLocals<T>({
  required Map<String, T> byName,
  required List<T> entries,
  required Map<String, NodeMatchKey?> locals,
  required String Function(T) nameOf,
  required NodeMatchKey? Function(T) keyOf,
  required bool Function(T, T) samePayload,
}) {
  final resolved = resolveNodeExtras(locals: locals, entries: entries, nameOf: nameOf, keyOf: keyOf, samePayload: samePayload);
  final extra = <String, T>{};
  resolved.forEach((name, entry) {
    if (!identical(byName[name], entry)) extra[name] = entry;
  });
  return extra.isEmpty ? byName : {...byName, ...extra};
}
