import 'package:bett_box/meowx/panel/realtime.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('实时通道重连退避', () {
    test('连续连不上：5 → 10 → 20 → 40 → 60 秒，之后封顶', () {
      final b = ReconnectBackoff();
      expect(
        [for (var i = 0; i < 8; i++) b.next().inSeconds],
        [5, 10, 20, 40, 60, 60, 60, 60],
      );
    });

    test('稳住 30 秒以上的连接断开 = 连上过，从 5 秒重新开始', () {
      final b = ReconnectBackoff();
      b.next();
      b.next();
      b.next();
      expect(b.next(uptime: const Duration(minutes: 3)).inSeconds, 5);
      expect(b.next().inSeconds, 10);
    });

    test('握手成功后马上被关（鉴权被拒）不算连上，退避继续增长', () {
      final b = ReconnectBackoff();
      expect(
        [for (var i = 0; i < 6; i++) b.next(uptime: const Duration(milliseconds: 200)).inSeconds],
        [5, 10, 20, 40, 60, 60],
      );
      // 刚好卡在门槛上算稳住
      expect(b.next(uptime: ReconnectBackoff.stableAfter).inSeconds, 5);
    });

    test('网络变化后从头退避', () {
      final b = ReconnectBackoff();
      for (var i = 0; i < 5; i++) {
        b.next();
      }
      b.reset();
      expect(b.next().inSeconds, 5);
    });

    test('ping 间隔必须小于主控的空闲窗口（70 秒）并留有余量', () {
      expect(RealtimeClient.pingInterval, lessThanOrEqualTo(const Duration(seconds: 60)));
      expect(RealtimeClient.pingInterval, greaterThan(const Duration(seconds: 25)));
    });
  });
}
