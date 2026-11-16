import 'package:bett_box/meowx/config/subscription_meta.dart';
import 'package:flutter_test/flutter_test.dart';

// 主控实时通道 / 订阅自动更新的纯逻辑（规格 MeowX 仓库 Design/entry-realtime.md §2.3 / §3.2 / §3.3）。

SubscriptionMeta _meta(String url, {String key = '', String rev = '', String rtUrl = '', String rt = '', int at = 0}) =>
    SubscriptionMeta(url: url, key: key, rev: rev, realtimeUrl: rtUrl, realtime: rt, updatedAt: at);

SubscriptionProfileRef _p(String id, String url, [SubscriptionMeta? meta]) => SubscriptionProfileRef(id: id, url: url, meta: meta);

void main() {
  group('主控地址规范化（与内核 panelrt.NormalizeBase 同口径）', () {
    test('补 https、host 小写、去路径与结尾斜杠', () {
      expect(normalizePanelBase('Panel.Example.COM'), 'https://panel.example.com');
      expect(normalizePanelBase('https://panel.example.com/'), 'https://panel.example.com');
      expect(normalizePanelBase('https://panel.example.com/api/x?y=1'), 'https://panel.example.com');
      expect(normalizePanelBase('http://10.0.0.1:8080/'), 'http://10.0.0.1:8080');
      expect(normalizePanelBase('https://[2001:db8::1]:8443/x'), 'https://[2001:db8::1]:8443');
    });
    test('无效的回 null', () {
      expect(normalizePanelBase(''), isNull);
      expect(normalizePanelBase('  '), isNull);
      expect(normalizePanelBase(null), isNull);
      expect(normalizePanelBase('ftp://a.example.com'), isNull);
    });
    test('规范化是幂等的（内核拿到的就是回调里给回来的 base）', () {
      for (final s in ['a.example.com', 'https://A.example.com:8443/p', 'https://[::1]']) {
        final once = normalizePanelBase(s)!;
        expect(normalizePanelBase(once), once);
      }
    });
  });

  group('应答头记录', () {
    test('四个头都取、去空白；订阅键只认应答头', () {
      final headers = {
        'mmwx-sub-key': ' pkg:12 ',
        'mmwx-sub-rev': '9b1e0c3a77d2',
        'mmwx-realtime-url': 'https://master.example.com',
        'mmwx-realtime': 'rt-token',
      };
      final m = SubscriptionMeta.fromHeaders('https://sub.example.com/x/abc', (n) => headers[n], now: 42);
      expect(m.key, 'pkg:12');
      expect(m.rev, '9b1e0c3a77d2');
      expect(m.realtimeBase, 'https://master.example.com');
      expect(m.realtime, 'rt-token');
      expect(m.hasRealtimeCredential, isTrue);
      expect(m.updatedAt, 42);
    });
    test('旧主控 / 别家机场没有这些头：全空，不从地址猜键', () {
      final m = SubscriptionMeta.fromHeaders('https://panel.example.com/api/clash/subscribe?filename=a.yaml', (_) => null, now: 1);
      expect(m.key, isEmpty);
      expect(m.rev, isEmpty);
      expect(m.hasRealtimeCredential, isFalse);
    });
    test('凭证缺通道地址不算', () {
      expect(_meta('https://a', rt: 'x').hasRealtimeCredential, isFalse);
      expect(_meta('https://a', rtUrl: 'https://m').hasRealtimeCredential, isFalse);
    });
    test('JSON 来回', () {
      final m = _meta('https://a/x', key: 'file:a.yaml', rev: 'r', rtUrl: 'https://m', rt: 't', at: 7);
      expect(SubscriptionMeta.fromJson(m.toJson()), m);
      expect(SubscriptionMeta.fromJson(_meta('https://a').toJson()), _meta('https://a'));
    });
    test('档案换了地址：旧记录作废', () {
      final p = _p('1', 'https://new.example.com/sub', _meta('https://old.example.com/sub', key: 'pkg:1'));
      expect(p.currentMeta, isNull);
    });
  });

  group('要连哪些主控', () {
    final login = PanelLogin.of('panel.example.com', 'tok')!;

    test('登录了：用会话 token 连它；它自己的订阅给的 rt 不再另连', () {
      final plan = planRealtime(
        login: login,
        profiles: [
          _p('a', 'https://panel.example.com/x/aaa', _meta('https://panel.example.com/x/aaa', key: 'pkg:1', rev: 'r1', rtUrl: 'https://panel.example.com', rt: 'rt-a')),
          // 订阅域名与主控不同，但应答说通道在登录的主控上
          _p('b', 'https://sub.example.net/x/bbb', _meta('https://sub.example.net/x/bbb', key: 'file:b.yaml', rev: 'r2', rtUrl: 'https://PANEL.example.com/', rt: 'rt-b')),
        ],
        currentProfileId: 'a',
      );
      expect(plan.channels, [const RealtimeChannelPlan.token('https://panel.example.com', 'tok')]);
      expect(plan.subs.toSet(), {
        const SubRevNote('https://panel.example.com', 'pkg:1', 'r1'),
        const SubRevNote('https://panel.example.com', 'file:b.yaml', 'r2'),
      });
    });

    test('订阅地址就在登录的主控上：哪怕应答给的通道地址是别名，也归登录的主控', () {
      final plan = planRealtime(
        login: login,
        profiles: [
          _p('a', 'https://panel.example.com/x/aaa', _meta('https://panel.example.com/x/aaa', key: 'pkg:1', rev: 'r1', rtUrl: 'https://master.example.com', rt: 'rt-a')),
        ],
        currentProfileId: null,
      );
      expect(plan.channels, [const RealtimeChannelPlan.token('https://panel.example.com', 'tok')]);
      expect(plan.subs.single.base, 'https://panel.example.com');
    });

    test('没登录的主控：一个主控一条 rt，优先当前在用的订阅，其次最近拉过的', () {
      final plan = planRealtime(
        login: null,
        profiles: [
          _p('old', 'https://s1.example.com/x/1', _meta('https://s1.example.com/x/1', key: 'pkg:1', rev: 'a', rtUrl: 'https://m1.example.com', rt: 'rt-old', at: 100)),
          _p('cur', 'https://s1.example.com/x/2', _meta('https://s1.example.com/x/2', key: 'pkg:2', rev: 'b', rtUrl: 'https://m1.example.com', rt: 'rt-cur', at: 50)),
          _p('n1', 'https://s2.example.com/x/3', _meta('https://s2.example.com/x/3', key: 'pkg:3', rev: 'c', rtUrl: 'https://m2.example.com', rt: 'rt-n1', at: 10)),
          _p('n2', 'https://s2.example.com/x/4', _meta('https://s2.example.com/x/4', key: 'pkg:4', rev: 'd', rtUrl: 'https://m2.example.com', rt: 'rt-n2', at: 20)),
          // 别家机场：没有凭证
          _p('x', 'https://airport.example.org/sub', _meta('https://airport.example.org/sub')),
          // 这个版本还没拉过（升级前导入的）
          _p('y', 'https://s3.example.com/x/5'),
        ],
        currentProfileId: 'cur',
      );
      expect(plan.channels, [
        const RealtimeChannelPlan.rt('https://m1.example.com', 'rt-cur'),
        const RealtimeChannelPlan.rt('https://m2.example.com', 'rt-n2'),
      ]);
      expect(plan.bases, {'https://m1.example.com', 'https://m2.example.com'});
      expect(plan.subs.map((s) => s.base).toSet(), {'https://m1.example.com', 'https://m2.example.com'});
      expect(plan.subs.length, 4);
    });

    test('什么都没有：空计划（内核停掉全部通道）', () {
      final plan = planRealtime(login: null, profiles: [_p('x', 'https://airport.example.org/sub')], currentProfileId: 'x');
      expect(plan.channels, isEmpty);
      expect(plan.subs, isEmpty);
      expect(PanelLogin.of('panel.example.com', ''), isNull);
      expect(PanelLogin.of('', 'tok'), isNull);
    });
  });

  group('一条订阅变更要重拉哪些档', () {
    const m1 = 'https://m1.example.com';
    final profiles = [
      _p('a', 'https://s1.example.com/x/1', _meta('https://s1.example.com/x/1', key: 'pkg:12', rev: 'old', rtUrl: m1, rt: 't')),
      _p('b', 'https://s1.example.com/x/2', _meta('https://s1.example.com/x/2', key: 'file:b.yaml', rev: 'same', rtUrl: m1, rt: 't')),
      // 旧主控拉的：没有键
      _p('c', 'https://m1.example.com/api/clash/subscribe?filename=c.yaml', _meta('https://m1.example.com/api/clash/subscribe?filename=c.yaml')),
      // 升级前导入、这个版本还没拉过
      _p('d', 'https://m1.example.com/x/4'),
      // 别的主控
      _p('e', 'https://s9.example.com/x/9', _meta('https://s9.example.com/x/9', key: 'pkg:12', rev: 'old', rtUrl: 'https://m9.example.com', rt: 't')),
      // 本地文件档
      _p('f', 'file:///tmp/a.yaml'),
    ];

    test('带键：键相同且 rev 不同的；还不知道键的（没拉过）也拉一次', () {
      expect(profilesToRefresh(const SubChange(base: m1, key: 'pkg:12', rev: 'new'), profiles, null), ['a', 'd']);
    });
    test('rev 一样的不拉', () {
      expect(profilesToRefresh(const SubChange(base: m1, key: 'file:b.yaml', rev: 'same'), profiles, null), ['d']);
    });
    test('不带键（旧主控的 subscription_changed）：这个主控来的全部订阅档', () {
      expect(profilesToRefresh(const SubChange(base: m1, key: '', rev: ''), profiles, null), ['a', 'b', 'c', 'd']);
    });
    test('别的主控的变更不碰这些档', () {
      expect(profilesToRefresh(const SubChange(base: 'https://m9.example.com', key: 'pkg:12', rev: 'new'), profiles, null), ['e']);
      expect(profilesToRefresh(const SubChange(base: 'https://nope.example.com', key: '', rev: ''), profiles, null), isEmpty);
    });
    test('登录了主控：订阅地址在它上面的档按它认', () {
      final login = PanelLogin.of('https://panel.example.com', 'tok')!;
      final mine = [
        _p('p', 'https://panel.example.com/x/1', _meta('https://panel.example.com/x/1', key: 'pkg:1', rev: 'r')),
        _p('q', 'https://other.example.com/x/1', _meta('https://other.example.com/x/1', key: 'pkg:1', rev: 'r')),
      ];
      expect(profilesToRefresh(const SubChange(base: 'https://panel.example.com', key: 'pkg:1', rev: 'r2'), mine, login), ['p']);
    });
  });

  test('重拉失败的重试间隔：1、2、4… 分钟，封顶 30 分钟', () {
    expect(pushRetryDelay(0), const Duration(minutes: 1));
    expect(pushRetryDelay(1), const Duration(minutes: 2));
    expect(pushRetryDelay(3), const Duration(minutes: 8));
    expect(pushRetryDelay(5), const Duration(minutes: 30));
    expect(pushRetryDelay(50), const Duration(minutes: 30));
    expect(pushRefreshHeaders, {'mmwx-refresh': 'push'});
  });
}
