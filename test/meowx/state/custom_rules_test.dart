import 'dart:convert';

import 'package:bett_box/meowx/config/meow_patch.dart';
import 'package:bett_box/meowx/state/custom_rules.dart';
import 'package:bett_box/meowx/state/overrides.dart';
import 'package:bett_box/models/meow.dart';
import 'package:flutter_test/flutter_test.dart';

const _d = MeowRuleAction.direct, _p = MeowRuleAction.proxy, _r = MeowRuleAction.reject;

MeowCustomRule _rule(String v, MeowRuleMatch m, MeowRuleAction a) => MeowCustomRule(value: v, match: m, action: a);

void main() {
  group('normalizeCustomRuleHost', () {
    test('整条链接：去协议头 / 用户名 / 端口 / 路径 / 查询，小写、去尾点', () {
      expect(normalizeCustomRuleHost('https://user:pw@WWW.Example.COM.:8443/a/b?q=1#f'), (value: 'www.example.com', ip: false, suffixHint: false));
      expect(normalizeCustomRuleHost('  example.com/path  '), (value: 'example.com', ip: false, suffixHint: false));
      expect(normalizeCustomRuleHost('example.com:443'), (value: 'example.com', ip: false, suffixHint: false));
      expect(normalizeCustomRuleHost('localhost'), (value: 'localhost', ip: false, suffixHint: false));
    });
    test('+. / . 前缀 = 想要含子域名', () {
      expect(normalizeCustomRuleHost('+.Example.com'), (value: 'example.com', ip: false, suffixHint: true));
      expect(normalizeCustomRuleHost('.example.com'), (value: 'example.com', ip: false, suffixHint: true));
    });
    test('IP：v4 带端口、v6 方括号 / 裸地址', () {
      expect(normalizeCustomRuleHost('http://1.2.3.4:80/x'), (value: '1.2.3.4', ip: true, suffixHint: false));
      expect(normalizeCustomRuleHost('[2001:DB8::1]:443'), (value: '2001:db8::1', ip: true, suffixHint: false));
      expect(normalizeCustomRuleHost('2001:db8::1'), (value: '2001:db8::1', ip: true, suffixHint: false));
    });
    test('不合法：空 / 通配符 / 非法字符 / CIDR / 带 zone 的 v6 / 没闭合的方括号', () {
      for (final s in ['', '   ', 'https://', '*.example.com', 'a.*.com', 'exa mple.com', 'ex_ample.com', '10.0.0.0/8', 'fe80::1%en0', '[2001:db8::1']) {
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
    test('没有 select 组 → 名叫 GLOBAL 的组，否则第一个组；一个组都没有 → 内置 GLOBAL', () {
      expect(resolveMainProxyGroup([{'name': '自动', 'type': 'url-test'}, {'name': 'GLOBAL', 'type': 'fallback'}], const []), 'GLOBAL');
      expect(resolveMainProxyGroup([{'name': '自动', 'type': 'url-test'}], const []), '自动');
      expect(resolveMainProxyGroup(const [], const ['MATCH,DIRECT']), 'GLOBAL');
      expect(resolveMainProxyGroup('不是列表', 42), 'GLOBAL');
    });
  });

  group('规则生成', () {
    test('DOMAIN / DOMAIN-SUFFIX / IP-CIDR(6) no-resolve，代理走主代理组；存坏的值跳过', () {
      expect(
        customRuleLines([
          _rule('a.example.com', MeowRuleMatch.domain, _d),
          _rule('example.org', MeowRuleMatch.suffix, _p),
          _rule('1.2.3.4', MeowRuleMatch.ip, _r),
          _rule('2001:db8::1', MeowRuleMatch.ip, _p),
          _rule('Bad Value', MeowRuleMatch.suffix, _d),
          _rule('10.0.0.0/8', MeowRuleMatch.ip, _d),
          _rule('1.2.3.4', MeowRuleMatch.suffix, _d),
        ], '节点选择'),
        [
          'DOMAIN,a.example.com,DIRECT',
          'DOMAIN-SUFFIX,example.org,节点选择',
          'IP-CIDR,1.2.3.4/32,REJECT,no-resolve',
          'IP-CIDR6,2001:db8::1/128,节点选择,no-resolve',
        ],
      );
    });

    test('前置规则的位置：主控直连 → po0 直连 → 自定义规则 → 绕过代理 → 推送直连，全部在订阅规则之前', () {
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
      expect(rules, [
        'DOMAIN,panel.example.com,DIRECT',
        'IP-CIDR,209.248.57.93/32,DIRECT,no-resolve',
        'DOMAIN-SUFFIX,example.org,兜底',
        'DOMAIN,ads.example.com,REJECT',
        'DOMAIN,x.com,DIRECT',
        ...pushDirectRules,
      ]);
      // 没给代理组（调用方没传）：代理落到内置 GLOBAL，不丢规则
      expect(meowPrependRules(MeowSettings(customRules: [_rule('a.com', MeowRuleMatch.suffix, _p)]), debugPo0: false), ['DOMAIN-SUFFIX,a.com,GLOBAL']);
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
    test('upsert：同值同匹配方式原位改动作；新的放最前', () {
      expect(upsertCustomRule(rules, _rule('google.com', MeowRuleMatch.suffix, _r)), [rules[0], _rule('google.com', MeowRuleMatch.suffix, _r), rules[2]]);
      expect(upsertCustomRule(rules, _rule('google.com', MeowRuleMatch.domain, _d)).first, _rule('google.com', MeowRuleMatch.domain, _d));
      expect(upsertCustomRule(rules, _rule('google.com', MeowRuleMatch.domain, _d)), hasLength(4));
    });
    test('replace：原位替换；改得与别的条目重复时去掉那条', () {
      expect(replaceCustomRule(rules, 2, _rule('5.6.7.8', MeowRuleMatch.ip, _d)), [rules[0], rules[1], _rule('5.6.7.8', MeowRuleMatch.ip, _d)]);
      expect(replaceCustomRule(rules, 0, _rule('google.com', MeowRuleMatch.suffix, _d)), [_rule('google.com', MeowRuleMatch.suffix, _d), rules[2]]);
    });
    test('动作文字：代理带组名', () {
      expect(customRuleActionLabel(_p, '节点选择'), '代理（节点选择）');
      expect(customRuleActionLabel(_d, '节点选择'), '直连');
      expect(customRuleActionLabel(_r, '节点选择'), '拒绝');
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
