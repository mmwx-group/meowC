import 'package:bett_box/meowx/state/latency.dart';
import 'package:bett_box/meowx/theme/tokens.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const mm = MeowTokens.light;

  test('HTTPS / TCPing 阈值 100 / 200', () {
    expect(latencyColor(100, LatencyMode.url, mm), mm.good);
    expect(latencyColor(101, LatencyMode.url, mm), mm.mid);
    expect(latencyColor(200, LatencyMode.tcping, mm), mm.mid);
    expect(latencyColor(201, LatencyMode.tcping, mm), mm.slow);
  });

  test('真连接阈值 300 / 600', () {
    expect(latencyColor(300, LatencyMode.urlFull, mm), mm.good);
    expect(latencyColor(600, LatencyMode.urlFull, mm), mm.mid);
    expect(latencyColor(601, LatencyMode.urlFull, mm), mm.slow);
  });

  test('延迟值语义', () {
    expect(latencyStateOf(null), LatencyState.untested);
    expect(latencyStateOf(0), LatencyState.testing);
    expect(latencyStateOf(-1), LatencyState.timeout);
    expect(latencyStateOf(88), LatencyState.value);
  });

  test('延迟文案：没测过 / 测试中 / 超时 / 有值按测速方式上色', () {
    expect(msStyle(mm, null, LatencyMode.url), ('— ms', mm.t2));
    expect(msStyle(mm, 0, LatencyMode.url), ('…', mm.t2));
    expect(msStyle(mm, -1, LatencyMode.url), ('超时', mm.slow));
    expect(msStyle(mm, 100000, LatencyMode.url), ('超时', mm.slow));
    expect(msStyle(mm, 38, LatencyMode.url), ('38 ms', mm.good));
    expect(msStyle(mm, 150, LatencyMode.url), ('150 ms', mm.mid));
    expect(msStyle(mm, 150, LatencyMode.urlFull), ('150 ms', mm.good));
  });
}
