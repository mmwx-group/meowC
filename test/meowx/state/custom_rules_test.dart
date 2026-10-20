import 'dart:convert';

import 'package:bett_box/meowx/config/meow_patch.dart';
import 'package:bett_box/meowx/pages/settings/custom_rules_page.dart';
import 'package:bett_box/meowx/state/custom_rules.dart';
import 'package:bett_box/meowx/state/overrides.dart';
import 'package:bett_box/meowx/state/status.dart';
import 'package:bett_box/models/meow.dart';
import 'package:bett_box/providers/providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

const _d = MeowRuleAction.direct, _p = MeowRuleAction.proxy, _r = MeowRuleAction.reject;

MeowCustomRule _rule(String v, MeowRuleMatch m, MeowRuleAction a) => MeowCustomRule(value: v, match: m, action: a);

class _CurrentId extends CurrentProfileId {
  _CurrentId(this.initial);
  final String? initial;

  @override
  String? build() => initial;

  @override
  void onUpdate(String? value) {}
}

void main() {
  group('normalizeCustomRuleHost', () {
    test('整条链接：去协议头 / 用户名 / 端口 / 路径 / 查询，小写、去尾点', () {
      expect(normalizeCustomRuleHost('https://user:pw@WWW.Example.COM.:8443/a/b?q=1#f'), (value: 'www.example.com', ip: false, suffixHint: false));
      expect(normalizeCustomRuleHost('  example.com/path  '), (value: 'example.com', ip: false, suffixHint: false));
      expect(normalizeCustomRuleHost('example.com:443'), (value: 'example.com', ip: false, suffixHint: false));
      expect(normalizeCustomRuleHost('localhost'), (value: 'localhost', ip: false, suffixHint: false));
    });
    test('+. / . 前缀 = 想要含子域名；剥掉前缀是 IP 的按单个 IP 算', () {
      expect(normalizeCustomRuleHost('+.Example.com'), (value: 'example.com', ip: false, suffixHint: true));
      expect(normalizeCustomRuleHost('.example.com'), (value: 'example.com', ip: false, suffixHint: true));
      expect(normalizeCustomRuleHost('+.1.2.3.4'), (value: '1.2.3.4', ip: true, suffixHint: false));
      expect(normalizeCustomRuleHost('.1.2.3.4'), (value: '1.2.3.4', ip: true, suffixHint: false));
      expect(normalizeCustomRuleHost('+.2001:DB8::1'), (value: '2001:db8::1', ip: true, suffixHint: false));
    });
    test('标签可以带下划线（同 iOS）', () {
      expect(normalizeCustomRuleHost('_dmarc.Foo_Bar.example.com'), (value: '_dmarc.foo_bar.example.com', ip: false, suffixHint: false));
      expect(normalizeCustomRuleHost('+.foo_bar.example.com'), (value: 'foo_bar.example.com', ip: false, suffixHint: true));
    });
    test('IP：v4 带端口、v6 方括号 / 裸地址；v6 统一成标准写法，IPv4-mapped 转成 IPv4', () {
      expect(normalizeCustomRuleHost('http://1.2.3.4:80/x'), (value: '1.2.3.4', ip: true, suffixHint: false));
      expect(normalizeCustomRuleHost('[2001:DB8::1]:443'), (value: '2001:db8::1', ip: true, suffixHint: false));
      expect(normalizeCustomRuleHost('2001:db8::1'), (value: '2001:db8::1', ip: true, suffixHint: false));
      expect(normalizeCustomRuleHost('2001:0db8::1'), (value: '2001:db8::1', ip: true, suffixHint: false));
      expect(normalizeCustomRuleHost('2001:db8:0:0:0:0:0:1'), (value: '2001:db8::1', ip: true, suffixHint: false));
      expect(normalizeCustomRuleHost('::ffff:1.2.3.4'), (value: '1.2.3.4', ip: true, suffixHint: false));
      expect(normalizeCustomRuleHost('[::FFFF:0102:0304]:443'), (value: '1.2.3.4', ip: true, suffixHint: false));
    });
    test('不合法：空 / 通配符 / 非法字符 / CIDR / 带 zone 的 v6 / 没闭合的方括号 / 非 ASCII', () {
      for (final s in [
        '',
        '   ',
        'https://',
        '+.',
        '*.example.com',
        '+.*.example.com',
        'a.*.com',
        'exa mple.com',
        'a..com',
        '10.0.0.0/8',
        'fe80::1%en0',
        '[2001:db8::1',
        'bücher.de',
      ]) {
        expect(normalizeCustomRuleHost(s), isNull, reason: s);
      }
    });
  });

  group('resolveMainProxyGroup', () {
    final groups = [
      {'name': '自动选择', 'type': 'url-test'},
      {'name': '节点选择', 'type': 'select'},
      {'name': '漏网之鱼', 'type': 'select'},
    ];
    test('MATCH 指向的组', () {
      expect(resolveMainProxyGroup(groups, ['DOMAIN,a.com,DIRECT', 'MATCH,漏网之鱼']), '漏网之鱼');
      expect(resolveMainProxyGroup(groups, [' MATCH , 自动选择 ']), '自动选择');
      expect(resolveMainProxyGroup(groups, ['MATCH,GLOBAL']), 'GLOBAL');
    });
    test('MATCH 指向 DIRECT / REJECT、不存在的组，或没有 MATCH → 第一个 select 组', () {
      expect(resolveMainProxyGroup(groups, ['MATCH,DIRECT']), '节点选择');
      expect(resolveMainProxyGroup(groups, ['MATCH,REJECT']), '节点选择');
      expect(resolveMainProxyGroup(groups, ['MATCH,不存在的组']), '节点选择');
      expect(resolveMainProxyGroup(groups, ['DOMAIN,a.com,DIRECT']), '节点选择');
      expect(resolveMainProxyGroup(groups, null), '节点选择');
      // 只看第一条兜底
      expect(resolveMainProxyGroup(groups, ['MATCH,DIRECT', 'MATCH,漏网之鱼']), '节点选择');
    });
    test('没有 select 组 → 名叫 GLOBAL 的组，否则第一个组；一个组都没有 → null（不落到内置 GLOBAL）', () {
      expect(resolveMainProxyGroup([{'name': '自动', 'type': 'url-test'}, {'name': 'GLOBAL', 'type': 'fallback'}], const []), 'GLOBAL');
      expect(resolveMainProxyGroup([{'name': '自动', 'type': 'url-test'}], const []), '自动');
      expect(resolveMainProxyGroup(const [], const ['MATCH,DIRECT']), isNull);
      expect(resolveMainProxyGroup(const [], const ['MATCH,节点A']), isNull);
      expect(resolveMainProxyGroup('不是列表', 42), isNull);
    });
  });

  group('规则生成', () {
    test('DOMAIN / DOMAIN-SUFFIX / IP-CIDR(6) no-resolve，代理走主代理组；存坏的、不是标准写法的值跳过', () {
      expect(
        customRuleLines([
          _rule('a.example.com', MeowRuleMatch.domain, _d),
          _rule('example.org', MeowRuleMatch.suffix, _p),
          _rule('foo_bar.example.com', MeowRuleMatch.suffix, _d),
          _rule('1.2.3.4', MeowRuleMatch.ip, _r),
          _rule('2001:db8::1', MeowRuleMatch.ip, _p),
          _rule('Bad Value', MeowRuleMatch.suffix, _d),
          _rule('10.0.0.0/8', MeowRuleMatch.ip, _d),
          _rule('1.2.3.4', MeowRuleMatch.suffix, _d),
          _rule('example.com', MeowRuleMatch.ip, _d),
          _rule('2001:0db8::1', MeowRuleMatch.ip, _d),
          _rule('::ffff:1.2.3.4', MeowRuleMatch.ip, _d),
        ], '节点选择'),
        [
          'DOMAIN,a.example.com,DIRECT',
          'DOMAIN-SUFFIX,example.org,节点选择',
          'DOMAIN-SUFFIX,foo_bar.example.com,DIRECT',
          'IP-CIDR,1.2.3.4/32,REJECT,no-resolve',
          'IP-CIDR6,2001:db8::1/128,节点选择,no-resolve',
        ],
      );
    });

    test('没有主代理组：「代理」规则不生成（交给订阅规则），直连 / 拒绝照常', () {
      expect(
        customRuleLines([
          _rule('a.com', MeowRuleMatch.suffix, _p),
          _rule('b.com', MeowRuleMatch.suffix, _d),
          _rule('1.2.3.4', MeowRuleMatch.ip, _p),
          _rule('c.com', MeowRuleMatch.domain, _r),
        ], null),
        ['DOMAIN-SUFFIX,b.com,DIRECT', 'DOMAIN,c.com,REJECT'],
      );
    });

    test('前置规则的位置：主控直连 → po0 直连 → 绕过代理 → 推送直连 → 自定义规则，全部在订阅规则之前', () {
      final meow = MeowSettings(
        account: const MeowAccount(host: 'https://panel.example.com', token: 't'),
        po0Enabled: true,
        po0DirectHosts: const ['209.248.57.93'],
        customRules: [_rule('example.org', MeowRuleMatch.suffix, _p), _rule('ads.example.com', MeowRuleMatch.domain, _r)],
        bypassDomains: const ['x.com'],
        pushDirect: true,
      );
      final rules = meowPrependRules(
        meow,
        debugPo0: false,
        proxyGroups: [
          {'name': '节点选择', 'type': 'select'},
          {'name': '兜底', 'type': 'select'},
        ],
        rules: ['GEOIP,CN,DIRECT', 'MATCH,兜底'],
      );
      // 绕过代理与推送直连在自定义规则之前：用户开着的这两项不被「google.com 含子域名 → 代理」这类规则盖掉（同 iOS）
      expect(rules, [
        'DOMAIN,panel.example.com,DIRECT',
        'IP-CIDR,209.248.57.93/32,DIRECT,no-resolve',
        'DOMAIN,x.com,DIRECT',
        ...pushDirectRules,
        'DOMAIN-SUFFIX,example.org,兜底',
        'DOMAIN,ads.example.com,REJECT',
      ]);
      // 没给代理组：「代理」规则不生成
      expect(meowPrependRules(MeowSettings(customRules: [_rule('a.com', MeowRuleMatch.suffix, _p)]), debugPo0: false), isEmpty);
    });

    test('整张规则表：阻止 QUIC 排在全部 MeowX 前置规则（含自定义规则）之前；主代理组只按订阅规则推断', () {
      const quic = ['AND,((NETWORK,UDP),(DST-PORT,443)),REJECT'];
      final table = meowRuleTable(
        MeowSettings(customRules: [_rule('youtube.com', MeowRuleMatch.suffix, _p)], bypassDomains: const ['x.com']),
        quicRules: quic,
        rules: ['GEOIP,CN,DIRECT', 'MATCH,兜底'],
        proxyGroups: [
          {'name': '节点选择', 'type': 'select'},
          {'name': '兜底', 'type': 'select'},
        ],
        debugPo0: false,
      );
      expect(table, [
        ...quic,
        'DOMAIN,x.com,DIRECT',
        'DOMAIN-SUFFIX,youtube.com,兜底',
        'GEOIP,CN,DIRECT',
        'MATCH,兜底',
      ]);
      // 没开阻止 QUIC：前置规则直接在最前
      expect(meowRuleTable(const MeowSettings(), rules: ['MATCH,DIRECT'], debugPo0: false), ['MATCH,DIRECT']);
    });
  });

  group('列表操作', () {
    final rules = [
      _rule('www.google.com', MeowRuleMatch.domain, _d),
      _rule('google.com', MeowRuleMatch.suffix, _p),
      _rule('1.2.3.4', MeowRuleMatch.ip, _r),
    ];
    test('customRuleFor：按列表顺序取第一条命中的；后缀含自身与子域名、不含形似的域名', () {
      expect(customRuleFor(rules, host: 'WWW.google.com'), rules[0]);
      expect(customRuleFor(rules, host: 'mail.google.com'), rules[1]);
      expect(customRuleFor(rules, host: 'google.com'), rules[1]);
      expect(customRuleFor(rules, host: 'notgoogle.com'), isNull);
      expect(customRuleFor(rules, host: '', ip: '1.2.3.4'), rules[2]);
      expect(customRuleFor(rules, host: 'other.com', ip: '1.2.3.4'), rules[2]);
      expect(customRuleFor(rules, host: '', ip: ''), isNull);
    });
    test('upsert：同值同匹配方式原位改动作；新的放最前；满 1000 条不再新增、已有的照样能改', () {
      expect(upsertCustomRule(rules, _rule('google.com', MeowRuleMatch.suffix, _r)), [rules[0], _rule('google.com', MeowRuleMatch.suffix, _r), rules[2]]);
      expect(upsertCustomRule(rules, _rule('google.com', MeowRuleMatch.domain, _d)).first, _rule('google.com', MeowRuleMatch.domain, _d));
      expect(upsertCustomRule(rules, _rule('google.com', MeowRuleMatch.domain, _d)), hasLength(4));

      final full = [for (var i = 0; i < overridesLimit; i++) _rule('h$i.example.com', MeowRuleMatch.suffix, _d)];
      expect(upsertCustomRule(full, _rule('new.example.com', MeowRuleMatch.suffix, _d)), full);
      expect(upsertCustomRule(full, _rule('h5.example.com', MeowRuleMatch.suffix, _r))[5], _rule('h5.example.com', MeowRuleMatch.suffix, _r));
    });
    test('promote（连接详情点动作）：去掉同值同匹配方式的旧条目、新的放最前；满 1000 条只能改已有的', () {
      // 被前面的「含子域名 www.google.com 拒绝」挡住的「仅此域名 → 直连」：点了挪到最前，压过去
      final shadowed = [_rule('www.google.com', MeowRuleMatch.suffix, _r), _rule('www.google.com', MeowRuleMatch.domain, _d)];
      expect(promoteCustomRule(shadowed, _rule('www.google.com', MeowRuleMatch.domain, _d)), [
        _rule('www.google.com', MeowRuleMatch.domain, _d),
        _rule('www.google.com', MeowRuleMatch.suffix, _r),
      ]);
      expect(promoteCustomRule(rules, _rule('1.2.3.4', MeowRuleMatch.ip, _d)), [_rule('1.2.3.4', MeowRuleMatch.ip, _d), rules[0], rules[1]]);
      expect(promoteCustomRule(rules, _rule('a.com', MeowRuleMatch.suffix, _p)), [_rule('a.com', MeowRuleMatch.suffix, _p), ...rules]);

      final full = [for (var i = 0; i < overridesLimit; i++) _rule('h$i.example.com', MeowRuleMatch.suffix, _d)];
      expect(promoteCustomRule(full, _rule('new.example.com', MeowRuleMatch.suffix, _d)), full);
      final moved = promoteCustomRule(full, _rule('h5.example.com', MeowRuleMatch.suffix, _r));
      expect(moved, hasLength(overridesLimit));
      expect(moved.first, _rule('h5.example.com', MeowRuleMatch.suffix, _r));
    });
    test('replace：原位替换；改得与别的条目重复时去掉那条', () {
      expect(replaceCustomRule(rules, 2, _rule('5.6.7.8', MeowRuleMatch.ip, _d)), [rules[0], rules[1], _rule('5.6.7.8', MeowRuleMatch.ip, _d)]);
      expect(replaceCustomRule(rules, 0, _rule('google.com', MeowRuleMatch.suffix, _d)), [_rule('google.com', MeowRuleMatch.suffix, _d), rules[2]]);
    });
    test('动作文字：代理带组名；没有主代理组只写「代理」', () {
      expect(customRuleActionLabel(_p, '节点选择'), '代理（节点选择）');
      expect(customRuleActionLabel(_d, '节点选择'), '直连');
      expect(customRuleActionLabel(_r, '节点选择'), '拒绝');
      expect(customRuleActionLabel(_p, null), '代理');
      expect(customRuleActionLabel(_p, ''), '代理');
    });
  });

  group('界面显示的主代理组', () {
    late Map<String, dynamic> raw;
    late ProviderContainer container;

    setUp(() {
      appliedMainProxyGroup.value = null;
      addTearDown(() => appliedMainProxyGroup.value = null);
      raw = {
        'proxy-groups': [
          {'name': '节点选择', 'type': 'select'},
          {'name': '兜底', 'type': 'select'},
        ],
        'rules': ['MATCH,兜底'],
      };
      container = ProviderContainer(
        overrides: [
          currentProfileIdProvider.overrideWith(() => _CurrentId('p1')),
          currentRawConfigProvider.overrideWith((ref) => raw),
        ],
      );
      addTearDown(container.dispose);
      container.listen(mainProxyGroupProvider, (_, _) {});
    });

    test('还没应用过：按订阅原始配置推断；原始配置还没取到 = null', () {
      expect(container.read(mainProxyGroupProvider), '兜底');
      raw = const {};
      container.invalidate(currentRawConfigProvider);
      expect(container.read(mainProxyGroupProvider), isNull);
    });

    test('应用配置时按交给内核的那份记下（停用组把 MATCH 改成 PASS 等）：当前订阅的优先，别的订阅的不算', () {
      // Bettbox 停用了「兜底」组：MATCH 改成 PASS、组被删掉，内核实际走第一个 select 组
      captureMainProxyGroup('p1', [{'name': '节点选择', 'type': 'select'}], ['MATCH,PASS']);
      expect(container.read(mainProxyGroupProvider), '节点选择');
      captureMainProxyGroup('p1', const [], const ['MATCH,DIRECT']);
      expect(container.read(mainProxyGroupProvider), isNull);
      captureMainProxyGroup('p2', [{'name': '别的组', 'type': 'select'}], const []);
      expect(container.read(mainProxyGroupProvider), '兜底');
    });
  });

  group('存储', () {
    test('随 MeowSettings 落盘读回；旧配置没有这个字段 = 空；认不出的枚举回到缺省', () {
      final s = MeowSettings(customRules: [_rule('example.org', MeowRuleMatch.suffix, _p), _rule('2001:db8::1', MeowRuleMatch.ip, _r)]);
      final back = MeowSettings.fromJson(jsonDecode(jsonEncode(s.toJson())) as Map<String, Object?>);
      expect(back.customRules, s.customRules);
      expect(back, s);

      expect(MeowSettings.fromJson({'pushDirect': true}).customRules, isEmpty);
      final odd = MeowSettings.fromJson({
        'customRules': [
          {'value': 'a.com', 'match': 'regex', 'action': 'teleport'},
        ],
      });
      expect(odd.customRules.single, _rule('a.com', MeowRuleMatch.suffix, _d));
    });
  });
}
