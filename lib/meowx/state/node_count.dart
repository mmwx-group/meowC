import 'package:bett_box/providers/providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../theme/badges.dart';

/// 叶子节点数（去重）：当前模式下可见组的全部成员，去掉嵌套的组。侧栏「节点」角标用它。
/// 和节点页标题「N 个节点」（proxies_page.dart 的 allLeafProxies）同一口径，有测试盯着两边一致。
///
/// 做成 provider 是为了代理组变一次只数一次：写在 widget 里的 `.select(...)` 每次 build 都是新的 selector、
/// 都会把「全部组 × 全部成员」重数一遍，而侧栏以前跟着连接数每秒重建。
final leafNodeCountProvider = Provider.autoDispose<int>((ref) {
  final seen = <String>{};
  for (final g in ref.watch(currentGroupsStateProvider).value) {
    for (final p in g.all) {
      if (!isGroupType(p.type)) seen.add(p.name);
    }
  }
  return seen.length;
});
