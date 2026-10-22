import 'package:bett_box/meowx/panel/models.dart';
import 'package:bett_box/meowx/panel/unlock_catalog.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const item = {'name': '套餐 A', 'filename': 'a.yaml', 'subscription_path': '/x/abc', 'expire_at': '2027-01-02T03:04:05Z', 'traffic_used': 1024, 'traffic_total': '2048'};

  test('订阅列表三种形状', () {
    for (final shape in [
      [item],
      {'subscriptions': [item]},
      {'items': [item]},
      {'data': [item]},
    ]) {
      final list = RemoteSubscription.parseList(shape);
      expect(list.length, 1, reason: '$shape');
      final s = list.single;
      expect(s.name, '套餐 A');
      expect(s.expireAt, DateTime.utc(2027, 1, 2, 3, 4, 5));
      expect(s.trafficUsed, 1024);
      expect(s.trafficTotal, 2048);
    }
    expect(RemoteSubscription.parseList({'foo': 1}), isEmpty);
    // 旧面板缺流量字段 → null
    final old = RemoteSubscription.parseList([{'name': 'x', 'filename': 'x.yaml', 'subscription_path': ''}]).single;
    expect(old.trafficUsed, isNull);
  });

  test('下载地址：短链优先，回退 subscribe 接口', () {
    final s = RemoteSubscription.parseList([item]).single;
    expect(s.downloadUrl('https://panel.example.com/', subscriptionToken: 'T'), 'https://panel.example.com/x/abc');
    final noPath = RemoteSubscription.parseList([{'name': 'x', 'filename': 'x y.yaml', 'subscription_path': ''}]).single;
    expect(noPath.downloadUrl('https://panel.example.com', subscriptionToken: 'T'), 'https://panel.example.com/api/clash/subscribe?token=T&filename=x+y.yaml&t=clash');
  });

  test('下载地址：主控关了短链接时 subscription_path 是要令牌的接口，补上订阅令牌', () {
    RemoteSubscription sub(String path) => RemoteSubscription.parseList([{'name': 'x', 'filename': 'x.yaml', 'subscription_path': path}]).single;
    expect(sub('/api/user/package-subscribe?assignment_id=7').downloadUrl('https://panel.example.com', subscriptionToken: 'T'),
        'https://panel.example.com/api/user/package-subscribe?assignment_id=7&token=T');
    expect(sub('/api/user/package-subscribe?merged=1').downloadUrl('http://203.0.113.5:12889/', subscriptionToken: 'T'),
        'http://203.0.113.5:12889/api/user/package-subscribe?merged=1&token=T');
    expect(sub('/api/clash/subscribe?filename=x.yaml').downloadUrl('https://panel.example.com', subscriptionToken: 'T'),
        'https://panel.example.com/api/clash/subscribe?filename=x.yaml&token=T');
    // 已经带了 token 的不重复加；短链不加
    expect(sub('/api/clash/subscribe?filename=x.yaml&token=X').downloadUrl('https://panel.example.com', subscriptionToken: 'T'),
        'https://panel.example.com/api/clash/subscribe?filename=x.yaml&token=X');
    expect(sub('x/abc?t=clash').downloadUrl('https://panel.example.com', subscriptionToken: 'T'), 'https://panel.example.com/x/abc?t=clash');
  });

  test('账户订阅去重：主控关了短链接时同一路径下按 assignment_id / merged 区分', () {
    // 与 iOS SubAccountStoreTests.notDownloadedAPIPaths 同一组用例
    final remote = RemoteSubscription.parseList([
      {'name': '套餐 7', 'filename': '__package__:7', 'subscription_path': '/api/user/package-subscribe?assignment_id=7'},
      {'name': '套餐 8', 'filename': '__package__:8', 'subscription_path': '/api/user/package-subscribe?assignment_id=8'},
      {'name': '全部套餐', 'filename': '__merged__', 'subscription_path': '/api/user/package-subscribe?merged=1'},
    ]);
    List<String> names(List<RemoteSubscription> l) => [for (final s in l) s.name];
    expect(
      names(notDownloadedSubscriptions(remote: remote, host: 'https://panel.example.com', localUrls: const ['https://panel.example.com/api/user/package-subscribe?assignment_id=7&token=T'])),
      ['套餐 8', '全部套餐'],
    );
    expect(
      notDownloadedSubscriptions(remote: remote, host: 'https://panel.example.com', localUrls: const ['https://other.example.com/api/user/package-subscribe?assignment_id=7&token=T']).length,
      3,
    );
  });

  test('登录结果解析', () {
    expect(LoginSuccess.tryParse({'token': 't', 'username': 'u'})?.nickname, 'u');
    expect(LoginSuccess.tryParse({'token': 't', 'username': 'u', 'nickname': 'N'})?.nickname, 'N');
    expect(LoginSuccess.tryParse({'requires_2fa': true}), isNull);
  });

  test('个人资料解析：昵称优先、没有昵称用用户名；出错应答不是资料', () {
    final p = AccountProfile.tryParse({'username': 'alice', 'nickname': '\u591c\u732b', 'avatar_url': '/api/user/avatar/ab?v=2', 'role': 'user'});
    expect(p?.nickname, '\u591c\u732b');
    expect(p?.avatarUrl, '/api/user/avatar/ab?v=2');
    final noNick = AccountProfile.tryParse({'username': 'alice', 'nickname': '', 'avatar_url': ''});
    expect(noNick?.nickname, 'alice');
    expect(noNick?.avatarUrl, '');   // 用户在主控上把头像删了：客户端跟着回到品牌头像
    for (final body in <Map<String, dynamic>>[{'error': 'unauthorized'}, {'error': 'path not allowed'}, {}, {'username': ''}]) {
      expect(AccountProfile.tryParse(body), isNull, reason: '$body');
    }
  });

  test('头像地址：主控上传的站内路径接到主控地址后面，外链原样，空就是空', () {
    const base = 'https://panel.example.com';
    expect(absoluteAvatarUrl('/api/user/avatar/0a1b?v=1760000000', base), 'https://panel.example.com/api/user/avatar/0a1b?v=1760000000');
    expect(absoluteAvatarUrl('/api/user/avatar/ff', 'https://panel.example.com:8443'), 'https://panel.example.com:8443/api/user/avatar/ff');
    expect(absoluteAvatarUrl('https://img.example.org/a.webp', base), 'https://img.example.org/a.webp');
    expect(absoluteAvatarUrl('', base), '');
    expect(absoluteAvatarUrl('  ', base), '');
    // 不知道主控地址时补不了：原样留着（加载不出来，落到品牌头像）
    expect(absoluteAvatarUrl('/api/user/avatar/ff', ''), '/api/user/avatar/ff');
  });

  test('登录后自动导入：账户下恰好一份、没在用订阅、本机还没有这个主控的订阅才导入', () {
    const a = RemoteSubscription(name: 'A', filename: 'a.yaml', subscriptionPath: '/x/a');
    const b = RemoteSubscription(name: 'B', filename: 'b.yaml', subscriptionPath: '/x/b');
    const host = 'https://panel.example.com';
    expect(autoImportCandidate(remote: [a], host: host, localUrls: const [''], usingSubscription: false), a);
    // 多份不替用户选；一份都没有
    expect(autoImportCandidate(remote: [a, b], host: host, localUrls: const [], usingSubscription: false), isNull);
    expect(autoImportCandidate(remote: const [], host: host, localUrls: const [], usingSubscription: false), isNull);
    // 正在用别家订阅：不替用户换
    expect(autoImportCandidate(remote: [a], host: host, localUrls: const ['https://airport.example.org/sub'], usingSubscription: true), isNull);
    // 本机已有这个主控的订阅（主机名不分大小写）
    expect(autoImportCandidate(remote: [a], host: host, localUrls: const ['https://Panel.Example.com/x/old'], usingSubscription: false), isNull);
    // 别家机场的订阅不算这个主控的
    expect(autoImportCandidate(remote: [a], host: host, localUrls: const ['https://airport.example.org/sub'], usingSubscription: false), a);
    // 这一份已在本机、挂在主控的「订阅域名」上（主机名不同、短链路径相同）：不重复导入
    expect(autoImportCandidate(remote: [a], host: host, localUrls: const ['https://sub.example.net/x/a'], usingSubscription: false), isNull);
  });

  test('账户订阅去重：短链按路径认（不比主机名），filename 旧式按主控主机 + 参数认', () {
    // 与 iOS SubAccountStoreTests.notDownloadedDedup 同一组用例
    final remote = RemoteSubscription.parseList([
      {'name': '主力', 'filename': 'a.yaml', 'subscription_path': '/x/aaa'},
      {'name': '备用', 'filename': 'b.yaml', 'subscription_path': 'x/bbb?t=clash'},
      {'name': '旧式', 'filename': 'c.yaml'},
      {'name': '没下', 'filename': 'd.yaml', 'subscription_path': '/x/ddd'},
    ]);
    const host = 'https://panel.example.com';
    const locals = [
      'https://sub.example.net/x/aaa?t=meowx', // 订阅域名 + 别的参数：同一份
      'https://panel.example.com/x/bbb/', // 结尾斜杠：同一份
      'https://panel.example.com/api/clash/subscribe?token=t&filename=c.yaml&t=clash', // filename 旧式
      '', // 内置直连档
      'https://airport.example.org/sub',
    ];
    List<String> names(List<RemoteSubscription> l) => [for (final s in l) s.name];
    expect(names(notDownloadedSubscriptions(remote: remote, host: host, localUrls: locals)), ['没下']);
    // 别的主控上同名 filename 不算
    expect(
      names(notDownloadedSubscriptions(remote: remote, host: host, localUrls: const ['https://other.example.com/api/clash/subscribe?filename=c.yaml'])),
      ['主力', '备用', '旧式', '没下'],
    );
    // 不知道主控地址：filename 那条认不出，短链照认
    expect(names(notDownloadedSubscriptions(remote: remote, host: '', localUrls: locals)), ['旧式', '没下']);
    // 主机名不分大小写；本机只有根路径的地址不会把短链误认成已下载
    expect(
      names(notDownloadedSubscriptions(
        remote: remote,
        host: host,
        localUrls: const ['https://Panel.Example.com/api/clash/subscribe?filename=c.yaml', 'https://panel.example.com/'],
      )),
      ['主力', '备用', '没下'],
    );
  });

  test('回程奖牌解析', () {
    final m = NodeMedal.parse({'success': true, 'nodes': [
      {'name': 'HK-1', 'medal': 'gold', 'routes': [{'carrier': 'CT', 'region': '广东', 'route_type': 'CN2 GIA', 'gold': true}]},
      {'name': 'JP-1', 'medal': 'silver'},
    ]});
    expect(m['HK-1']?.routes.single.routeType, 'CN2 GIA');
    expect(m['JP-1']?.medal, 'silver');
    expect(NodeMedal.parse({'success': false}), isEmpty);
  });

  test('功能开关解析', () {
    expect(PanelFeatures.parse({'success': true, 'return_routes': true, 'unlock_check': false}).returnRoutes, isTrue);
    expect(PanelFeatures.parse({'success': true, 'return_routes': true, 'unlock_check': false}).unlockCheck, isFalse);
    expect(PanelFeatures.parse({'success': false}).returnRoutes, isFalse);
    expect(PanelFeatures.parse('x').unlockCheck, isFalse);
  });

  test('解锁结论解析 / 分组 / 文案', () {
    final m = NodeUnlocks.parse({'success': true, 'nodes': [
      {'name': 'HK-1', 'unlocks': [
        {'service': 'openai', 'status': 'yes', 'region': 'HK'},
        {'service': 'netflix', 'status': 'originals_only'},
        {'service': 'apple', 'status': 'yes', 'region': 'HK'},
        {'service': 'claude', 'status': 'banned'},
        {'service': 'unknown_svc', 'status': 'no'},
      ]},
      {'name': 'empty', 'unlocks': []},
    ]});
    expect(m.keys, ['HK-1']);
    final n = m['HK-1']!;
    expect(n.unlockedCount, 3);
    final g = n.grouped;
    expect(g[UnlockCategory.streaming]!.map((e) => e.service), ['netflix']);
    expect(g[UnlockCategory.ai]!.map((e) => e.service), ['openai', 'claude']);   // 目录顺序
    expect(g[UnlockCategory.other]!.map((e) => e.service), ['apple', 'unknown_svc']);
    expect(n.entries.firstWhere((e) => e.service == 'openai').statusText, '已解锁 · HK');
    expect(n.entries.firstWhere((e) => e.service == 'apple').statusText, 'HK');     // 信息类只显示地区
    expect(n.entries.firstWhere((e) => e.service == 'netflix').statusText, '仅自制剧');
    expect(n.entries.firstWhere((e) => e.service == 'claude').statusText, 'IP 被封禁');
    expect(NodeUnlocks.parse({'success': true, 'nodes': []}), isEmpty);
  });

  test('登录深链', () {
    final r = parseLoginLink(Uri.parse('miaomiaowu://login?host=panel.example.com&code=abc'));
    expect(r?.base, 'https://panel.example.com');
    expect(r?.code, 'abc');
    expect(parseLoginLink(Uri.parse('miaomiaowu://login?host=https://p.example.com/&code=1'))?.base, 'https://p.example.com');
    expect(parseLoginLink(Uri.parse('clash://install-config?url=x')), isNull);
  });
}
