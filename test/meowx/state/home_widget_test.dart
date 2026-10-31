import 'package:bett_box/enum/enum.dart';
import 'package:bett_box/meowx/state/home_widget.dart';
import 'package:flutter_test/flutter_test.dart';

HomeWidgetData data({bool connected = true, String? sub = '妙妙屋X', Mode mode = Mode.rule, int up = 0, int down = 0}) =>
    HomeWidgetData(
      connected: connected,
      subName: sub,
      mode: mode,
      used: 100,
      total: 1000,
      sessionUp: up,
      sessionDown: down,
    );

void main() {
  final t0 = DateTime(2026, 10, 31, 12);

  test('首次一律推', () {
    expect(HomeWidgetPushPolicy().shouldPush(data(), t0), isTrue);
  });

  test('连接态 / 订阅 / 模式变了马上推', () {
    final p = HomeWidgetPushPolicy()..shouldPush(data(), t0);
    final t1 = t0.add(const Duration(seconds: 1));
    expect(p.shouldPush(data(connected: false), t1), isTrue);
    expect(p.shouldPush(data(connected: false, sub: '别的订阅'), t1), isTrue);
    expect(p.shouldPush(data(connected: false, sub: '别的订阅', mode: Mode.global), t1), isTrue);
    expect(p.shouldPush(data(connected: false, sub: '别的订阅', mode: Mode.global), t1), isFalse);
  });

  test('本次流量至多 30 秒推一次', () {
    final p = HomeWidgetPushPolicy()..shouldPush(data(), t0);
    expect(p.shouldPush(data(down: 1 << 20), t0.add(const Duration(seconds: 5))), isFalse);
    expect(p.shouldPush(data(down: 2 << 20), t0.add(const Duration(seconds: 29))), isFalse);
    expect(p.shouldPush(data(down: 3 << 20), t0.add(const Duration(seconds: 30))), isTrue);
    expect(p.shouldPush(data(down: 3 << 20), t0.add(const Duration(seconds: 90))), isFalse);   // 没变不推
  });

  test('退到后台强推（force），不受 30 秒限制', () {
    final p = HomeWidgetPushPolicy()..shouldPush(data(), t0);
    expect(p.shouldPush(data(down: 1 << 20), t0.add(const Duration(seconds: 2)), force: true), isTrue);
  });

  test('没连时本次流量与起点写 0', () {
    final map = data(connected: false, up: 5, down: 6).toMap(since: 123);
    expect(map['sessionUp'], 0);
    expect(map['sessionDown'], 0);
    expect(map['since'], 0);
    expect(data(up: 5, down: 6).toMap(since: 123)['since'], 123);
  });
}
