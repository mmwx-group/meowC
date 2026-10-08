import 'dart:async';
import 'dart:typed_data';

import 'package:bett_box/meowx/panel/client.dart';
import 'package:bett_box/meowx/panel/realtime.dart';
import 'package:flutter_test/flutter_test.dart';

/// 握手第一步（取主控公钥）由测试决定何时失败的假主控：每次 [masterPub] 记一次「开始握手」。
class _HangingPanel extends PanelClient {
  _HangingPanel() : super('https://panel.test');

  final attempts = <Completer<Uint8List>>[];

  @override
  Future<Uint8List> masterPub({bool refresh = false}) {
    final c = Completer<Uint8List>();
    attempts.add(c);
    return c.future;
  }

  /// 让最近一次握手失败。
  void failLast() => attempts.last.completeError(StateError('unreachable'));
}

void main() {
  // testWidgets 自带假时钟（fake_async 不是直接依赖），退避的几十秒用 pump 拨过去
  group('实时通道：网络变化', () {
    late _HangingPanel panel;
    late StreamController<Object?> network;
    late RealtimeClient rt;

    /// 连续失败到退避涨满：5 → 10 → 20 → 40 秒各等一轮，返回时第 5 次握手正在途中（没有重连定时器）。
    Future<void> failUntilSaturated(WidgetTester tester) async {
      panel = _HangingPanel();
      network = StreamController<Object?>.broadcast();
      rt = RealtimeClient(client: panel, token: 't', onEvent: (_, _) {}, networkChanges: network.stream)..start();
      for (final wait in [5, 10, 20, 40]) {
        panel.failLast();
        await tester.pump();
        await tester.pump(Duration(seconds: wait));
      }
      expect(panel.attempts, hasLength(5));
    }

    Future<void> shutdown() async {
      await rt.stop();
      await network.close();
    }

    testWidgets('握手在途时网络变了：这次失败后从 5 秒重新退避，而不是接着等 60 秒', (tester) async {
      await failUntilSaturated(tester);

      network.add(null);
      await tester.pump();
      expect(panel.attempts, hasLength(5), reason: '握手在途，不重复发起');

      panel.failLast(); // 旧网络上的那次握手失败
      await tester.pump();
      await tester.pump(const Duration(seconds: 5));
      expect(panel.attempts, hasLength(6));

      await shutdown();
    });

    testWidgets('正等着重连时网络变了：立刻连，退避同样从头算', (tester) async {
      await failUntilSaturated(tester);
      panel.failLast(); // 排上 60 秒
      await tester.pump();
      await tester.pump(const Duration(seconds: 30));
      expect(panel.attempts, hasLength(5));

      network.add(null);
      await tester.pump();
      expect(panel.attempts, hasLength(6), reason: '不等完剩下的 30 秒');

      panel.failLast();
      await tester.pump();
      await tester.pump(const Duration(seconds: 5));
      expect(panel.attempts, hasLength(7));

      await shutdown();
    });

    testWidgets('没有网络变化：退避照旧涨到 60 秒', (tester) async {
      await failUntilSaturated(tester);
      panel.failLast();
      await tester.pump();
      await tester.pump(const Duration(seconds: 59));
      expect(panel.attempts, hasLength(5));
      await tester.pump(const Duration(seconds: 1));
      expect(panel.attempts, hasLength(6));

      await shutdown();
    });
  });

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
