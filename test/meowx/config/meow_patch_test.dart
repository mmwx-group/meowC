import 'dart:convert';

import 'package:bett_box/meowx/config/meow_patch.dart';
import 'package:bett_box/meowx/state/overrides.dart';
import 'package:bett_box/models/meow.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('effectiveDnsMode', () {
    test('follow：声明 fake-ip 才 fake-ip，其它（含未声明）→ redir-host', () {
      expect(effectiveDnsMode(MeowDnsMode.follow, 'fake-ip'), 'fake-ip');
      expect(effectiveDnsMode(MeowDnsMode.follow, 'redir-host'), 'redir-host');
      expect(effectiveDnsMode(MeowDnsMode.follow, 'normal'), 'redir-host');
      expect(effectiveDnsMode(MeowDnsMode.follow, null), 'redir-host');
    });
    test('强制档不看声明', () {
      expect(effectiveDnsMode(MeowDnsMode.fakeIp, 'redir-host'), 'fake-ip');
      expect(effectiveDnsMode(MeowDnsMode.redirHost, 'fake-ip'), 'redir-host');
    });
  });

  group('用户覆写', () {
    test('DNS 劫持写 hosts，保留原有', () {
      final raw = <String, dynamic>{'hosts': {'a.com': '1.1.1.1'}};
      applyMeowHosts(raw, const MeowSettings(dnsHijack: {'b.com': '2.2.2.2'}));
      expect(raw['hosts'], {'a.com': '1.1.1.1', 'b.com': '2.2.2.2'});
    });
    test('前置规则：绕过 → 推送直连', () {
      expect(meowPrependRules(const MeowSettings(bypassDomains: ['x.com'], bypassCidrs: ['10.0.0.0/8'], pushDirect: true)), [
        'DOMAIN,x.com,DIRECT',
        'IP-CIDR,10.0.0.0/8,DIRECT,no-resolve',
        ...pushDirectRules,
      ]);
      expect(meowPrependRules(const MeowSettings()), isEmpty);
    });
    test('主控直连：登录的主控 + 主控样式的订阅地址（订阅域名）排在最前；别家订阅、没登录不算', () {
      const account = MeowAccount(host: 'https://Panel.Example.com:8443', token: 't');
      final urls = [
        'https://sub.example.com/x/abc',
        'https://SUB.example.com/api/clash/subscribe?token=t',
        'https://cdn.example.net/api/user/package-subscribe?token=t',
        'https://airport.example.org/link/xyz',
        '',
      ];
      expect(meowPrependRules(const MeowSettings(account: account, bypassDomains: ['x.com']), subscriptionUrls: urls), [
        'DOMAIN,panel.example.com,DIRECT',
        'DOMAIN,sub.example.com,DIRECT',
        'DOMAIN,cdn.example.net,DIRECT',
        'DOMAIN,x.com,DIRECT',
      ]);
      // 没登录：只看订阅地址
      expect(panelDirectRules(const MeowAccount(host: 'https://panel.example.com'), urls.take(1)), ['DOMAIN,sub.example.com,DIRECT']);
      // 主控是 IP
      expect(panelDirectRules(const MeowAccount(host: 'https://203.0.113.9:8443', token: 't'), const []),
          ['IP-CIDR,203.0.113.9/32,DIRECT,no-resolve']);
      expect(panelDirectRules(const MeowAccount(host: 'https://[2001:db8::9]', token: 't'), const []),
          ['IP-CIDR6,2001:db8::9/128,DIRECT,no-resolve']);
      expect(panelDirectRules(const MeowAccount(), const ['https://airport.example.org/sub']), isEmpty);
    });
    test('po0 直连：开关关着不加；开着按缓存主机生成 v4 / v6 / 域名规则且排在最前', () {
      const hosts = ['209.248.57.93', '2001:db8::1', 'fw.example.com'];
      // 关着：有缓存也不加
      expect(meowPrependRules(const MeowSettings(po0DirectHosts: hosts), debugPo0: false), isEmpty);
      // 开着：排在绕过 / 推送直连之前；域名不带 no-resolve
      expect(meowPrependRules(const MeowSettings(po0Enabled: true, po0DirectHosts: hosts, bypassDomains: ['x.com'], pushDirect: true), debugPo0: false), [
        'IP-CIDR,209.248.57.93/32,DIRECT,no-resolve',
        'IP-CIDR6,2001:db8::1/128,DIRECT,no-resolve',
        'DOMAIN,fw.example.com,DIRECT',
        'DOMAIN,x.com,DIRECT',
        ...pushDirectRules,
      ]);
      // 开着但列表空（撤掉）
      expect(meowPrependRules(const MeowSettings(po0Enabled: true), debugPo0: false), isEmpty);
      // debug 注入视为开着
      expect(meowPrependRules(const MeowSettings(po0DirectHosts: ['1.2.3.4']), debugPo0: true), ['IP-CIDR,1.2.3.4/32,DIRECT,no-resolve']);
    });
    test('po0 设置落盘：沿用旧键 po0DirectIps；自定义条目与它一起读写，旧配置没有就是空', () {
      // 旧版落盘的数据（只有 IP、没有 po0Custom）原样读成主机
      final old = MeowSettings.fromJson({'po0Enabled': true, 'po0DirectIps': ['209.248.57.93']});
      expect(old.po0DirectHosts, ['209.248.57.93']);
      expect(old.po0Custom, isEmpty);

      const s = MeowSettings(
        po0DirectHosts: ['fw.example.com'],
        po0Custom: [Po0CustomServer(address: 'fw.example.com:8443', token: 'pgnfw_abcd1234wxyz@2')],
      );
      final round = MeowSettings.fromJson(json.decode(json.encode(s.toJson())) as Map<String, Object?>);
      expect(round, s);
      expect(s.toJson().containsKey('po0DirectIps'), isTrue);
    });
    test('本地代理凭据 → authentication', () {
      final raw = <String, dynamic>{};
      applyMeowAuthentication(raw, const MeowSettings(localProxy: MeowLocalProxy(username: 'u', password: 'p')));
      expect(raw['authentication'], ['u:p']);
      expect(raw['skip-auth-prefixes'], ['127.0.0.1/32', '::1/128']);
      final none = <String, dynamic>{};
      applyMeowAuthentication(none, const MeowSettings());
      expect(none.containsKey('authentication'), isFalse);
    });
  });

  group('applyMeowDns', () {
    test('follow 不动配置', () {
      final raw = <String, dynamic>{'dns': {'enable': false, 'enhanced-mode': 'fake-ip'}};
      applyMeowDns(raw, MeowDnsMode.follow);
      expect(raw['dns'], {'enable': false, 'enhanced-mode': 'fake-ip'});
    });
    test('redir-host：强制 enable + 写模式，其它键保留', () {
      final raw = <String, dynamic>{'dns': {'enable': false, 'enhanced-mode': 'fake-ip', 'nameserver': ['https://1.1.1.1/dns-query']}};
      applyMeowDns(raw, MeowDnsMode.redirHost);
      expect(raw['dns']['enable'], true);
      expect(raw['dns']['enhanced-mode'], 'redir-host');
      expect(raw['dns']['nameserver'], ['https://1.1.1.1/dns-query']);
    });
    test('fake-ip：缺 range / filter 才补默认', () {
      final raw = <String, dynamic>{};
      applyMeowDns(raw, MeowDnsMode.fakeIp);
      expect(raw['dns']['enhanced-mode'], 'fake-ip');
      expect(raw['dns']['fake-ip-range'], defaultFakeIpRange);
      expect(raw['dns']['fake-ip-filter'], defaultFakeIpFilter);

      final own = <String, dynamic>{'dns': {'fake-ip-range': '28.0.0.1/8', 'fake-ip-filter': ['*.lan']}};
      applyMeowDns(own, MeowDnsMode.fakeIp);
      expect(own['dns']['fake-ip-range'], '28.0.0.1/8');
      expect(own['dns']['fake-ip-filter'], ['*.lan']);
    });
    test('declaredDnsMode', () {
      expect(declaredDnsMode({'dns': {'enhanced-mode': 'fake-ip'}}), 'fake-ip');
      expect(declaredDnsMode({'dns': {}}), isNull);
      expect(declaredDnsMode({}), isNull);
    });
  });
}
