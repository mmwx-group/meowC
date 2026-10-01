import 'package:bett_box/meowx/panel/po0.dart';
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

  test('直连 IP：ip 字段优先，缺省取 url host（去方括号），跳过域名，规范化去重', () {
    Po0Server srv(String ip, String url) => Po0Server(serverId: 0, name: '', ip: ip, token: '', url: url);
    final ips = po0DirectIps([
      srv('209.248.57.93', 'https://209.248.57.93/api/firewall/a/add?slot=1'),
      srv('209.248.57.93', 'https://209.248.57.93:8443/api/firewall/b/add'), // 同 IP 两个 token → 去重
      srv('', 'https://[2001:DB8::1]/api/firewall/c/add'),
      srv('[2001:db8:0::1]', 'https://x/'), // 同一个 v6 的不同写法
      srv('', 'https://po0.example.com/api/firewall/d/add'), // 域名跳过
      srv('', 'https://1.2.3.4:21018/api/firewall/e/add'),
    ]);
    expect(ips, ['209.248.57.93', '2001:db8::1', '1.2.3.4']);
    expect(po0DirectRules(ips), [
      'IP-CIDR,209.248.57.93/32,DIRECT,no-resolve',
      'IP-CIDR6,2001:db8::1/128,DIRECT,no-resolve',
      'IP-CIDR,1.2.3.4/32,DIRECT,no-resolve',
    ]);
    expect(po0DirectRules(const []), isEmpty);
  });
}
