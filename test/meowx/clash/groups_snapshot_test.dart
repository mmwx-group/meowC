import 'dart:async';
import 'dart:convert';
import 'dart:isolate';

import 'package:bett_box/clash/core.dart';
import 'package:bett_box/clash/interface.dart';
import 'package:bett_box/enum/enum.dart';
import 'package:bett_box/models/models.dart';
import 'package:flutter_test/flutter_test.dart';

// 代理组刷新的两段：核心回包原样（不在 UI isolate 解码）交到调用方；worker 里解包、建组、算内容摘要。

/// mihomo 给每个节点 / 组带的一堆界面用不到的字段（延迟历史等），解析时应当被丢掉。
Map<String, dynamic> _node(String name, String type, {String? now, List<String>? all, Map<String, dynamic>? more}) => {
  'name': name,
  'type': type,
  'alive': true,
  'udp': true,
  'history': [
    {'time': '2026-10-08T00:00:00Z', 'delay': 42},
  ],
  'extra': <String, dynamic>{},
  'now': ?now,
  'all': ?all,
  ...?more,
};

Map<String, dynamic> _proxies({String selected = '香港 01', String auto = '东京 01', bool? hidden}) => {
  'DIRECT': _node('DIRECT', 'Direct'),
  'REJECT': _node('REJECT', 'Reject'),
  '香港 01': _node('香港 01', 'Vless'),
  '东京 01': _node('东京 01', 'Trojan'),
  'GLOBAL': _node('GLOBAL', 'Selector', now: '节点选择', all: ['节点选择', '自动选择', '香港 01', '东京 01', 'DIRECT', '不存在的节点']),
  '节点选择': _node(
    '节点选择',
    'Selector',
    now: selected,
    all: ['自动选择', '香港 01', '东京 01', 'DIRECT'],
    more: {'icon': 'https://example.com/a.png', 'hidden': ?hidden},
  ),
  '自动选择': _node(
    '自动选择',
    'URLTest',
    now: auto,
    all: ['香港 01', '东京 01'],
    more: {'testUrl': 'https://test.example/204'},
  ),
};

/// 核心回包的原样：Go 按结构体字段顺序输出 id、method、data、code、Port。
String _envelope(Map<String, dynamic> data, {String id = 'getProxies#1759900000000000abcdefgh'}) =>
    '{"id":"$id","method":"getProxies","data":${json.encode(data)},"code":0,"Port":0}';

class _FakeCore extends ClashHandlerInterface {
  final sent = <Map<String, dynamic>>[];

  @override
  void sendMessage(String message) => sent.add(json.decode(message) as Map<String, dynamic>);

  @override
  Future<bool> preload() async => true;

  @override
  FutureOr<void> reStart() {}

  @override
  FutureOr<bool> destroy() => true;
}

void main() {
  group('parseGroupsSnapshot', () {
    test('GLOBAL 打头，后面按 GLOBAL.all 的顺序列出其中的组；成员只留 name / type / now', () {
      final snapshot = parseGroupsSnapshot(_envelope(_proxies()));

      expect(snapshot.groups.map((g) => g.name), ['GLOBAL', '节点选择', '自动选择']);
      final global = snapshot.groups[0];
      expect(global.type, GroupType.Selector);
      expect(global.now, '节点选择');
      // 配置里引用了但核心没有的名字跳过
      expect(global.all.map((p) => p.name), ['节点选择', '自动选择', '香港 01', '东京 01', 'DIRECT']);
      expect(global.all.first, const Proxy(name: '节点选择', type: 'Selector', now: '香港 01'));

      final select = snapshot.groups[1];
      expect(select.icon, 'https://example.com/a.png');
      expect(select.hidden, isNull);
      expect(select.all, const [
        Proxy(name: '自动选择', type: 'URLTest', now: '东京 01'),
        Proxy(name: '香港 01', type: 'Vless'),
        Proxy(name: '东京 01', type: 'Trojan'),
        Proxy(name: 'DIRECT', type: 'Direct'),
      ]);

      final auto = snapshot.groups[2];
      expect(auto.type, GroupType.URLTest);
      expect(auto.now, '东京 01');
      expect(auto.testUrl, 'https://test.example/204');
    });

    test('同一个节点在各组里是同一个 Proxy 实例', () {
      final groups = parseGroupsSnapshot(_envelope(_proxies())).groups;
      Proxy pick(Group g) => g.all.firstWhere((p) => p.name == '香港 01');
      expect(identical(pick(groups[0]), pick(groups[1])), isTrue);
      expect(identical(pick(groups[1]), pick(groups[2])), isTrue);
    });

    test('空表 / 没有 GLOBAL / GLOBAL 没有成员 → 空快照', () {
      expect(parseGroupsSnapshot(_envelope({})).groups, isEmpty);
      expect(parseGroupsSnapshot(_envelope({'DIRECT': _node('DIRECT', 'Direct')})).groups, isEmpty);
      expect(parseGroupsSnapshot(_envelope({'GLOBAL': _node('GLOBAL', 'Selector')})).groups, isEmpty);
      expect(parseGroupsSnapshot('{"data":null}').groups, isEmpty);
    });

    test('外部 provider 的节点并进来（原名 + 带 [provider] 后缀两个名字）；给原始 JSON 与给对象结果一样', () {
      final proxies = _proxies()
        ..['自动选择'] = _node('自动选择', 'URLTest', now: '机场 A', all: ['机场 A', '机场 B[air]', '香港 01']);
      final providersJson = [
        {
          'name': 'air',
          'type': 'Proxy',
          'count': 2,
          'vehicle-type': 'HTTP',
          'update-at': '2026-10-08T00:00:00Z',
          'proxies': [_node('机场 A', 'Vmess'), _node('机场 B', 'Hysteria2')],
        },
        // 规则 provider 之类没有 proxies 的条目
        {'name': 'rules', 'type': 'Rule', 'count': 0, 'vehicle-type': 'HTTP', 'update-at': '2026-10-08T00:00:00Z'},
      ];

      final fromRaw = parseGroupsSnapshot(_envelope(proxies), providersRaw: json.encode(providersJson));
      expect(fromRaw.groups[2].all, const [
        Proxy(name: '机场 A', type: 'Vmess'),
        Proxy(name: '机场 B', type: 'Hysteria2'),
        Proxy(name: '香港 01', type: 'Vless'),
      ]);

      final fromObjects = parseGroupsSnapshot(
        _envelope(proxies),
        providers: providersJson.map(ExternalProvider.fromJson).toList(),
      );
      expect(fromObjects.groups, fromRaw.groups);
      expect(fromObjects.digest, fromRaw.digest);
    });
  });

  group('groupsDigest', () {
    final base = parseGroupsSnapshot(_envelope(_proxies()));

    test('内容相同 → 摘要相同（与请求 id、节点的延迟历史无关），换一个 isolate 算也一样', () async {
      final proxies = _proxies();
      (proxies['香港 01'] as Map)['history'] = [
        {'time': '2026-10-08T01:00:00Z', 'delay': 999},
      ];
      final again = parseGroupsSnapshot(_envelope(proxies, id: 'getProxies#1759900060000000zzzzzzzz'));
      expect(again.groups, base.groups);
      expect(again.digest, base.digest);

      // 每次刷新都在一个新的 worker isolate 里算：两个 isolate 的结果必须对得上
      final raw = _envelope(_proxies());
      final a = await Isolate.run(() => parseGroupsSnapshot(raw));
      final b = await Isolate.run(() => parseGroupsSnapshot(raw));
      expect(a.groups, base.groups);
      expect(a.digest, base.digest);
      expect(b.digest, base.digest);
    });

    test('界面用到的任何字段变了，摘要都变', () {
      final g = base.groups;
      List<Group> withGroup(int i, Group Function(Group) change) => [...g]..[i] = change(g[i]);
      final variants = <String, List<Group>>{
        '组的 now': withGroup(1, (x) => x.copyWith(now: '东京 01')),
        '组的 now 置空': withGroup(1, (x) => x.copyWith(now: null)),
        '组的 now 空串': withGroup(1, (x) => x.copyWith(now: '')),
        '组名': withGroup(1, (x) => x.copyWith(name: '节点选择 2')),
        '组类型': withGroup(2, (x) => x.copyWith(type: GroupType.Fallback)),
        'hidden': withGroup(1, (x) => x.copyWith(hidden: true)),
        'hidden=false': withGroup(1, (x) => x.copyWith(hidden: false)),
        'testUrl': withGroup(2, (x) => x.copyWith(testUrl: 'https://other.example/204')),
        'icon': withGroup(1, (x) => x.copyWith(icon: '')),
        '少一个成员': withGroup(1, (x) => x.copyWith(all: x.all.sublist(1))),
        '成员换顺序': withGroup(1, (x) => x.copyWith(all: x.all.reversed.toList())),
        '成员类型': withGroup(2, (x) => x.copyWith(all: [x.all[0].copyWith(type: 'Vmess'), x.all[1]])),
        '成员的 now': withGroup(1, (x) => x.copyWith(all: [x.all[0].copyWith(now: '香港 01'), ...x.all.skip(1)])),
        '少一个组': g.sublist(0, 2),
        '组换顺序': [g[0], g[2], g[1]],
        // 成员挪到相邻的组里：总的字符序列不变，靠组边界区分
        '成员跨组': [g[0], g[1].copyWith(all: g[1].all.sublist(0, 3)), g[2].copyWith(all: [g[1].all[3], ...g[2].all])],
      };
      final digests = {'原样': base.digest};
      variants.forEach((name, groups) {
        expect(groups, isNot(g), reason: name);
        digests[name] = groupsDigest(groups);
      });
      // 两两不同
      expect(digests.values.toSet().length, digests.length, reason: '$digests');
    });

    test('摘要覆盖模型的全部字段：Group / Proxy 加了字段要同步改 groupsDigest', () {
      expect(base.groups.first.toJson().keys.toSet(), {'type', 'all', 'now', 'hidden', 'testUrl', 'icon', 'name'});
      expect(base.groups.first.all.first.toJson().keys.toSet(), {'name', 'type', 'now'});
    });
  });

  group('核心回包的分发（handleMessage 里 getProxies 的快路径）', () {
    test('getProxies 的回包原样交回：不解码、按 id 配对，交完就不再留着', () async {
      final core = _FakeCore();
      final pending = core.getProxies();
      final id = core.sent.single['id'] as String;
      expect(id, startsWith('getProxies#'));

      final raw = _envelope(_proxies(), id: id);
      core.handleMessage(raw);
      expect(identical(await pending, raw), isTrue);
      expect(core.callbackCompleterMap, isNot(contains(id)));
      expect(parseGroupsSnapshot(raw).groups, hasLength(3));

      // 没人等的回包（已超时被清掉）直接丢掉，不报错
      core.handleMessage(_envelope(_proxies(), id: 'getProxies#gone'));
    });

    test('回包对不上快路径的前缀（字段顺序 / 空白变了）时退回整包解码，解析结果不变', () async {
      final core = _FakeCore();
      final pending = core.getProxies();
      final id = core.sent.single['id'] as String;

      core.handleMessage(json.encode({'method': 'getProxies', 'id': id, 'code': 0, 'data': _proxies()}));
      final snapshot = parseGroupsSnapshot(await pending);
      final expected = parseGroupsSnapshot(_envelope(_proxies()));
      expect(snapshot.groups, expected.groups);
      expect(snapshot.digest, expected.digest);
    });

    test('其它回包照旧整包解码', () async {
      final core = _FakeCore();
      final mode = core.getMode();
      core.handleMessage(json.encode({'id': core.sent.single['id'], 'method': 'getMode', 'data': 'rule', 'code': 0}));
      expect(await mode, 'rule');
    });
  });
}
