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
    test('po0 直连：开关关着不加；开着按缓存 IP 生成 v4 / v6 规则且排在最前', () {
      const ips = ['209.248.57.93', '2001:db8::1'];
      // 关着：有缓存也不加
      expect(meowPrependRules(const MeowSettings(po0DirectIps: ips), debugPo0: false), isEmpty);
      // 开着：排在绕过 / 推送直连之前
      expect(meowPrependRules(const MeowSettings(po0Enabled: true, po0DirectIps: ips, bypassDomains: ['x.com'], pushDirect: true), debugPo0: false), [
        'IP-CIDR,209.248.57.93/32,DIRECT,no-resolve',
        'IP-CIDR6,2001:db8::1/128,DIRECT,no-resolve',
        'DOMAIN,x.com,DIRECT',
        ...pushDirectRules,
      ]);
      // 开着但列表空（撤掉）
      expect(meowPrependRules(const MeowSettings(po0Enabled: true), debugPo0: false), isEmpty);
      // debug 注入视为开着
      expect(meowPrependRules(const MeowSettings(po0DirectIps: ['1.2.3.4']), debugPo0: true), ['IP-CIDR,1.2.3.4/32,DIRECT,no-resolve']);
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
