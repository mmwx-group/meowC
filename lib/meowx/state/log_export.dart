import 'dart:convert';
import 'dart:typed_data';

import 'package:bett_box/models/models.dart';

import 'log_source.dart';

/// 日志页「导出」（2026-11-22 用户要求：Windows 上 App 与内核都不写日志文件，排查问题只能截图）：
/// 把内存里的日志（MeowX 自己的 + 内核的，不管当前筛选）写成一份纯文本 .log。
/// 第一段是头（App 版本、系统、导出时间、条数），之后每行「时间 [来源] [级别] 内容」，按记录顺序（旧的在前）。
abstract final class LogExport {
  /// 文件名：MeowX-logs-20261122-153045.log
  static String fileName(DateTime now) =>
      'MeowX-logs-${now.year}${_pad(now.month)}${_pad(now.day)}-${_pad(now.hour)}${_pad(now.minute)}${_pad(now.second)}.log';

  static String text(List<Log> logs, {required String version, required String platform, required DateTime now}) {
    final b = StringBuffer()
      ..writeln('MeowX $version ($platform)')
      ..writeln('导出时间 ${now.year}-${_pad(now.month)}-${_pad(now.day)} ${_pad(now.hour)}:${_pad(now.minute)}:${_pad(now.second)}')
      ..writeln('共 ${logs.length} 条（MeowX ${logs.where(isClientLog).length} · 引擎 ${logs.where((l) => !isClientLog(l)).length}）')
      ..writeln();
    for (final l in logs) {
      final client = isClientLog(l);
      final payload = client ? l.payload.substring('[APP] '.length) : l.payload;
      b.writeln('${l.dateTime} [${client ? 'MeowX' : '引擎'}] [${l.logLevel.name}] $payload');
    }
    return b.toString();
  }

  static Uint8List bytes(List<Log> logs, {required String version, required String platform, required DateTime now}) =>
      Uint8List.fromList(utf8.encode(text(logs, version: version, platform: platform, now: now)));

  static String _pad(int n) => n.toString().padLeft(2, '0');
}

