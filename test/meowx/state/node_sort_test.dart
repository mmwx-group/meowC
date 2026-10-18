import 'package:bett_box/enum/enum.dart';
import 'package:bett_box/meowx/state/node_sort.dart';
import 'package:bett_box/models/models.dart';
import 'package:flutter_test/flutter_test.dart';

List<Proxy> _proxies(Iterable<String> names) => [for (final n in names) Proxy(name: n, type: 'Vless')];

List<String> _names(List<Proxy> nodes) => [for (final p in nodes) p.name];

void main() {
  test('默认：原样返回，不拷贝', () {
    final nodes = _proxies(['b', 'a']);
    expect(identical(sortNodes(nodes, ProxiesSortType.none), nodes), isTrue);
  });

  test('延迟：有读数的从低到高，没测过 / 测试中的按原顺序接在后面，超时（<0 或 ≥100000）垫底', () {
    const ms = <String, int?>{'超时': -1, '慢': 300, '没测': null, '快': 20, '测试中': 0, '离谱': 100000, '中': 120};
    final sorted = sortNodes(_proxies(ms.keys), ProxiesSortType.delay, delayOf: (p) => ms[p.name]);
    expect(_names(sorted), ['快', '中', '慢', '没测', '测试中', '超时', '离谱']);
  });

  test('延迟相同：保持原顺序（稳定）', () {
    const ms = <String, int?>{'c': 50, 'a': 50, 'b': 50, 'd': 10};
    final sorted = sortNodes(_proxies(ms.keys), ProxiesSortType.delay, delayOf: (p) => ms[p.name]);
    expect(_names(sorted), ['d', 'c', 'a', 'b']);
  });

  test('名称：中文按拼音、数字按数值、不分大小写；比不出先后的保持原顺序', () {
    final sorted = sortNodes(
      _proxies(['香港 10', '美国 01', 'hk 2', '香港 2', '日本 01', 'HK 10', '节点 A', '香港 02', '节点 a']),
      ProxiesSortType.name,
    );
    expect(_names(sorted), ['hk 2', 'HK 10', '节点 A', '节点 a', '美国 01', '日本 01', '香港 2', '香港 02', '香港 10']);
  });

  test('自然顺序：数字段按数值比，数值相同时位数少的在前', () {
    expect(compareNatural('node2', 'node10'), lessThan(0));
    expect(compareNatural('node10', 'node2'), greaterThan(0));
    expect(compareNatural('node', 'node1'), lessThan(0));
    expect(compareNatural('node1', 'node01'), lessThan(0));
    expect(compareNatural('node01', 'node01'), 0);
    expect(compareNatural('a9b', 'a10a'), lessThan(0));
  });
}
