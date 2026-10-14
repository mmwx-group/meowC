import 'package:bett_box/meowx/panel/po0.dart';
import 'package:bett_box/models/meow.dart';
import 'package:bett_box/meowx/state/po0_reporter.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const server = {
    'server_id': 2,
    'name': 'AgentB-Exit',
    'ip': '209.248.57.93',
    'token': 'pgnfw_agentbtoken1',
    'slot': 1,
    'url': 'https://209.248.57.93/api/firewall/pgnfw_agentbtoken1/add?slot=1',
  };

  test('po0 服务器列表解析', () {
    final list = Po0Server.parse({'success': true, 'servers': [server]});
    expect(list.length, 1);
    final s = list.single;
    expect(s.serverId, 2);
    expect(s.name, 'AgentB-Exit');
    expect(s.ip, '209.248.57.93');
    expect(s.token, 'pgnfw_agentbtoken1');
    expect(s.slot, 1);
    expect(s.url, 'https://209.248.57.93/api/firewall/pgnfw_agentbtoken1/add?slot=1');

    // 没设槽位 → slot 为 null；server_id 是字符串也认
    final noSlot = Po0Server.parse({
      'success': true,
      'servers': [
        {'server_id': '7', 'name': 'x', 'ip': '::1', 'token': 't', 'url': 'https://[::1]/api/firewall/t/add'},
      ],
    }).single;
    expect(noSlot.slot, isNull);
    expect(noSlot.serverId, 7);

    // 缺 url 的条目跳过；空列表 / 失败 / 形状不对 → 空
    expect(Po0Server.parse({'success': true, 'servers': [{'name': 'no-url'}]}), isEmpty);
    expect(Po0Server.parse({'success': true, 'servers': []}), isEmpty);
    expect(Po0Server.parse({'success': false, 'error': 'unauthorized'}), isEmpty);
    expect(Po0Server.parse('nope'), isEmpty);
  });

  test('上报结果解析', () {
    final results = Po0ReportResult.parseList(
      '[{"url":"https://a/add","status":200,"body":"{\\"enabled\\":true,\\"whitelist\\":[{\\"ip\\":\\"1.2.3.4\\",\\"slot\\":1},{\\"ip\\":\\"5.6.7.8\\",\\"slot\\":2}],\\"limit\\":5,\\"currentIp\\":\\"1.2.3.4\\"}"},'
      '{"url":"https://b/add","status":403,"body":"forbidden"},'
      '{"url":"https://c/add","error":"dial tcp: i/o timeout"}]',
    );
    expect(results.length, 3);

    final ok = results[0];
    expect(ok.ok, isTrue);
    final w = ok.whitelist!;
    expect(w.enabled, isTrue);
    expect(w.count, 2);
    expect(w.limit, 5);
    expect(w.currentIp, '1.2.3.4');

    expect(results[1].tokenInvalid, isTrue);
    expect(results[1].whitelist, isNull);

    expect(results[2].status, 0);
    expect(results[2].error, 'dial tcp: i/o timeout');

    expect(Po0ReportResult.parseList(''), isEmpty);
    expect(Po0ReportResult.parseList('not json'), isEmpty);
    expect(Po0ReportResult.parseList('{"a":1}'), isEmpty);
  });

  test('日志文案', () {
    expect(
      Po0Reporter.describeResult(
        'AgentB-Exit',
        const Po0ReportResult(url: 'u', status: 200, body: '{"enabled":true,"whitelist":[{"ip":"1.2.3.4","slot":1}],"limit":5,"currentIp":"1.2.3.4"}'),
      ),
      'po0 加白 AgentB-Exit：白名单 1/5，当前 IP 1.2.3.4',
    );
    expect(Po0Reporter.describeResult('n', const Po0ReportResult(url: 'u', status: 403)), 'po0 加白 n 失败：po0 token 无效');
    expect(Po0Reporter.describeResult('n', const Po0ReportResult(url: 'u', status: 500)), 'po0 加白 n 失败：HTTP 500');
    expect(Po0Reporter.describeResult('n', const Po0ReportResult(url: 'u', error: 'refused')), 'po0 加白 n 失败：refused');
    expect(Po0Reporter.describeResult('n', const Po0ReportResult(url: 'u', status: 200, body: 'html')), 'po0 加白 n 失败：响应无法解析');
  });

  test('直连主机：取上报地址的 host（去方括号、转小写），IP 规范化、域名保留，去重', () {
    Po0Server srv(String ip, String url) => Po0Server(serverId: 0, name: '', ip: ip, token: '', url: url);
    final hosts = po0DirectHosts([
      srv('209.248.57.93', 'https://209.248.57.93/api/firewall/a/add?slot=1'),
      srv('209.248.57.93', 'https://209.248.57.93:8443/api/firewall/b/add'), // 同 IP 两个 token → 去重
      srv('', 'https://[2001:DB8::1]/api/firewall/c/add'),
      srv('', 'https://[2001:db8:0::1]:8443/api/firewall/c2/add'), // 同一个 v6 的不同写法
      srv('', 'https://PO0.Example.com/api/firewall/d/add'), // 域名 → 小写保留
      srv('', 'https://po0.example.com:8443/api/firewall/d2/add'), // 同域名不同端口 → 去重
      srv('', 'https://1.2.3.4:21018/api/firewall/e/add'),
      srv('5.6.7.8', ''), // url 解析不出 host 才退回 ip 字段
    ]);
    expect(hosts, ['209.248.57.93', '2001:db8::1', 'po0.example.com', '1.2.3.4', '5.6.7.8']);
    expect(po0DirectRules(hosts), [
      'IP-CIDR,209.248.57.93/32,DIRECT,no-resolve',
      'IP-CIDR6,2001:db8::1/128,DIRECT,no-resolve',
      'DOMAIN,po0.example.com,DIRECT',
      'IP-CIDR,1.2.3.4/32,DIRECT,no-resolve',
      'IP-CIDR,5.6.7.8/32,DIRECT,no-resolve',
    ]);
    expect(po0DirectRules(const []), isEmpty);
    // 旧版落盘的纯 IP 列表照旧生成；不是 IP 也不是合法域名的（逗号会破坏规则）跳过
    expect(po0DirectRules(const ['1.2.3.4', 'bad,host', '']), ['IP-CIDR,1.2.3.4/32,DIRECT,no-resolve']);
  });

  group('自定义 po0 服务器', () {
    test('地址规范化：合法', () {
      const ok = {
        '1.2.3.4': '1.2.3.4',
        ' 1.2.3.4:8443 ': '1.2.3.4:8443',
        'https://1.2.3.4/': '1.2.3.4',
        'http://1.2.3.4:08443': '1.2.3.4:8443',
        'HTTP://FW.Example.com:8443/': 'fw.example.com:8443',
        'fw.example.com': 'fw.example.com',
        'localhost': 'localhost',
        '2001:DB8::1': '[2001:db8::1]',
        '[2001:db8::1]': '[2001:db8::1]',
        '[2001:db8::1]:8443': '[2001:db8::1]:8443',
        'https://[2001:db8::1]:8443/': '[2001:db8::1]:8443',
        'a-b.example.com:65535': 'a-b.example.com:65535',
        '1.2.3.4:1': '1.2.3.4:1',
        '1.2.3.4//': '1.2.3.4', // 结尾连续的 / 全去掉
        'https://fw.example.com:8443///': 'fw.example.com:8443',
        '1.2.3.4:0008443': '1.2.3.4:8443',
        '::ffff:1.2.3.4': '[::ffff:1.2.3.4]',
        '[::FFFF:1.2.3.4]:443': '[::ffff:1.2.3.4]:443',
        '2001:DB8:0:0::1': '[2001:db8:0:0::1]', // 只转小写，不压缩不展开
        '0.0.0.0': '0.0.0.0',
        '255.255.255.255:65535': '255.255.255.255:65535',
      };
      for (final e in ok.entries) {
        expect(parsePo0Address(e.key), (e.value, null), reason: e.key);
        expect(normalizePo0Address(e.key), e.value, reason: e.key);
      }
    });

    test('地址规范化：非法，给出具体提示', () {
      const bad = {
        '': po0AddressEmptyMessage,
        '  ': po0AddressEmptyMessage,
        'https://': po0AddressEmptyMessage,
        '1.2.3.4/api': po0AddressPathMessage,
        '1.2.3.4?x=1': po0AddressPathMessage,
        '1.2.3.4#x': po0AddressPathMessage,
        'user@1.2.3.4': po0AddressPathMessage,
        '1.2.3.4/api/': po0AddressPathMessage,
        'ftp://1.2.3.4': po0AddressPathMessage,
        '1.2.3.4:000000': po0AddressPortMessage,
        '1.2.3.4:100000': po0AddressPortMessage,
        '1.2.3.4.': po0AddressInvalidMessage,
        '1234': po0AddressInvalidMessage,
        '256.1.1.1': po0AddressInvalidMessage,
        '1.2.3.4:0': po0AddressPortMessage,
        '1.2.3.4:65536': po0AddressPortMessage,
        '1.2.3.4:': po0AddressPortMessage,
        '1.2.3.4:abc': po0AddressPortMessage,
        '[2001:db8::1]:0': po0AddressPortMessage,
        '1.2.3.999': po0AddressInvalidMessage,
        '1.2.3': po0AddressInvalidMessage,
        '12345': po0AddressInvalidMessage,
        '01.2.3.4': po0AddressInvalidMessage,
        'fw_example.com': po0AddressInvalidMessage,
        '-fw.example.com': po0AddressInvalidMessage,
        'fw-.example.com': po0AddressInvalidMessage,
        'fw..example.com': po0AddressInvalidMessage,
        'fw.example.com.': po0AddressInvalidMessage,
        'fw example.com': po0AddressInvalidMessage,
        '[2001:db8::1': po0AddressInvalidMessage,
        '[2001:db8::1]8443': po0AddressInvalidMessage,
        '[1.2.3.4]': po0AddressInvalidMessage,
        '[fw.example.com]': po0AddressInvalidMessage,
        'fe80::1%en0': po0AddressInvalidMessage,
        '[fe80::1%en0]': po0AddressInvalidMessage,
        '2001:db8::zz': po0AddressInvalidMessage,
      };
      for (final e in bad.entries) {
        expect(parsePo0Address(e.key), (null, e.value), reason: e.key);
        expect(normalizePo0Address(e.key), isNull, reason: e.key);
      }
      // 不带方括号的「v6:端口」：提示要加方括号（`2001:db8::1:8443` 本身是合法 v6，只能按裸 v6 收）
      expect(parsePo0Address('2001:db8:1:2:3:4:5:6:8443'), (null, po0AddressV6PortMessage));
      expect(parsePo0Address('2001:db8::1:8443'), ('[2001:db8::1:8443]', null));
    });

    test('token 校验：与主控同一个正则', () {
      for (final t in ['pgnfw_abcd', 'pgnfw_abcd1234wxyz', ' pgnfw_a-b_c@2 ', 'pgnfw_abcd@0', 'pgnfw_abcd@99', 'pgnfw_${'a' * 200}']) {
        expect(validatePo0Token(t), isNull, reason: t);
      }
      expect(validatePo0Token(''), po0TokenEmptyMessage);
      expect(validatePo0Token('   '), po0TokenEmptyMessage);
      for (final t in ['pgnfw_abc', 'abcd1234', 'PGNFW_abcd', 'pgnfw_abcd@', 'pgnfw_abcd@123', 'pgnfw_ab cd', 'pgnfw_abc.d', 'pgnfw_abcd@2@3', 'pgnfw_${'a' * 201}']) {
        expect(validatePo0Token(t), po0TokenInvalidMessage, reason: t);
      }
    });

    test('上报地址：去掉 @槽位，有槽位加 ?slot=N', () {
      expect(po0ReportUrl('1.2.3.4', 'pgnfw_abcd1234wxyz'), 'https://1.2.3.4/api/firewall/pgnfw_abcd1234wxyz/add');
      expect(po0ReportUrl('[2001:db8::1]:8443', 'pgnfw_abcd1234wxyz@2'), 'https://[2001:db8::1]:8443/api/firewall/pgnfw_abcd1234wxyz/add?slot=2');
      expect(po0ReportUrl('fw.example.com:8443', ' pgnfw_abcd@12 '), 'https://fw.example.com:8443/api/firewall/pgnfw_abcd/add?slot=12');
    });

    test('token 脱敏', () {
      expect(maskPo0Token('pgnfw_abcd1234wxyz@2'), 'pgnfw_••••wxyz@2');
      expect(maskPo0Token('pgnfw_abcd1234wxyz'), 'pgnfw_••••wxyz');
      expect(maskPo0Token('pgnfw_abcd1234'), 'pgnfw_••••1234'); // 正好 8 个字符
      expect(maskPo0Token('pgnfw_abcd123'), 'pgnfw_••••'); // 少于 8 个
      expect(maskPo0Token('pgnfw_abcd123@3'), 'pgnfw_••••@3');
      expect(maskPo0Token('whatever-secret'), '••••');
    });

    test('文字里的 token 脱敏：上报地址那一段 + 散落的 pgnfw_…', () {
      expect(
        redactPo0('Post "https://1.2.3.4/api/firewall/pgnfw_abcd1234wxyz/add?slot=2": dial tcp 1.2.3.4:443: i/o timeout'),
        'Post "https://1.2.3.4/api/firewall/pgnfw_••••wxyz/add?slot=2": dial tcp 1.2.3.4:443: i/o timeout',
      );
      expect(redactPo0('https://[::1]/api/firewall/secret-debug-token/add'), 'https://[::1]/api/firewall/••••/add');
      expect(redactPo0('token pgnfw_abcd1234wxyz@2 无效'), 'token pgnfw_••••wxyz@2 无效');
      // 已脱敏的不再动；没有 token 的原样
      expect(redactPo0('po0 加白 1.2.3.4（pgnfw_••••wxyz@2）：白名单 1/5'), 'po0 加白 1.2.3.4（pgnfw_••••wxyz@2）：白名单 1/5');
      expect(redactPo0('白名单 1/5，当前 IP 1.2.3.4'), '白名单 1/5，当前 IP 1.2.3.4');
    });

    test('合并：自定义追加在主控之后，按上报地址去重，不合法的跳过；直连规则含域名', () {
      const panel = [
        Po0Server(serverId: 2, name: 'AgentB-Exit', ip: '209.248.57.93', token: 'pgnfw_abcd1234wxyz', slot: 1, url: 'https://209.248.57.93/api/firewall/pgnfw_abcd1234wxyz/add?slot=1'),
      ];
      final merged = mergePo0Servers(panel, const [
        Po0CustomServer(address: '209.248.57.93', token: 'pgnfw_abcd1234wxyz@1'), // 与主控那条同一个上报地址
        Po0CustomServer(address: 'fw.example.com:8443', token: 'pgnfw_efgh5678ijkl@2'),
        Po0CustomServer(address: 'fw.example.com:8443', token: 'pgnfw_efgh5678ijkl@2'), // 自己重复
        Po0CustomServer(address: '[2001:db8::1]', token: 'pgnfw_mnop9012'),
        Po0CustomServer(address: 'bad host', token: 'pgnfw_qrst3456'),
        Po0CustomServer(address: '5.6.7.8', token: 'not-a-token'),
      ]);
      expect(merged.map((s) => s.url), [
        'https://209.248.57.93/api/firewall/pgnfw_abcd1234wxyz/add?slot=1',
        'https://fw.example.com:8443/api/firewall/pgnfw_efgh5678ijkl/add?slot=2',
        'https://[2001:db8::1]/api/firewall/pgnfw_mnop9012/add',
      ]);
      expect(merged.first.name, 'AgentB-Exit');
      expect(merged[1].name, 'fw.example.com:8443（pgnfw_••••ijkl@2）');
      expect(merged[1].slot, 2);
      expect(merged[2].slot, isNull);
      // 没有主控列表时只剩自定义的
      expect(mergePo0Servers(const [], const [Po0CustomServer(address: '1.2.3.4', token: 'pgnfw_abcd')]).single.url,
          'https://1.2.3.4/api/firewall/pgnfw_abcd/add');
      // 直连主机：主控的 IP + 自定义的域名 / v6
      expect(po0DirectRules(po0DirectHosts(merged)), [
        'IP-CIDR,209.248.57.93/32,DIRECT,no-resolve',
        'DOMAIN,fw.example.com,DIRECT',
        'IP-CIDR6,2001:db8::1/128,DIRECT,no-resolve',
      ]);
    });

    test('日志文案：名字找不到时退回的上报地址、核心错误里的 token 都脱敏', () {
      expect(
        Po0Reporter.describeResult(
          'https://1.2.3.4/api/firewall/pgnfw_abcd1234wxyz/add',
          const Po0ReportResult(
            url: 'https://1.2.3.4/api/firewall/pgnfw_abcd1234wxyz/add',
            error: 'Post "https://1.2.3.4/api/firewall/pgnfw_abcd1234wxyz/add": context deadline exceeded',
          ),
        ),
        'po0 加白 https://1.2.3.4/api/firewall/pgnfw_••••wxyz/add 失败：'
        'Post "https://1.2.3.4/api/firewall/pgnfw_••••wxyz/add": context deadline exceeded',
      );
    });
  });
}
