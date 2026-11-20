import 'dart:convert';

import 'package:bett_box/meowx/panel/po0.dart';
import 'package:bett_box/meowx/panel/whitelist_common.dart';
import 'package:bett_box/models/meow.dart';
import 'package:flutter_test/flutter_test.dart';

// po0 加白结果的解析 / 判定 / 同段 / 脱敏（规格：MeowX 仓库 Design/po0-ggy-results.md §1、§5）。只用假 token。

const _url = 'https://203.0.113.9/api/firewall/pgnfw_FAKEtoken00001234/add';
const _slotUrl = 'https://203.0.113.9:8443/api/firewall/pgnfw_FAKEtoken00001234/add?slot=2';
final _at = DateTime(2026, 11, 20, 14, 30);

Po0Result _judge(String url, {int status = 200, Object? body, String error = ''}) => Po0Result.judge(
  Po0ReportResult(url: url, status: status, body: body is String ? body : json.encode(body), error: error),
  at: _at,
);

void main() {
  group('同段判断（sameC24）', () {
    test('相等算同一个', () {
      expect(po0SameC24('1.2.3.4', '1.2.3.4'), isTrue);
      expect(po0SameC24('1.2.3.0/24', '1.2.3.0/24'), isTrue);
      expect(po0SameC24('2001:db8::1', '2001:db8::1'), isTrue);
    });

    test('任一边是 /24：前三段相同算同一个', () {
      expect(po0SameC24('1.2.3.0/24', '1.2.3.77'), isTrue);
      expect(po0SameC24('1.2.3.77', '1.2.3.0/24'), isTrue);
      expect(po0SameC24('1.2.3.0/24', '1.2.4.77'), isFalse);
      expect(po0SameC24('9.2.3.0/24', '1.2.3.77'), isFalse);
    });

    test('两边都是精确 IP：必须全等；IPv6 只按全等；空串不算', () {
      expect(po0SameC24('1.2.3.4', '1.2.3.5'), isFalse);
      expect(po0SameC24('2001:db8::1', '2001:db8::2'), isFalse);
      expect(po0SameC24('2001:db8::/24', '2001:db8::1'), isFalse);
      expect(po0SameC24('', ''), isFalse);
      expect(po0SameC24(' 1.2.3.4 ', '1.2.3.4'), isTrue);
    });
  });

  group('名单解析', () {
    test('对象写法：ip + slot（null = 普通条目），按应答顺序', () {
      final w = Po0Whitelist.parse(
        json.encode({
          'enabled': true,
          'whitelist': [
            {'ip': '1.2.3.0/24', 'slot': 1},
            {'ip': '5.6.7.8', 'slot': null},
            {'ip': '9.9.9.9'},
          ],
          'limit': 5,
          'currentIp': '1.2.3.4',
        }),
      )!;
      expect(w.entries, const [
        Po0WhitelistEntry(ip: '1.2.3.0/24', slot: 1),
        Po0WhitelistEntry(ip: '5.6.7.8'),
        Po0WhitelistEntry(ip: '9.9.9.9'),
      ]);
      expect(w.count, 3);
      expect(w.limit, 5);
    });

    test('旧版字符串写法 = 没有槽位；两种混着也认', () {
      final w = Po0Whitelist.parse(
        '{"enabled":true,"whitelist":["1.2.3.4",{"ip":"5.6.7.8","slot":"3"}],"limit":5,"currentIp":"1.2.3.4"}',
      )!;
      expect(w.entries, const [Po0WhitelistEntry(ip: '1.2.3.4'), Po0WhitelistEntry(ip: '5.6.7.8', slot: 3)]);
    });

    test('不是 JSON 对象 → null', () {
      expect(Po0Whitelist.parse(''), isNull);
      expect(Po0Whitelist.parse('<html>'), isNull);
      expect(Po0Whitelist.parse('[1,2]'), isNull);
    });
  });

  group('判定', () {
    test('200、开着、名单里有本机（/24 与精确 IP 混杂）→ 已加白', () {
      final r = _judge(
        _slotUrl,
        body: {
          'enabled': true,
          'whitelist': [
            {'ip': '5.6.7.8', 'slot': null},
            {'ip': '1.2.3.0/24', 'slot': 2},
          ],
          'limit': 5,
          'currentIp': '1.2.3.4',
        },
      );
      expect(r.kind, Po0ResultKind.success);
      expect(r.summary, '已加白 · 2/5');
      expect(r.slot, 2);
      expect(r.selfIndex, 1);
      expect(r.currentIp, '1.2.3.4');
      expect(r.message, '');
      expect(r.overview, '防火墙已开启 · 名单 2/5');
      expect(r.hasWhitelist, isTrue);
    });

    test('currentIp 是 /24、名单里是精确 IP 也算同段', () {
      final r = _judge(_url, body: '{"enabled":true,"whitelist":["1.2.3.77"],"limit":5,"currentIp":"1.2.3.0/24"}');
      expect(r.kind, Po0ResultKind.success);
      expect(r.slot, isNull);
      expect(r.selfIndex, 0);
    });

    test('enabled:false → po0 没有开启防火墙', () {
      final r = _judge(_url, body: '{"enabled":false,"whitelist":[],"limit":5,"currentIp":"1.2.3.4"}');
      expect(r.kind, Po0ResultKind.disabled);
      expect(r.summary, 'po0 没有开启防火墙');
      expect(r.overview, '防火墙未开启');
      expect(r.enabled, isFalse);
    });

    test('开着但名单里没有本机 → 加白未生效', () {
      final r = _judge(
        _url,
        body: '{"enabled":true,"whitelist":["5.6.7.8","1.2.4.0/24"],"limit":5,"currentIp":"1.2.3.4"}',
      );
      expect(r.kind, Po0ResultKind.notApplied);
      expect(r.summary, '加白未生效 · 2/5');
      expect(r.selfIndex, -1);
    });

    group('缺字段时信 200（老版 po0 只回个确认）', () {
      test('空对象 {}：enabled 缺省按开启、没名单没 currentIp → 已加白（不带条数）', () {
        final r = _judge(_url, body: '{}');
        expect(r.kind, Po0ResultKind.success);
        expect(r.summary, '已加白');
        expect(r.enabled, isTrue);
        expect(r.entries, isNull);
        expect(r.currentIp, isNull);
        expect(r.selfIndex, -1);
        expect(r.overview, '防火墙已开启');
        expect(r.hasWhitelist, isTrue);
      });

      test('只有 limit：已加白（没有名单就不知道条数）', () {
        final r = _judge(_url, body: {'limit': 5});
        expect(r.kind, Po0ResultKind.success);
        expect(r.summary, '已加白');
        expect(r.limit, 5);
        expect(r.entries, isNull);
      });

      test('名单是空数组 [] 但有 limit：照写「已加白 · 0/limit」（区分「没有名单」与「名单是空的」）', () {
        final r = _judge(_url, body: {'whitelist': [], 'limit': 5});
        expect(r.kind, Po0ResultKind.success);
        expect(r.summary, '已加白 · 0/5');
        expect(r.entries, isEmpty);
        expect(r.overview, '防火墙已开启 · 名单 0/5');
        // 对比：没有名单字段 → 只写「已加白」
        expect(_judge(_url, body: {'limit': 5}).summary, '已加白');
      });

      test('只有名单没有 currentIp：无从比对 → 已加白，有 limit 带条数，不标本机', () {
        final r = _judge(_url, body: {
          'enabled': true,
          'whitelist': ['5.6.7.8', '9.9.9.9'],
          'limit': 5,
        });
        expect(r.kind, Po0ResultKind.success);
        expect(r.summary, '已加白 · 2/5');
        expect(r.selfIndex, -1);
        expect(r.overview, '防火墙已开启 · 名单 2/5');
        // 没有 limit：只写「已加白」
        expect(_judge(_url, body: {'whitelist': ['5.6.7.8']}).summary, '已加白');
      });

      test('只有 currentIp 没有名单 → 已加白；名单与 currentIp 都有才可能判未生效', () {
        expect(_judge(_url, body: {'currentIp': '1.2.3.4', 'limit': 5}).kind, Po0ResultKind.success);
        final miss = _judge(_url, body: {'whitelist': ['5.6.7.8'], 'currentIp': '1.2.3.4'});
        expect(miss.kind, Po0ResultKind.notApplied);
        expect(miss.summary, '加白未生效');
      });

      test('只有 enabled:false 才算没开防火墙；enabled 写成别的值按开启', () {
        expect(_judge(_url, body: {'enabled': false}).kind, Po0ResultKind.disabled);
        expect(_judge(_url, body: {'enabled': 'yes'}).kind, Po0ResultKind.success);
        expect(_judge(_url, body: {'enabled': null}).kind, Po0ResultKind.success);
      });

      test('200 但空正文 / 不是 JSON 对象：仍是失败「应答无法解析」', () {
        expect(_judge(_url, body: '').summary, '失败：应答无法解析');
        expect(_judge(_url, body: '  ').summary, '失败：应答无法解析');
        expect(_judge(_url, body: '"ok"').summary, '失败：应答无法解析');
        expect(_judge(_url, body: 'OK').summary, '失败：应答无法解析');
      });
    });

    test('403 带槽位 → 槽位冲突（正文是 JSON 时记下 currentIp）', () {
      final r = _judge(_slotUrl, status: 403, body: '{"error":"slot taken","currentIp":"1.2.3.4"}');
      expect(r.kind, Po0ResultKind.slotConflict);
      expect(r.summary, '槽位冲突：本机 IP 已在这台 po0 的其它槽位，先到 po0 面板删除旧槽位');
      expect(r.currentIp, '1.2.3.4');
      expect(r.slot, 2);
      expect(r.hasWhitelist, isFalse);
    });

    test('403 不带槽位 → token 无效', () {
      final r = _judge(_url, status: 403, body: 'forbidden');
      expect(r.kind, Po0ResultKind.invalidToken);
      expect(r.summary, 'token 无效');
      expect(r.currentIp, isNull);
    });

    test('200 但不是 JSON 对象 → 失败：应答无法解析；别的状态码 → HTTP <码>', () {
      expect(_judge(_url, body: '<html>blocked</html>').summary, '失败：应答无法解析');
      expect(_judge(_url, body: '').summary, '失败：应答无法解析');
      expect(_judge(_url, body: '[]').kind, Po0ResultKind.failed);
      expect(_judge(_url, status: 502, body: 'bad gateway').summary, '失败：HTTP 502');
    });

    test('连不上：原因去掉 url.Error 带的地址，token 一律脱敏', () {
      final r = _judge(_slotUrl, status: 0, error: 'Post "$_slotUrl": dial tcp 203.0.113.9:8443: i/o timeout');
      expect(r.kind, Po0ResultKind.failed);
      expect(r.summary, '失败：dial tcp 203.0.113.9:8443: i/o timeout');
      // 错误里还散落着 token（别的格式）也要换掉
      final r2 = _judge(
        _url,
        status: 0,
        error: 'weird pgnfw_FAKEtoken00001234 at /api/firewall/pgnfw_FAKEtoken00001234/add',
      );
      expect(r2.message, 'weird pgnfw_••••1234 at /api/firewall/pgnfw_••••1234/add');
      expect(r2.summary, isNot(contains('FAKEtoken')));
    });

    test('槽位从上报地址取', () {
      expect(po0SlotFromUrl(_slotUrl), 2);
      expect(po0SlotFromUrl(_url), isNull);
      expect(po0SlotFromUrl('https://x/api/firewall/t/add?slot=abc'), isNull);
    });
  });

  group('显示', () {
    test('上报地址 → 地址 · 脱敏 token[@N]', () {
      expect(po0UrlLabel(_url), '203.0.113.9 · pgnfw_••••1234');
      expect(po0UrlLabel(_slotUrl), '203.0.113.9:8443 · pgnfw_••••1234@2');
      expect(
        po0UrlLabel('https://[2001:db8::1]:8443/api/firewall/pgnfw_FAKEtoken00001234/add'),
        '[2001:db8::1]:8443 · pgnfw_••••1234',
      );
    });

    test('自定义条目：有备注时标题 = 备注、副标题 = 地址 · 脱敏 token；没备注照旧', () {
      const c = Po0CustomServer(address: 'fw.example.com:8443', token: 'pgnfw_FAKEtoken00001234@3');
      expect(po0CustomLabels(c), ('fw.example.com:8443', 'pgnfw_••••1234@3'));
      expect(po0CustomLabels(c.copyWith(note: '洛杉矶 po0')), ('洛杉矶 po0', 'fw.example.com:8443 · pgnfw_••••1234@3'));
    });

    test('老数据没有 note 字段 = 没有备注；新字段落盘', () {
      final old = Po0CustomServer.fromJson({'address': '1.2.3.4', 'token': 'pgnfw_FAKEtoken00001234'});
      expect(old.note, '');
      expect(old.copyWith(note: 'x').toJson()['note'], 'x');
    });
  });

  group('备注与时间（共用）', () {
    test('备注：去掉首尾空白，最多 40 个字符（按 Unicode 字符数）', () {
      expect(normalizeWhitelistNote('  香港 po0  '), '香港 po0');
      expect(normalizeWhitelistNote('   '), '');
      expect(normalizeWhitelistNote('a' * 41).length, 40);
      final emoji = '🐱' * 45;
      final n = normalizeWhitelistNote(emoji);
      expect(n.runes.length, 40);
      expect(n, '🐱' * 40);
    });

    test('上次上报时间：刚刚 / N 分钟前 / HH:mm / 跨天写日期', () {
      final t = DateTime(2026, 11, 20, 9, 5);
      expect(fmtReportTime(t, t.add(const Duration(seconds: 59))), '刚刚');
      expect(fmtReportTime(t, t.subtract(const Duration(minutes: 3))), '刚刚');
      expect(fmtReportTime(t, t.add(const Duration(minutes: 59))), '59 分钟前');
      expect(fmtReportTime(t, t.add(const Duration(hours: 2))), '09:05');
      expect(fmtReportTime(t, DateTime(2026, 11, 21, 0, 10)), '11-20 09:05');
      expect(fmtReportTime(t, DateTime(2027, 1, 2)), '2026-11-20 09:05');
    });
  });
}
