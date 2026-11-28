import 'package:bett_box/meowx/config/mesh_config.dart';
import 'package:bett_box/meowx/config/mesh_whitelist.dart';
import 'package:bett_box/models/meow.dart';
import 'package:flutter_test/flutter_test.dart';

/// 订阅：一个普通节点、两个喵窝版白名单节点（其中一个自己写了 dialer-proxy）、几个分组与规则。
Map<String, dynamic> _config() => {
  'proxies': [
    {'name': '香港', 'type': 'ss', 'server': 'hk.example.com', 'port': 443},
    {'name': '东京 · 喵窝', 'type': 'vless', 'server': '100.64.0.21', 'port': 443, 'servername': 'jp.example.com', '_mmwx-mesh': true},
    {'name': '首尔 · 喵窝', 'type': 'trojan', 'server': '100.64.0.22', 'port': 443, '_mmwx-mesh': 'true', 'dialer-proxy': '香港'},
    {'name': '链式', 'type': 'ss', 'server': '1.2.3.4', 'port': 8388, 'dialer-proxy': '东京 · 喵窝'},
  ],
  'proxy-groups': [
    {'name': '节点选择', 'type': 'select', 'proxies': ['香港', '东京 · 喵窝', '首尔 · 喵窝']},
    {'name': '只有白名单', 'type': 'url-test', 'proxies': ['东京 · 喵窝', '首尔 · 喵窝']},
    {'name': '带 provider', 'type': 'select', 'proxies': ['东京 · 喵窝'], 'use': ['p1']},
  ],
};

const _rules = ['DOMAIN,jp.example.com,东京 · 喵窝', 'MATCH,节点选择'];

Map<String, dynamic> _node(Map<String, dynamic> raw, String name) =>
    (raw['proxies'] as List).cast<Map<String, dynamic>>().firstWhere((p) => p['name'] == name);

MeowSettings _settings({String token = 't', String? reason = '', bool enabled = true, bool sw = true}) => MeowSettings(
  account: MeowAccount(host: 'https://panel.example.com', token: token),
  mesh: MeowMesh(enabled: enabled, panelReason: reason, whitelistViaMesh: sw),
);

void main() {
  group('运行配置里的白名单节点（规格 B3）', () {
    test('喵窝开着：加 dialer-proxy: 喵窝，已有的不覆盖，去掉私有字段', () {
      final raw = _config();
      final patch = applyMeshWhitelist(raw, List<dynamic>.of(_rules), on: true);
      expect(patch.viaMesh, ['东京 · 喵窝', '首尔 · 喵窝']);
      expect(patch.removed, isEmpty);
      expect(patch.rules, _rules);
      final jp = _node(raw, '东京 · 喵窝');
      expect(jp['dialer-proxy'], meshOutboundName);
      expect(jp.containsKey(meshWhitelistField), isFalse);
      expect(jp['servername'], 'jp.example.com');
      final kr = _node(raw, '首尔 · 喵窝');
      expect(kr['dialer-proxy'], '香港');
      expect(kr.containsKey(meshWhitelistField), isFalse);
      // 普通节点、分组原样
      expect(_node(raw, '香港').containsKey('dialer-proxy'), isFalse);
      expect((raw['proxy-groups'] as List).first['proxies'], ['香港', '东京 · 喵窝', '首尔 · 喵窝']);
    });

    test('喵窝关着：拿掉这些节点、摘掉分组成员（删空补 DIRECT、有 use 的不补）、目标是它们的规则删掉、别的节点的 dialer-proxy 去掉', () {
      final raw = _config();
      final patch = applyMeshWhitelist(raw, List<dynamic>.of(_rules), on: false);
      expect(patch.removed, ['东京 · 喵窝', '首尔 · 喵窝']);
      expect(patch.viaMesh, isEmpty);
      final names = [for (final p in raw['proxies'] as List) p['name']];
      expect(names, ['香港', '链式']);
      expect(_node(raw, '链式').containsKey('dialer-proxy'), isFalse);
      final groups = (raw['proxy-groups'] as List).cast<Map>();
      expect(groups[0]['proxies'], ['香港']);
      expect(groups[1]['proxies'], ['DIRECT']);
      expect(groups[2]['proxies'], isEmpty);
      expect(patch.rules, ['MATCH,节点选择']);
    });

    test('喵窝关着：rules / sub-rules 里目标是拿掉节点的整行删掉（含 AND / OR / NOT），不改成 DIRECT', () {
      final raw = _config()
        ..['sub-rules'] = {
          'sub1': ['DOMAIN-SUFFIX,jp.example.com,东京 · 喵窝', 'NOT,((DOMAIN,a.com)),首尔 · 喵窝', 'MATCH,香港'],
        };
      final rules = [
        'DOMAIN,jp.example.com,东京 · 喵窝',
        'IP-CIDR,100.64.0.0/10,首尔 · 喵窝,no-resolve',
        'AND,((DOMAIN,b.com),(NETWORK,UDP)),东京 · 喵窝',
        'OR,((DOMAIN,c.com),(DOMAIN,d.com)),首尔 · 喵窝,no-resolve',
        'DOMAIN-REGEX,^e\\.com\$,东京 · 喵窝',
        'SUB-RULE,(NETWORK,TCP),sub1',
        'AND,((DOMAIN,f.com),(NETWORK,TCP)),香港',
        'DOMAIN,g.com,节点选择',
        'MATCH,东京 · 喵窝',
      ];
      final patch = applyMeshWhitelist(raw, rules, on: false);
      expect(patch.rules, [
        'SUB-RULE,(NETWORK,TCP),sub1',
        'AND,((DOMAIN,f.com),(NETWORK,TCP)),香港',
        'DOMAIN,g.com,节点选择',
      ]);
      expect((raw['sub-rules'] as Map)['sub1'], ['MATCH,香港']);
      // 传进来的规则列表不动
      expect(rules.length, 9);
    });

    test('规则目标的认法', () {
      expect(ruleTarget('MATCH,x'), 'x');
      expect(ruleTarget('DOMAIN,a.com,x'), 'x');
      expect(ruleTarget('IP-CIDR,1.2.3.0/24,x,no-resolve'), 'x');
      expect(ruleTarget('AND,((DOMAIN,a),(NETWORK,UDP)),x'), 'x');
      expect(ruleTarget('NOT,((DOMAIN,a)),x,no-resolve'), 'x');
      expect(ruleTarget('SUB-RULE,(NETWORK,TCP),sub'), isNull);
      expect(ruleTarget('bad'), isNull);
      expect(ruleTarget('DOMAIN,a.com'), isNull);
    });

    test('没有白名单节点：原样（新的规则列表）', () {
      final raw = {
        'proxies': [
          {'name': 'a', 'type': 'ss', '_mmwx-mesh': false},
        ],
      };
      final rules = List<dynamic>.unmodifiable(_rules);
      for (final on in [true, false]) {
        final patch = applyMeshWhitelist(raw, rules, on: on);
        expect(patch.rules, _rules);
        expect(patch.viaMesh, isEmpty);
        expect(patch.removed, isEmpty);
      }
      expect((raw['proxies'] as List).single['name'], 'a');
      expect(applyMeshWhitelist(<String, dynamic>{}, const [], on: true).rules, isEmpty);
    });

    test('传进来的集合不可改也不报错（改到的都换成新的）', () {
      final raw = <String, dynamic>{
        'proxies': List<dynamic>.unmodifiable([
          Map<String, dynamic>.unmodifiable({'name': 'm', 'type': 'ss', '_mmwx-mesh': true}),
        ]),
        'proxy-groups': List<dynamic>.unmodifiable([
          Map<String, dynamic>.unmodifiable({'name': 'g', 'type': 'select', 'proxies': List<dynamic>.unmodifiable(['m'])}),
        ]),
      };
      applyMeshWhitelist(raw, List<dynamic>.unmodifiable(['MATCH,m']), on: true);
      expect(_node(raw, 'm')['dialer-proxy'], meshOutboundName);
      final raw2 = Map<String, dynamic>.of(raw)..['proxies'] = List<dynamic>.unmodifiable([
        Map<String, dynamic>.unmodifiable({'name': 'm', 'type': 'ss', '_mmwx-mesh': true}),
      ]);
      final patch = applyMeshWhitelist(raw2, List<dynamic>.unmodifiable(['MATCH,m', 'MATCH,g']), on: false);
      expect(raw2['proxies'], isEmpty);
      expect(patch.rules, ['MATCH,g']);
    });

    test('和喵窝注入连在一起：开着时节点经注入的「喵窝」出站', () {
      final raw = _config();
      const mesh = MeshInjection(controlUrl: 'https://c', hostname: 'h');
      final patch = applyMeowNetworking(raw, List<dynamic>.of(_rules), stripTailscale: true, mesh: mesh);
      final wl = applyMeshWhitelist(raw, patch.rules, on: true);
      final names = [for (final p in raw['proxies'] as List) p['name']];
      expect(names, contains(meshOutboundName));
      expect(_node(raw, '东京 · 喵窝')['dialer-proxy'], meshOutboundName);
      expect(wl.rules, _rules);
    });
  });

  group('该不该带 X-MeowX-Mesh、值是什么（规格 B2）', () {
    test('on = 登录着 + 在喵窝名单里 + 喵窝开着 + 开关开着', () {
      expect(meshWhitelistOn(_settings()), isTrue);
      expect(meshWhitelistOn(_settings(token: '')), isFalse);
      expect(meshWhitelistOn(_settings(reason: 'not_admin')), isFalse);
      expect(meshWhitelistOn(_settings(reason: null)), isFalse);
      expect(meshWhitelistOn(_settings(enabled: false)), isFalse);
      expect(meshWhitelistOn(_settings(sw: false)), isFalse);
      // 名单里但主控暂时关了 / 还在启动：账号仍在名单里
      expect(meshWhitelistOn(_settings(reason: 'starting')), isTrue);
    });

    test('名单账号：主控说可用或原因不是 not_admin；没问过 / not_admin 不算', () {
      expect(meshListedAccount(''), isTrue);
      expect(meshListedAccount('disabled'), isTrue);
      expect(meshListedAccount('starting'), isTrue);
      expect(meshListedAccount('not_admin'), isFalse);
      expect(meshListedAccount(null), isFalse);
    });

    test('开关缺省开：老配置没有这个键也算开', () {
      expect(const MeowMesh().whitelistViaMesh, isTrue);
      expect(MeowMesh.fromJson({'enabled': true}).whitelistViaMesh, isTrue);
      expect(MeowMesh.fromJson({'whitelistViaMesh': false}).whitelistViaMesh, isFalse);
    });

    test('只给本主控的订阅：同主机、实时通道指向本主控、或主控订阅路径样子（没有实时通道地址时）', () {
      const base = 'https://panel.example.com';
      expect(isOwnPanelSubscription('https://panel.example.com/api/clash/subscribe?token=x', base), isTrue);
      expect(isOwnPanelSubscription('https://PANEL.example.com:443/whatever', base), isTrue);
      // 订阅域名：主控给的实时通道地址是本主控
      expect(isOwnPanelSubscription('https://sub.cdn.net/abc', base, realtimeBase: 'https://panel.example.com'), isTrue);
      // 订阅域名、还没有应答头：路径像主控订阅
      expect(isOwnPanelSubscription('https://sub.cdn.net/x/AbCd', base), isTrue);
      expect(isOwnPanelSubscription('https://sub.cdn.net/api/user/package-subscribe?assignment_id=3', base), isTrue);
      expect(isOwnPanelSubscription('https://sub.cdn.net/api/subscribe/', base), isTrue);
      // 别的妙妙屋X 主控（应答头指向它）：不算
      expect(isOwnPanelSubscription('https://other.net/x/AbCd', base, realtimeBase: 'https://other.net'), isFalse);
      // 别家机场
      expect(isOwnPanelSubscription('https://airport.example.org/link/abc?clash=1', base), isFalse);
      // 没登录过主控 / 地址坏了
      expect(isOwnPanelSubscription('https://panel.example.com/x/a', ''), isFalse);
      expect(isOwnPanelSubscription('not a url', base), isFalse);
      expect(isOwnPanelSubscription('', base), isFalse);
    });

    test('请求头：本主控的订阅加 on / off，别家原样，不改传进来的那份', () {
      expect(withMeshSubscriptionHeader(null, own: true, on: true), {meshSubscriptionHeader: 'on'});
      expect(withMeshSubscriptionHeader(null, own: true, on: false), {meshSubscriptionHeader: 'off'});
      expect(withMeshSubscriptionHeader(null, own: false, on: true), isNull);
      const push = {'mmwx-refresh': 'push'};
      expect(withMeshSubscriptionHeader(push, own: false, on: true), same(push));
      final merged = withMeshSubscriptionHeader(push, own: true, on: true);
      expect(merged, {'mmwx-refresh': 'push', 'X-MeowX-Mesh': 'on'});
      expect(push, {'mmwx-refresh': 'push'});
    });

    test('节点认法：true 或字符串 true', () {
      expect(isMeshWhitelistNode({'_mmwx-mesh': true}), isTrue);
      expect(isMeshWhitelistNode({'_mmwx-mesh': 'TRUE'}), isTrue);
      expect(isMeshWhitelistNode({'_mmwx-mesh': false}), isFalse);
      expect(isMeshWhitelistNode({'_mmwx-mesh': 1}), isFalse);
      expect(isMeshWhitelistNode({'name': 'a'}), isFalse);
      expect(isMeshWhitelistNode('x'), isFalse);
    });
  });
}
