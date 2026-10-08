import 'package:bett_box/enum/enum.dart';
import 'package:bett_box/meowx/pages/proxies/proxies_page.dart' show allLeafProxies;
import 'package:bett_box/meowx/state/node_count.dart';
import 'package:bett_box/models/models.dart';
import 'package:bett_box/providers/providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

const _nodes = [
  Proxy(name: '香港 01', type: 'Vless'),
  Proxy(name: '东京 01', type: 'Hysteria2'),
  Proxy(name: '新加坡 01', type: 'Trojan'),
  Proxy(name: '洛杉矶 01', type: 'Miu'),
];

final _groups = [
  // 成员里有嵌套的组（不算节点）和内置策略（算）
  Group(
    name: '节点选择',
    type: GroupType.Selector,
    all: [const Proxy(name: '自动选择', type: 'URLTest'), ..._nodes.take(2), const Proxy(name: 'DIRECT', type: 'Direct')],
  ),
  // 和上一个组重复的节点只数一次
  const Group(name: '自动选择', type: GroupType.URLTest, all: _nodes),
  Group(name: '故障转移', type: GroupType.Fallback, all: [const Proxy(name: '节点选择', type: 'Selector'), _nodes.last]),
];

final _input = StateProvider<List<Group>>((ref) => _groups);

void main() {
  test('leafNodeCountProvider：和节点页标题同一口径（allLeafProxies），代理组不变就不重算', () {
    final container = ProviderContainer(
      overrides: [currentGroupsStateProvider.overrideWith((ref) => GroupsState(value: ref.watch(_input)))],
    );
    addTearDown(container.dispose);
    final seen = <int>[];
    container.listen(leafNodeCountProvider, (_, next) => seen.add(next), fireImmediately: true);

    // 4 个节点 + DIRECT；两个嵌套的组不算
    expect(seen, [5]);
    expect(container.read(leafNodeCountProvider), allLeafProxies(_groups).length);

    // 组变了才重算；数没变不通知
    container.read(_input.notifier).state = [_groups[1], _groups[0], _groups[2]];
    expect(container.read(leafNodeCountProvider), 5);
    expect(seen, [5]);

    final fewer = [_groups[2]];
    container.read(_input.notifier).state = fewer;
    expect(container.read(leafNodeCountProvider), allLeafProxies(fewer).length);
    expect(seen, [5, 1]);

    container.read(_input.notifier).state = const [];
    expect(container.read(leafNodeCountProvider), 0);
  });
}
