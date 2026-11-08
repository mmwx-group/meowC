import 'dart:convert';

import 'package:bett_box/meowx/panel/akile.dart';
import 'package:bett_box/meowx/panel/node_match.dart';
import 'package:bett_box/models/meow.dart';
import 'package:flutter_test/flutter_test.dart';

// 只用假 Key。
const _key = 'ak_TESTkey0000000000AAAA';

void main() {
  group('API Key', () {
    test('去掉首尾空白与 X-API-Key: / Bearer 前缀（不分大小写）后校验', () {
      for (final input in [
        _key,
        '  $_key \n',
        'X-API-Key: $_key',
        'x-api-key:$_key',
        'Bearer $_key',
        'BEARER   $_key',
        'X-API-Key: Bearer $_key',
      ]) {
        expect(parseAkileKey(input), (_key, null), reason: input);
      }
      for (final input in [
        '',
        '   ',
        'ak_short',
        'sk_TESTkey0000000000AAAA',
        'ak_has space123',
        'ak_${'x' * 201}',
        'Authorization: $_key',
      ]) {
        expect(parseAkileKey(input), (null, akileKeyInvalidMessage), reason: input);
      }
      expect(isValidAkileKey(_key), isTrue);
      expect(isValidAkileKey(''), isFalse);
    });

    test('脱敏写法 ak_••••<后 4 位>；文字里的 Key 与像 Key 的串都换掉', () {
      expect(maskAkileKey(_key), 'ak_••••AAAA');
      final text = 'bad key $_key / other ak_otherKEY12345678ZZZZ';
      final out = redactAkile(text, _key);
      expect(out, 'bad key ak_••••AAAA / other ak_••••ZZZZ');
      expect(redactAkile('no key here'), 'no key here');
    });
  });

  group('节点', () {
    const a = MeowAkileNode(name: '香港', port: 443, ruleId: 7, label: '香港 01');
    const b = MeowAkileNode(name: '日本', port: 8443, ruleId: 8);

    test('落盘写法同 iOS / macOS：{name, port, rule_id, label}', () {
      expect(a.toJson(), {'name': '香港', 'port': 443, 'rule_id': 7, 'label': '香港 01'});
      expect(
        MeowAkileNode.fromJson(const {'name': 'x', 'port': 1, 'rule_id': 2}),
        const MeowAkileNode(name: 'x', port: 1, ruleId: 2),
      );
      final settings = MeowSettings.fromJson(
        json.decode(json.encode(const MeowSettings(akileEnabled: true, akileKey: _key, akileNodes: [a]).toJson())),
      );
      expect(settings.akileNodes, [a]);
      expect(settings.akileEnabled, isTrue);
      // 老配置没有这几项 = 关、没有 Key、没有节点
      final old = MeowSettings.fromJson(const {});
      expect(old.akileEnabled, isFalse);
      expect(old.akileKey, '');
      expect(old.akileNodes, isEmpty);
    });

    test('按规则去重、上限 20', () {
      expect(checkNewAkileNode([a], 8), isNull);
      expect(checkNewAkileNode([a], 7), akileDuplicateMessage);
      final full = [for (var i = 1; i <= akileMaxNodes; i++) MeowAkileNode(ruleId: i)];
      expect(checkNewAkileNode(full, 100), akileNodesFullMessage);
      expect(akileReportNodes([a, b, a, const MeowAkileNode(ruleId: 0), ...full]).map((n) => n.ruleId).take(4), [
        7,
        8,
        1,
        2,
      ]);
      expect(akileReportNodes([...full, a]), hasLength(akileMaxNodes));
    });

    test('节点行第二行', () {
      expect(akileNodeDetail(a), '规则 #7 · 香港 01 · 端口 443');
      expect(akileNodeDetail(b), '规则 #8 · 端口 8443');
    });

    test('订阅里的可选节点：只列有 type / server / port 的，保持顺序；搜索名字或地址', () {
      final keys = <String, NodeMatchKey?>{
        '香港 01': NodeMatchKey.of(type: 'vless', server: 'hk.example.com', port: 443),
        '喵窝': null, // type: tailscale，没有 server / port
        'v6': NodeMatchKey.of(type: 'ss', server: '2001:db8::1', port: 8388),
        'mieru 范围': NodeMatchKey.ofProxy(const {'type': 'mieru', 'server': '1.2.3.4', 'port-range': '2000-2010'}),
      };
      final all = akileCandidates(keys);
      expect(all.map((c) => c.name), ['香港 01', 'v6', 'mieru 范围']);
      expect(all.map((c) => c.address), ['hk.example.com:443', '[2001:db8::1]:8388', '1.2.3.4:2000']);
      expect(filterAkileCandidates(all, ' HK ').map((c) => c.name), ['香港 01']);
      expect(filterAkileCandidates(all, '8388').map((c) => c.name), ['v6']);
      expect(filterAkileCandidates(all, ''), all);
    });
  });

  group('核心回包', () {
    test('查规则：每条一行；出错文字脱敏', () {
      final ok = parseAkileRules(
        '{"rules":[{"id":7,"entry_whitelist":"1.2.3.4/32","summary":"香港 01","node_id":"3","listen_port":443},{"id":9,"entry_whitelist":""},{"id":"x"}]}',
      );
      expect(ok.error, isNull);
      expect(ok.rules.map((r) => r.line), ['规则 #7 · 香港 01 · 节点 3 · 当前白名单 1.2.3.4/32', '规则 #9 · 当前白名单 未设置']);
      final err = parseAkileRules('{"rules":[],"kind":"failed","error":"bad $_key"}', key: _key);
      expect(err.error, 'bad ak_••••AAAA');
      expect(parseAkileRules('{"rules":[],"kind":"invalid_key","error":"API Key 无效或已删除"}').error, 'API Key 无效或已删除');
      expect(parseAkileRules('').error, '核心无响应');
      expect(parseAkileRules('{"rules":[]}').rules, isEmpty);
    });

    test('一轮上报：成功 / 已是 / 失败 / 定时轮跳过 / 回包里缺的', () {
      final at = DateTime(2026, 11, 8, 9, 5);
      const nodes = [
        MeowAkileNode(name: 'a', ruleId: 1),
        MeowAkileNode(name: 'b', ruleId: 2),
        MeowAkileNode(name: 'c', ruleId: 3),
        MeowAkileNode(name: 'd', ruleId: 4),
        MeowAkileNode(name: 'e', ruleId: 5),
      ];
      final raw = json.encode({
        'ip': '203.0.113.10',
        'results': [
          {'rule_id': 1, 'ok': true, 'kind': 'updated', 'ip': '203.0.113.10', 'previous': '198.51.100.1'},
          {'rule_id': 2, 'ok': true, 'kind': 'unchanged', 'ip': '203.0.113.10', 'previous': '203.0.113.10'},
          {'rule_id': 3, 'ok': false, 'kind': 'invalid_key', 'error': 'API Key 无效或已删除 $_key'},
          {'rule_id': 4, 'ok': true, 'kind': 'skipped', 'ip': '203.0.113.10'},
        ],
      });
      final r = parseAkileReport(raw, nodes, key: _key, at: at);
      expect(r.ip, '203.0.113.10');
      expect(r.skipped, {4});
      expect(r.results.keys, [1, 2, 3, 5]);
      expect(r.results[1]!.summary, '已更新为 203.0.113.10 · 09:05');
      expect(r.results[1]!.okIp, '203.0.113.10');
      expect(r.results[2]!.summary, '已是 203.0.113.10 · 09:05');
      expect(r.results[3]!.kind, AkileResultKind.invalidKey);
      expect(r.results[3]!.summary, 'API Key 无效或已删除 ak_••••AAAA · 09:05');
      expect(r.results[3]!.okIp, isNull);
      expect(r.results[5]!.error, '核心无响应');

      expect(r.results[1]!.logLine('香港', 1), 'AkileCDN 白名单 香港（规则 #1）：已更新 198.51.100.1 → 203.0.113.10');
      expect(r.results[2]!.logLine('日本', 2), 'AkileCDN 白名单 日本（规则 #2）：已是 203.0.113.10');
      expect(r.results[3]!.logLine('x', 3, key: _key), 'AkileCDN 白名单 x（规则 #3）：失败（API Key 无效或已删除 ak_••••AAAA）');
      expect(
        AkileResult(kind: AkileResultKind.updated, ip: '203.0.113.10', at: at).logLine('n', 9),
        'AkileCDN 白名单 n（规则 #9）：已更新为 203.0.113.10',
      );
    });

    test('一轮上报：查不到出口 IP / 整轮出错 / 核心无响应', () {
      const nodes = [MeowAkileNode(ruleId: 1), MeowAkileNode(ruleId: 2)];
      final noIp = parseAkileReport(
        json.encode({
          'ip_error': 'ip.3322.net：超时',
          'results': [
            {'rule_id': 1, 'kind': 'failed', 'error': '查不到本机直连出口 IPv4'},
            {'rule_id': 2, 'kind': 'failed', 'error': '查不到本机直连出口 IPv4'},
          ],
        }),
        nodes,
      );
      expect(noIp.ip, '');
      expect(noIp.ipError, 'ip.3322.net：超时');
      expect(noIp.results.values.map((r) => r.error), ['查不到本机直连出口 IPv4', '查不到本机直连出口 IPv4']);

      final bad = parseAkileReport('{"error":"API Key 应以 ak_ 开头","results":[]}', nodes);
      expect(bad.error, 'API Key 应以 ak_ 开头');
      expect(bad.results.values.every((r) => !r.ok), isTrue);

      final none = parseAkileReport('', nodes);
      expect(none.error, '核心无响应');
      expect(none.results.keys, [1, 2]);
    });
  });
}
