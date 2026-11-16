import 'dart:io';

import 'package:bett_box/meowx/config/subscription_meta.dart';
import 'package:bett_box/meowx/state/realtime_sync.dart';
import 'package:bett_box/meowx/state/subscription_meta_store.dart';
import 'package:flutter_test/flutter_test.dart';

// 订阅自动更新（规格 §3.3）：内核的待更新队列 → 重拉 → ack；拉订阅时记下的应答头落盘。

const _m = 'https://m.example.com';

class _Harness {
  _Harness(this.profiles);

  List<SubscriptionProfileRef> profiles;
  List<SubChange> queue = [];
  final acked = <SubChange>[];
  final refreshed = <String>[];
  final failing = <String>{};
  final logs = <String>[];
  var panelChanged = 0;
  DateTime now = DateTime(2026, 11, 16, 12);
  PanelLogin? login;

  late final drainer = SubscriptionPushDrainer(
    pending: () async => List.of(queue),
    ack: (items) async {
      acked.addAll(items);
      queue = [for (final q in queue) if (!items.contains(q)) q];
    },
    profiles: () => profiles,
    login: () => login,
    refresh: (id) async {
      refreshed.add(id);
      if (failing.contains(id)) throw StateError('网络不通');
      // 拉完记下主控给的新 rev（同 Profile.update 记应答头）
      profiles = [
        for (final p in profiles)
          p.id == id && p.meta != null
              ? SubscriptionProfileRef(
                  id: p.id,
                  url: p.url,
                  meta: SubscriptionMeta(url: p.url, key: p.meta!.key, rev: 'fresh', realtimeUrl: _m, realtime: 't'),
                )
              : p,
      ];
    },
    log: logs.add,
    onLoggedInPanelChanged: () => panelChanged++,
    now: () => now,
  );
}

SubscriptionProfileRef _p(String id, String key, String rev) =>
    SubscriptionProfileRef(id: id, url: 'https://s.example.com/x/$id', meta: SubscriptionMeta(url: 'https://s.example.com/x/$id', key: key, rev: rev, realtimeUrl: _m, realtime: 't'));

void main() {
  group('订阅待更新队列', () {
    test('重拉成功的 ack；rev 已经一样的不拉、也 ack', () async {
      final h = _Harness([_p('a', 'pkg:1', 'old'), _p('b', 'pkg:2', 'same')]);
      addTearDown(h.drainer.dispose);
      h.queue = const [SubChange(base: _m, key: 'pkg:1', rev: 'new'), SubChange(base: _m, key: 'pkg:2', rev: 'same')];
      await h.drainer.drain();
      expect(h.refreshed, ['a']);
      expect(h.acked.length, 2);
      expect(h.queue, isEmpty);
      expect(h.drainer.scheduledIn, isNull);
    });

    test('一遍里同一个档只拉一次（带键的与不带键的都点到它）', () async {
      final h = _Harness([_p('a', 'pkg:1', 'old')]);
      addTearDown(h.drainer.dispose);
      h.queue = const [SubChange(base: _m, key: 'pkg:1', rev: 'new'), SubChange(base: _m, key: '', rev: '')];
      await h.drainer.drain();
      expect(h.refreshed, ['a']);
      expect(h.acked.length, 2);
    });

    test('重拉失败的留在队列里，按退避重试；成功一次后退避从头算', () async {
      final h = _Harness([_p('a', 'pkg:1', 'old')]);
      addTearDown(h.drainer.dispose);
      h.failing.add('a');
      h.queue = const [SubChange(base: _m, key: 'pkg:1', rev: 'new')];
      await h.drainer.drain();
      expect(h.acked, isEmpty);
      expect(h.queue.length, 1);
      expect(h.drainer.scheduledIn, const Duration(minutes: 1));
      expect(h.logs.single, contains('重拉失败'));

      // 30 秒内再叫：被节流，等到 30 秒满（比 2 分钟的重试近）
      h.now = h.now.add(const Duration(seconds: 10));
      await h.drainer.drain();
      expect(h.refreshed, ['a']);
      expect(h.drainer.scheduledIn, const Duration(seconds: 20));

      h.now = h.now.add(const Duration(minutes: 1));
      await h.drainer.drain();
      expect(h.refreshed, ['a', 'a']);
      expect(h.drainer.scheduledIn, const Duration(minutes: 2), reason: '连着第二次失败');

      h.failing.clear();
      h.now = h.now.add(const Duration(minutes: 2));
      await h.drainer.drain();
      expect(h.queue, isEmpty);
      expect(h.drainer.scheduledIn, isNull);
    });

    test('登录着的主控来了变更：顺带刷新「我的订阅」列表', () async {
      final h = _Harness([_p('a', 'pkg:1', 'old')]);
      addTearDown(h.drainer.dispose);
      h.queue = const [SubChange(base: _m, key: 'pkg:9', rev: 'x')];
      await h.drainer.drain();
      expect(h.panelChanged, 0);
      h.login = PanelLogin.of(_m, 'tok');
      h.queue = const [SubChange(base: _m, key: 'pkg:9', rev: 'y')];
      await h.drainer.drain();
      expect(h.panelChanged, 1);
    });

    test('队列空：什么都不做', () async {
      final h = _Harness([_p('a', 'pkg:1', 'old')]);
      addTearDown(h.drainer.dispose);
      await h.drainer.drain();
      expect(h.refreshed, isEmpty);
      expect(h.acked, isEmpty);
    });
  });

  group('应答头落盘', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('meowx-meta-'));
    tearDown(() => dir.deleteSync(recursive: true));

    test('记下、换个实例读回来、去掉删掉的档', () async {
      final path = '${dir.path}/meowx-sub-meta.json';
      final s1 = SubscriptionMetaStore(path: () async => path);
      const a = SubscriptionMeta(url: 'https://s/x/a', key: 'pkg:1', rev: 'r1', realtimeUrl: _m, realtime: 't', updatedAt: 1);
      const b = SubscriptionMeta(url: 'https://s/x/b', updatedAt: 2);
      await s1.record('a', a);
      await s1.record('b', b);
      expect(s1.metas.value, {'a': a, 'b': b});

      final s2 = SubscriptionMetaStore(path: () async => path);
      await s2.load();
      expect(s2.metas.value, {'a': a, 'b': b});

      await s2.remove({'b', 'gone'});
      final s3 = SubscriptionMetaStore(path: () async => path);
      await s3.load();
      expect(s3.metas.value, {'a': a});
    });

    test('文件坏了 / 不存在：当作没有记录', () async {
      final path = '${dir.path}/meowx-sub-meta.json';
      File(path).writeAsStringSync('{oops');
      final s = SubscriptionMetaStore(path: () async => path);
      await s.load();
      expect(s.metas.value, isEmpty);
      final none = SubscriptionMetaStore(path: () async => '${dir.path}/none.json');
      await none.load();
      expect(none.metas.value, isEmpty);
    });
  });
}
