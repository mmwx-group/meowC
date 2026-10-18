import 'dart:convert';

import 'package:bett_box/meowx/config/subscription_headers.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('profile-title 明文 / base64 / 空', () {
    expect(subscriptionTitle('喵喵屋 套餐'), '喵喵屋 套餐');
    expect(subscriptionTitle('base64:${base64.encode(utf8.encode('妙妙屋X'))}'), '妙妙屋X');
    expect(subscriptionTitle('base64:'), isNull);
    expect(subscriptionTitle('  '), isNull);
    expect(subscriptionTitle(null), isNull);
  });
  test('profile-update-interval 小时，默认 24', () {
    expect(subscriptionUpdateInterval('12'), const Duration(hours: 12));
    expect(subscriptionUpdateInterval('0'), const Duration(hours: 24));
    expect(subscriptionUpdateInterval('x'), const Duration(hours: 24));
    expect(subscriptionUpdateInterval(null), const Duration(hours: 24));
  });

  group('通用订阅（分享链接）', () {
    List<int> bytes(String s) => utf8.encode(s);
    const links = 'vmess://eyJhZGQiOiJhIn0=\nvless://uuid@a.example:443?security=reality#HK\nss://YWVzOnB3@b.example:8388#JP\n';

    test('base64（标准 / URL 安全、缺 =、带换行）或明文的链接列表都算', () {
      final b64 = base64.encode(utf8.encode(links));
      expect(isShareLinkSubscription(bytes(b64)), isTrue);
      expect(isShareLinkSubscription(bytes(base64Url.encode(utf8.encode(links)).replaceAll('=', ''))), isTrue);
      expect(isShareLinkSubscription(bytes('${b64.substring(0, 20)}\r\n${b64.substring(20)}')), isTrue);
      expect(isShareLinkSubscription(bytes(links)), isTrue);
      expect(isShareLinkSubscription(bytes('STATUS=剩余流量 10G\n$links')), isTrue);
    });

    test('Clash YAML、网页、空内容、随便一段 base64 都不算', () {
      expect(isShareLinkSubscription(bytes('mixed-port: 7890\nproxies:\n  - {name: a, type: ss, server: vmess://x}\n')), isFalse);
      expect(isShareLinkSubscription(bytes('<html><a href="https://x">vless://y</a></html>')), isFalse);
      expect(isShareLinkSubscription(bytes('   ')), isFalse);
      expect(isShareLinkSubscription(bytes(base64.encode(utf8.encode('hello world, not links')))), isFalse);
      expect(isShareLinkSubscription(bytes('https://example.com/a\nhttps://example.com/b')), isFalse);
    });

    test('拉订阅：先用 App 的 UA；回 Clash 配置就不再拉', () async {
      final uas = <String?>[];
      final got = await fetchClashSubscription((ua) async {
        uas.add(ua);
        return 'proxies: []';
      }, bytes);
      expect(got, 'proxies: []');
      expect(uas, [null]);
    });

    test('拉订阅：回的是通用订阅 → 换 clash.meta 再要一次，用第二次的', () async {
      final uas = <String?>[];
      final got = await fetchClashSubscription((ua) async {
        uas.add(ua);
        return ua == null ? base64.encode(utf8.encode(links)) : 'proxies: []';
      }, bytes);
      expect(got, 'proxies: []');
      expect(uas, [null, clashCompatUa]);
    });

    test('拉订阅：换了 UA 还是通用订阅 → 报明白是通用订阅，不丢 yaml 解析错误', () async {
      final uas = <String?>[];
      await expectLater(
        fetchClashSubscription((ua) async {
          uas.add(ua);
          return links;
        }, bytes),
        throwsA(subscriptionShareLinkMessage),
      );
      expect(uas, [null, clashCompatUa]);
    });
  });
}
