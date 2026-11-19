import 'dart:convert';

import 'package:bett_box/meowx/config/subscription_meta.dart';
import 'package:bett_box/meowx/panel/realtime.dart';
import 'package:flutter_test/flutter_test.dart';

// 内核实时通道（core/meow_realtime.go 的 meowRealtime 动作）的 Dart 调用与回包解析。

void main() {
  group('CoreRealtime', () {
    late List<Map<String, Object?>> sent;
    late String reply;
    late CoreRealtime core;

    setUp(() {
      sent = [];
      reply = '{}';
      core = CoreRealtime((p) async {
        sent.add(json.decode(json.encode(p)) as Map<String, Object?>);
        return reply;
      });
    });

    test('configure 交通道与各订阅 rev；内核报错原样回', () async {
      const plan = RealtimePlan(
        channels: [RealtimeChannelPlan.token('https://panel.example.com', 'tok'), RealtimeChannelPlan.rt('https://m.example.com', 'rt1')],
        subs: [SubRevNote('https://m.example.com', 'pkg:1', 'r')],
      );
      expect(await core.configure(plan), isNull);
      expect(sent.single, {
        'op': 'configure',
        'channels': [
          {'base': 'https://panel.example.com', 'token': 'tok'},
          {'base': 'https://m.example.com', 'rt': 'rt1'},
        ],
        'subs': [
          {'base': 'https://m.example.com', 'key': 'pkg:1', 'rev': 'r'},
        ],
      });
      reply = '{"error":"主控地址无效"}';
      expect(await core.configure(plan), '主控地址无效');
      reply = '';
      expect(await core.configure(plan), isNotNull, reason: '核心没回应也算没交成功');
    });

    test('待更新队列与 ack', () async {
      reply = '{"items":[{"base":"https://m.example.com","key":"pkg:1","rev":"r2","at":5},{"base":"https://m.example.com","key":"","rev":""}]}';
      final items = await core.pending();
      expect(items, const [
        SubChange(base: 'https://m.example.com', key: 'pkg:1', rev: 'r2'),
        SubChange(base: 'https://m.example.com', key: '', rev: ''),
      ]);
      expect(items.first.at, 5);
      await core.ack(items.take(1).toList());
      expect(sent.last, {
        'op': 'ack',
        'items': [
          {'base': 'https://m.example.com', 'key': 'pkg:1', 'rev': 'r2'},
        ],
      });
      sent.clear();
      await core.ack(const []);
      expect(sent, isEmpty);
      reply = 'not json';
      expect(await core.pending(), isEmpty);
    });

    test('clear 只按主控清；空地址不发（内核那边空 = 全部）', () async {
      reply = '{"cleared":3}';
      expect(await core.clear('https://panel.example.com'), 3);
      expect(sent.single, {'op': 'clear', 'source': 'https://panel.example.com'});
      expect(await core.clear(''), 0);
      expect(sent.length, 1);
    });

    test('entries：只留有 IP 的', () async {
      reply = json.encode({
        'entries': [
          {'server': 'hk-entry.example.com', 'ips': ['203.0.113.11', '203.0.113.12'], 'rev': 1794000123456, 'chainId': 7, 'source': 'https://panel.example.com', 'updatedAt': 1794000123999, 'confirmedAt': 1, 'active': true},
          {'server': 'gone.example.com', 'ips': null, 'rev': 1, 'active': true},
        ],
      });
      final list = await core.entries();
      expect(list.length, 1);
      expect(list.single.ips, ['203.0.113.11', '203.0.113.12']);
      expect(list.single.chainId, 7);
      expect(list.single.active, isTrue);
      expect(sent.single, {'op': 'entries'});
    });
  });

  group('节点 server ↔ 入口覆盖的键（同内核 NormalizeKey）', () {
    test('域名小写、去结尾的点；IPv6 去方括号 / zone、按地址比；IPv4-mapped 还原成 IPv4', () {
      expect(entryKeyOf('HK-Entry.Example.com.'), 'hk-entry.example.com');
      expect(entryKeyOf('[2001:db8::1]'), entryKeyOf('2001:0db8:0:0::1'));
      expect(entryKeyOf('fe80::1%en0'), entryKeyOf('fe80::1'));
      expect(entryKeyOf('::ffff:198.51.100.20'), '198.51.100.20');
      expect(entryKeyOf(' 198.51.100.20 '), '198.51.100.20');
    });

    test('主控给了入口端口：节点端口在里面才算；空集合谁都不算；老主控没给端口只比 server', () {
      const entries = [
        EntryOverride(server: '198.51.100.20', ips: ['198.51.100.21', '198.51.100.22'], active: true, ports: [50520, 50523]),
        EntryOverride(server: 'empty.example.com', ips: ['203.0.113.1'], active: true, ports: []),
        EntryOverride(server: 'old.example.com', ips: ['203.0.113.2'], active: true),
      ];
      expect(entryOverrideFor('198.51.100.20', entries, port: 50523)?.ips, ['198.51.100.21', '198.51.100.22']);
      // 入口机器上另开的直连节点：同一个 server、端口不在里面
      expect(entryOverrideFor('198.51.100.20', entries, port: 443), isNull);
      expect(entryOverrideFor('198.51.100.20', entries), isNull);
      expect(entryOverrideFor('empty.example.com', entries, port: 443), isNull);
      expect(entryOverrideFor('old.example.com', entries, port: 443)?.ips, ['203.0.113.2']);
    });

    test('解析内核的 ports：没有字段 / null = 没给，数组照收', () {
      expect(EntryOverride.fromJson({'server': 'a', 'ips': ['1.1.1.1']}).ports, isNull);
      expect(EntryOverride.fromJson({'server': 'a', 'ips': ['1.1.1.1'], 'ports': null}).ports, isNull);
      expect(EntryOverride.fromJson({'server': 'a', 'ips': ['1.1.1.1'], 'ports': []}).ports, isEmpty);
      expect(EntryOverride.fromJson({'server': 'a', 'ips': ['1.1.1.1'], 'ports': [50520, 50523]}).ports, [50520, 50523]);
    });

    test('只认当前配置里用着的（active）', () {
      const entries = [
        EntryOverride(server: 'hk-entry.example.com', ips: ['203.0.113.11'], active: true),
        EntryOverride(server: '2001:db8::1', ips: ['2001:db8::2'], active: true),
        EntryOverride(server: 'idle.example.com', ips: ['203.0.113.9'], active: false),
      ];
      expect(entryOverrideFor('HK-ENTRY.example.com', entries)?.ips, ['203.0.113.11']);
      expect(entryOverrideFor('[2001:DB8::1]', entries)?.ips, ['2001:db8::2']);
      expect(entryOverrideFor('idle.example.com', entries), isNull);
      expect(entryOverrideFor('other.example.com', entries), isNull);
      expect(entryOverrideFor('', entries), isNull);
    });

    test('详情文字：IP + 切换时间', () {
      final at = DateTime(2026, 11, 16, 12);
      final e = EntryOverride(server: 'hk', ips: const ['203.0.113.11', '203.0.113.12'], updatedAt: at.millisecondsSinceEpoch, active: true);
      expect(entryOverrideLabel(e, now: at.add(const Duration(minutes: 3))), '主控指定入口 203.0.113.11, 203.0.113.12 · 3 分钟前');
      expect(entryOverrideLabel(const EntryOverride(server: 'hk', ips: ['1.2.3.4'])), '主控指定入口 1.2.3.4');
    });

    test('入口服务器名称：有名称写「名称（IP）」，没名称的 IP 只写 IP', () {
      final at = DateTime(2026, 11, 19, 12);
      final e = EntryOverride.fromJson({
        'server': 'hk',
        'ips': ['203.0.113.11', '203.0.113.12'],
        'updatedAt': at.millisecondsSinceEpoch,
        'active': true,
        'names': {'203.0.113.11': '香港入口 A'},
      });
      expect(entryOverrideLabel(e, now: at.add(const Duration(minutes: 3))), '主控指定入口 香港入口 A（203.0.113.11）, 203.0.113.12 · 3 分钟前');
    });

    test('入口服务器名称的解析：没有 / 形状不对 = 没有，值不是字符串或空白的跳过', () {
      EntryOverride parse(Object? names) => EntryOverride.fromJson({'server': 'a', 'ips': ['1.1.1.1'], 'names': ?names});
      expect(parse(null).names, isNull);
      expect(parse(['1.1.1.1']).names, isNull);
      expect(parse('x').names, isNull);
      expect(parse({'1.1.1.1': 5, '2.2.2.2': '  '}).names, isNull);
      expect(parse({'1.1.1.1': ' 香港入口 A ', '2.2.2.2': null}).names, {'1.1.1.1': '香港入口 A'});
    });

    test('同一个 rev 补上名称也算变了（界面要跟着换）', () {
      const a = EntryOverride(server: 'hk', ips: ['1.1.1.1'], rev: 1, active: true);
      const b = EntryOverride(server: 'hk', ips: ['1.1.1.1'], rev: 1, active: true, names: {'1.1.1.1': '香港入口 A'});
      expect(a == b, isFalse);
      expect(b == const EntryOverride(server: 'hk', ips: ['1.1.1.1'], rev: 1, active: true, names: {'1.1.1.1': '香港入口 A'}), isTrue);
    });
  });
}
