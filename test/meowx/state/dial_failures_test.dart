import 'package:bett_box/meowx/state/dial_failures.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final t0 = DateTime(2026, 11, 18, 10);

  test('解析 mihomo 的拨号失败日志：带规则 / 不带规则 / 来源带进程与 uid / IPv6 目标', () {
    final a = parseDialFailure(
      '[TCP] dial 🇭🇰 香港 01 · IEPL (match DomainSuffix/google.com) 172.19.0.1:51234(com.android.chrome, uid=10086) --> www.google.com:443 error: dial tcp 1.2.3.4:443: i/o timeout',
      t0,
    )!;
    expect(a.network, 'TCP');
    expect(a.proxy, '🇭🇰 香港 01 · IEPL');
    expect(a.rule, 'DomainSuffix');
    expect(a.payload, 'google.com');
    expect(a.host, 'www.google.com');
    expect(a.port, '443');
    expect(a.reason, 'dial tcp 1.2.3.4:443: i/o timeout');
    expect(a.info.metadata.host, 'www.google.com');
    expect(a.info.chains, ['🇭🇰 香港 01 · IEPL']);

    final b = parseDialFailure('[UDP] dial 节点选择 198.18.0.1:5353 --> [2001:db8::1]:443 error: connection refused', t0)!;
    expect(b.network, 'UDP');
    expect(b.proxy, '节点选择');
    expect(b.host, '2001:db8::1');
    expect(b.info.metadata.destinationIP, '2001:db8::1');
    expect(b.reason, 'connection refused');

    expect(parseDialFailure('[TCP] 172.19.0.1:1 --> a.com:443 match Match using DIRECT', t0), isNull);
    expect(parseDialFailure('[DNS] resolve a.com error: timeout', t0), isNull);
  });

  test('同主机 / 出站 / 原因 5 秒内连着失败合成一条计次；隔久了或原因不同另起一条', () {
    final log = DialFailureLog();
    const line = '[TCP] dial 节点A (match Match/) 10.0.0.2:1000 --> a.example.com:443 error: timeout';
    expect(log.record(line, t0), isTrue);
    expect(log.record(line, t0.add(const Duration(seconds: 3))), isTrue);
    expect(log.items, hasLength(1));
    expect(log.items.single.count, 2);
    expect(log.items.single.at, t0.add(const Duration(seconds: 3)));

    log.record('[TCP] dial 节点A (match Match/) 10.0.0.2:1001 --> a.example.com:443 error: refused', t0.add(const Duration(seconds: 4)));
    expect(log.items, hasLength(2));
    log.record(line, t0.add(const Duration(seconds: 20)));
    expect(log.items, hasLength(3));
    expect(log.items.first.count, 1);
    expect(log.record('普通日志', t0), isFalse);
  });
}
