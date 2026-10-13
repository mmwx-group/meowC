import 'package:bett_box/meowx/panel/models.dart';
import 'package:bett_box/meowx/panel/node_match.dart';
import 'package:flutter_test/flutter_test.dart';

/// 奖牌 / 解锁认节点：先按名字，名字对不上（主控的套餐订阅会改名）再按 type / server / port。
class _Entry {
  const _Entry(this.name, this.payload, [this.key]);
  final String name;
  final String payload;
  final NodeMatchKey? key;
}

NodeMatchKey? _key(String type, String server, int port) => NodeMatchKey.of(type: type, server: server, port: port);

Map<String, _Entry> _resolve(Map<String, NodeMatchKey?> locals, List<_Entry> entries) => resolveNodeExtras<_Entry>(
      locals: locals,
      entries: entries,
      nameOf: (e) => e.name,
      keyOf: (e) => e.key,
      samePayload: (a, b) => a.payload == b.payload,
    );

void main() {
  test('键的归一：type / server 不分大小写、去空白；三项缺一不成键', () {
    expect(NodeMatchKey.of(type: ' VLESS ', server: 'Node.Example.com', port: 443), _key('vless', 'node.example.com', 443));
    expect(NodeMatchKey.of(type: 'vless', server: 'a.com', port: '8443'), _key('vless', 'a.com', 8443));
    expect(NodeMatchKey.of(type: 'vless', server: 'a.com', port: null), isNull);
    expect(NodeMatchKey.of(type: 'vless', server: 'a.com', port: 0), isNull);
    expect(NodeMatchKey.of(type: null, server: 'a.com', port: 443), isNull);
    expect(NodeMatchKey.of(type: 'vless', server: ' ', port: 443), isNull);
  });

  test('订阅里的节点：取 type / server / port；mieru 只写 port-range 时取范围起点', () {
    expect(NodeMatchKey.ofProxy({'name': 'a', 'type': 'vless', 'server': 'A.example.com', 'port': 443}), _key('vless', 'a.example.com', 443));
    expect(NodeMatchKey.ofProxy({'name': 'm', 'type': 'mieru', 'server': '1.2.3.4', 'port-range': '20000-20100'}), _key('mieru', '1.2.3.4', 20000));
    expect(NodeMatchKey.ofProxy({'name': 'x', 'type': 'vless'}), isNull);
  });

  test('应用配置时记下各节点的键；节点没变不通知', () {
    localNodeKeys.value = const {};
    var notified = 0;
    void listener() => notified++;
    localNodeKeys.addListener(listener);
    addTearDown(() {
      localNodeKeys.removeListener(listener);
      localNodeKeys.value = const {};
    });
    final raw = <String, dynamic>{
      'proxies': [
        {'name': '香港 01', 'type': 'vless', 'server': 'hk.example.com', 'port': 443},
        {'name': '没有端口', 'type': 'vless', 'server': 'x.example.com'},
        'not-a-map',
      ],
    };
    captureNodeKeys(raw);
    expect(localNodeKeys.value, {'香港 01': _key('vless', 'hk.example.com', 443), '没有端口': null});
    expect(notified, 1);
    captureNodeKeys(raw);
    expect(notified, 1);
    captureNodeKeys(<String, dynamic>{});
    expect(localNodeKeys.value, isEmpty);
    expect(notified, 2);
  });

  test('名字相同直接用；旧主控不带键也照常；名字和键都对不上不显示', () {
    const entries = [_Entry('香港 01', 'gold')];
    expect(_resolve({'香港 01': _key('vless', 'hk.example.com', 443)}, entries)['香港 01']?.payload, 'gold');
    expect(_resolve({'别的': _key('vless', 'x.example.com', 443)}, entries), isEmpty);
  });

  test('套餐订阅改了名（倍率前缀 / 流量到期尾缀 / 套餐内名称）：按键认出来', () {
    final entries = [
      _Entry('香港 01', 'gold', _key('vless', 'hk.example.com', 443)),
      _Entry('日本 01', 'silver', _key('trojan', 'jp.example.com', 2053)),
    ];
    final resolved = _resolve({
      '「2」香港 01 87.5GB📊 30天⏳': _key('vless', 'HK.example.com', 443),
      '东京精品线路': _key('trojan', 'jp.example.com', 2053),
      '美国 01': _key('vless', 'us.example.com', 443),
    }, entries);
    expect(resolved['「2」香港 01 87.5GB📊 30天⏳']?.payload, 'gold');
    expect(resolved['东京精品线路']?.payload, 'silver');
    expect(resolved.containsKey('美国 01'), isFalse);
  });

  test('同一个名字下几个协议：取键也相同的那条', () {
    final entries = [
      _Entry('香港 01', 'from-vless', _key('vless', 'hk.example.com', 443)),
      _Entry('香港 01', 'from-anytls', _key('anytls', 'hk.example.com', 8443)),
    ];
    final resolved = _resolve({
      '香港 01': _key('vless', 'hk.example.com', 443),
      '香港 01 (2)': _key('anytls', 'hk.example.com', 8443),
    }, entries);
    expect(resolved['香港 01']?.payload, 'from-vless');
    expect(resolved['香港 01 (2)']?.payload, 'from-anytls');
  });

  test('键撞了：按原名包含关系挑，挑不出且内容不同就不显示', () {
    final key = _key('vless', 'hk.example.com', 443);
    final parent = _Entry('香港 01', 'host', key);
    final child = _Entry('香港 01-落地美国', 'us-exit', key);
    final decorated = _resolve({'「2」香港 01 30天⏳': key, '「2」香港 01-落地美国 30天⏳': key}, [parent, child]);
    expect(decorated['「2」香港 01 30天⏳']?.payload, 'host');
    expect(decorated['「2」香港 01-落地美国 30天⏳']?.payload, 'us-exit');
    // 套餐内名称把名字整个换了：认不出是哪条，内容又不同 → 不显示
    expect(_resolve({'精品线路': key}, [parent, child]), isEmpty);
    // 内容相同（同一台机器上的两个入站）：用哪条都对
    expect(_resolve({'精品线路': key}, [parent, _Entry('香港 01-备用', 'host', key)])['精品线路']?.payload, 'host');
  });

  test('界面用的表：普通订阅下就是按名字的索引本身；改过名的节点补进去', () {
    final hk = NodeMedal(name: '香港 01', medal: 'gold', routes: const [], key: _key('vless', 'hk.example.com', 443));
    final byName = NodeMedal.index([hk]);
    Map<String, NodeMedal> table(Map<String, NodeMatchKey?> locals) => nodeExtrasForLocals<NodeMedal>(
          byName: byName,
          entries: [hk],
          locals: locals,
          nameOf: (m) => m.name,
          keyOf: (m) => m.key,
          samePayload: (a, b) => a.samePayload(b),
        );
    expect(identical(table({'香港 01': _key('vless', 'hk.example.com', 443)}), byName), isTrue);
    final renamed = table({'「2」香港 01': _key('vless', 'hk.example.com', 443)});
    expect(renamed['「2」香港 01']?.medal, 'gold');
    expect(renamed['香港 01']?.medal, 'gold');
  });

  test('主控回包：新版带 type / server / port，旧版不带也解得出；同名的几个协议都保留', () {
    final list = NodeMedal.parseList({
      'success': true,
      'nodes': [
        {'name': '香港 01', 'type': 'vless', 'server': 'HK.example.com', 'port': 443, 'medal': 'gold', 'routes': []},
        {'name': '香港 01', 'type': 'anytls', 'server': 'hk.example.com', 'port': 8443, 'medal': 'gold', 'routes': []},
        {'name': '旧主控', 'medal': 'silver', 'routes': []},
      ],
    });
    expect(list.map((m) => m.key).toList(), [_key('vless', 'hk.example.com', 443), _key('anytls', 'hk.example.com', 8443), null]);
    expect(NodeMedal.index(list).keys, ['香港 01', '旧主控']);
    final unlocks = NodeUnlocks.parseList({
      'success': true,
      'nodes': [
        {'name': '香港 01', 'type': 'vless', 'server': 'hk.example.com', 'port': '443', 'unlocks': [{'service': 'netflix', 'status': 'yes'}]},
        {'name': '空的', 'type': 'vless', 'server': 'x.example.com', 'port': 443, 'unlocks': []},
      ],
    });
    expect(unlocks.length, 1);
    expect(unlocks.single.key, _key('vless', 'hk.example.com', 443));
  });
}
