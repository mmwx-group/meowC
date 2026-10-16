import 'package:bett_box/meowx/state/speed_history.dart';
import 'package:flutter_test/flutter_test.dart';

/// 每秒推送都是新对象：用一个盒子模拟（速率相同也是不同对象）。
class _T {
  _T(this.v);
  final double v;
}

void main() {
  double up(_T t) => t.v;
  double down(_T t) => t.v * 10;

  test('按对象身份认新样本：同一份列表不重复计；离开一会儿回来一次多出几个也接得上', () {
    final b = SpeedHistoryBuffer();
    final list = <_T>[for (var i = 0; i < 5; i++) _T(i.toDouble())];
    expect(b.ingest(list, up, down), isTrue);
    expect(b.state.sequence, 5);
    expect(b.state.up, [0, 1, 2, 3, 4]);
    expect(b.ingest(list, up, down), isFalse); // 没有新点

    // Bettbox 的定长列表（30）滚动：丢掉最旧的、追加三个新的
    final next = [...list.sublist(3), _T(5), _T(6), _T(7)];
    expect(b.ingest(next, up, down), isTrue);
    expect(b.state.sequence, 8);
    expect(b.state.up, [0, 1, 2, 3, 4, 5, 6, 7]);
    expect(b.state.down.last, 70);

    // 速率相同的新对象也算新点
    final same = [...next, _T(7)];
    b.ingest(same, up, down);
    expect(b.state.sequence, 9);
  });

  test('攒满 60 个后丢最旧的，序号继续涨；列表清空（断开）归零', () {
    final b = SpeedHistoryBuffer();
    var window = <_T>[];
    for (var i = 0; i < 100; i++) {
      window = [...window, _T(i.toDouble())];
      if (window.length > 30) window = window.sublist(window.length - 30);
      b.ingest(window, up, down);
    }
    expect(b.state.sequence, 100);
    expect(b.state.up.length, SpeedHistoryBuffer.capacity);
    expect(b.state.up.first, 40);
    expect(b.state.up.last, 99);

    expect(b.ingest(<_T>[], up, down), isTrue);
    expect(b.state.sequence, 0);
    expect(b.state.up, isEmpty);
    expect(b.ingest(<_T>[], up, down), isFalse);
  });

  test('上次见过的点已经不在列表里（离开太久整份都换了）：整份当新的', () {
    final b = SpeedHistoryBuffer();
    b.ingest([_T(1), _T(2)], up, down);
    final fresh = [for (var i = 0; i < 30; i++) _T(100.0 + i)];
    b.ingest(fresh, up, down);
    expect(b.state.sequence, 32);
    expect(b.state.up.length, 32);
    expect(b.state.up.last, 129);
  });
}
