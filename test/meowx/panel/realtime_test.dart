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
  });
}
