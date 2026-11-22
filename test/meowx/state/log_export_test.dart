import 'package:bett_box/enum/enum.dart';
import 'package:bett_box/meowx/state/log_export.dart';
import 'package:bett_box/models/models.dart';
import 'package:flutter_test/flutter_test.dart';

/// 日志页「导出」的文件名与内容（2026-11-22）。
void main() {
  final now = DateTime(2026, 11, 22, 9, 5, 7);

  test('文件名：MeowX-logs-年月日-时分秒.log', () {
    expect(LogExport.fileName(now), 'MeowX-logs-20261122-090507.log');
  });

  test('内容：头（版本 / 系统 / 导出时间 / 条数）+ 每行「时间 [来源] [级别] 内容」，MeowX 的去掉 [APP] 前缀，按记录顺序', () {
    const logs = [
      Log(logLevel: LogLevel.info, payload: '[APP] 启动代理', dateTime: '2026-11-22 09:00:01'),
      Log(logLevel: LogLevel.warning, payload: '[TCP] dial 伦敦 01 error: timeout', dateTime: '2026-11-22 09:00:02'),
      Log(logLevel: LogLevel.error, payload: 'dns: 解析 example.invalid 失败', dateTime: '2026-11-22 09:00:03'),
    ];
    final text = LogExport.text(logs, version: '0.6.2', platform: 'Windows', now: now);
    expect(
      text,
      'MeowX 0.6.2 (Windows)\n'
      '导出时间 2026-11-22 09:05:07\n'
      '共 3 条（MeowX 1 · 引擎 2）\n'
      '\n'
      '2026-11-22 09:00:01 [MeowX] [info] 启动代理\n'
      '2026-11-22 09:00:02 [引擎] [warning] [TCP] dial 伦敦 01 error: timeout\n'
      '2026-11-22 09:00:03 [引擎] [error] dns: 解析 example.invalid 失败\n',
    );
    // 存成 UTF-8
    expect(LogExport.bytes(logs, version: '0.6.2', platform: 'Windows', now: now).length, greaterThan(text.length));
  });

  test('没有日志：只有头', () {
    expect(LogExport.text(const [], version: '0.6.2', platform: 'Android', now: now), endsWith('共 0 条（MeowX 0 · 引擎 0）\n\n'));
  });
}
