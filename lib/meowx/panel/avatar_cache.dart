import 'dart:async';
import 'dart:io';

import 'package:bett_box/common/common.dart';
import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

/// 账户头像的本地缓存（2026-11-18 用户：不要每次都重新获取）。
/// 按头像地址存一份到磁盘（`<home>/meowx-avatar/<sha1(地址)>`），之后从磁盘读；进程内再留一份字节，页面重建不闪。
/// 主控换头像时地址带的 `?v=<时间戳>` 会变 = 新地址、重新下载；只留最新那一张，旧的写新文件时删掉。
class AvatarCache {
  AvatarCache({Future<String> Function()? dir, Future<Uint8List> Function(String url)? fetch})
    : _dir = dir ?? _defaultDir,
      _fetch = fetch ?? _download;

  static final shared = AvatarCache();

  final Future<String> Function() _dir;
  final Future<Uint8List> Function(String url) _fetch;
  final _mem = <String, Uint8List>{};
  final _inflight = <String, Future<Uint8List?>>{};

  static const _maxBytes = 8 << 20;

  static Future<String> _defaultDir() async => p.join(await appPath.homeDirPath, 'meowx-avatar');

  static Future<Uint8List> _download(String url) async {
    final res = await Dio(
      BaseOptions(connectTimeout: const Duration(seconds: 10), receiveTimeout: const Duration(seconds: 20)),
    ).get<List<int>>(url, options: Options(responseType: ResponseType.bytes));
    final data = res.data;
    if (data == null || data.isEmpty) throw const FormatException('头像为空');
    if (data.length > _maxBytes) throw const FormatException('头像太大');
    return Uint8List.fromList(data);
  }

  static String _name(String url) => sha1.convert(url.codeUnits).toString();

  /// 测试用：直接放进内存那份
  @visibleForTesting
  void seed(String url, Uint8List bytes) => _mem[url] = bytes;

  /// 进程里已有的字节（同步，给首帧用）
  Uint8List? peek(String url) => _mem[url];

  /// 先内存、再磁盘、最后下载；失败返回 null（下次再试，不记失败）
  Future<Uint8List?> load(String url) {
    final hit = _mem[url];
    if (hit != null) return SynchronousFuture(hit);
    // 回调不能返回 remove 的结果：那是这个 Future 自己，whenComplete 会等它、永远完成不了
    return _inflight[url] ??= _load(url).whenComplete(() {
      _inflight.remove(url);
    });
  }

  Future<Uint8List?> _load(String url) async {
    try {
      final dir = Directory(await _dir());
      final file = File(p.join(dir.path, _name(url)));
      if (await file.exists()) {
        final bytes = await file.readAsBytes();
        if (bytes.isNotEmpty) return _mem[url] = bytes;
      }
      final bytes = await _fetch(url);
      _mem
        ..clear()
        ..[url] = bytes;
      try {
        await dir.create(recursive: true);
        final tmp = File('${file.path}.tmp');
        await tmp.writeAsBytes(bytes, flush: true);
        await tmp.rename(file.path);
        await for (final e in dir.list()) {
          if (e is File && e.path != file.path) await e.delete().catchError((_) => e);
        }
      } catch (_) {
        // 写不进磁盘就只留内存那份
      }
      return bytes;
    } catch (_) {
      return null;
    }
  }
}
