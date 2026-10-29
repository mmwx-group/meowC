import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:bett_box/common/common.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path/path.dart' as p;

/// 液态玻璃「插画」背景用的自己的图片（同 MeowX iOS，2026-10-28 起插画只用自己选的图、不再内置品牌插画）。
///
/// 存在数据目录的 `meowx/glass-art-custom-<编号>`，同一时间只留一张，编号记在设置里（[MeowSettings.glassArtImage]），
/// 换图 = 换编号，背景宿主按编号重画。安卓从系统相册选（不要存储权限），由 image_picker 在原生端缩到长边 [maxPixel]、
/// 重新压成 JPEG；Windows 原样复制选中的文件。渲染时只按屏幕需要的大小解码（[decode]），大图不整张解码进内存。
abstract final class MeowGlassArt {
  /// 安卓选图时缩到的长边：够 2K 屏竖着 cover 铺满再外扩 6%
  static const maxPixel = 3200;

  /// Windows 原样复制的上限：再大的图解码时也只取需要的大小，但没必要存一份几十 MB 的原图
  static const maxBytes = 40 * 1024 * 1024;

  static const _prefix = 'glass-art-custom-';

  static Future<Directory> _dir() async => Directory(p.join(await appPath.homeDirPath, 'meowx'));

  /// 编号对应的文件（不保证存在）
  static Future<File> file(String id) async => File(p.join((await _dir()).path, '$_prefix$id'));

  /// 选一张图存成新的，返回编号；取消 = null。图读不了 / 太大抛 [MeowGlassArtError]。
  static Future<String?> pick() async {
    String? path;
    if (system.isAndroid) {
      final x = await ImagePicker().pickImage(
        source: ImageSource.gallery,
        maxWidth: maxPixel.toDouble(),
        maxHeight: maxPixel.toDouble(),
        imageQuality: 88,
        requestFullMetadata: false,
      );
      path = x?.path;
    } else {
      final result = await FilePicker.platform.pickFiles(type: FileType.image);
      path = result?.files.singleOrNull?.path;
    }
    if (path == null) return null;
    return save(File(path));
  }

  /// 把 [source] 存成新的一张，删掉旧的，返回编号
  static Future<String> save(File source) async {
    if (await source.length() > maxBytes) throw const MeowGlassArtError('图片太大（超过 40MB），换一张小一点的');
    final bytes = await source.readAsBytes();
    // 先确认解码得了：坏图、不认识的格式在这里就报错，不存
    final probe = await decode(bytes, const ui.Size(8, 8));
    if (probe == null) throw const MeowGlassArtError('这张图片读不出来，换一张试试');
    probe.dispose();
    final dir = await _dir();
    await dir.create(recursive: true);
    final rand = math.Random.secure();
    final id = List.generate(8, (_) => rand.nextInt(16).toRadixString(16)).join();
    await File(p.join(dir.path, '$_prefix$id')).writeAsBytes(bytes, flush: true);
    // 只留这一张
    await for (final e in dir.list()) {
      final name = p.basename(e.path);
      if (e is File && name.startsWith(_prefix) && name != '$_prefix$id') {
        try {
          await e.delete();
        } catch (_) {}
      }
    }
    return id;
  }

  /// 读出编号 [id] 的图，解码到 cover 铺满 [cover]（像素）就够的大小；文件没了 / 读不了 = null
  static Future<ui.Image?> load(String id, ui.Size cover) async {
    final f = await file(id);
    if (!await f.exists()) return null;
    return decode(await f.readAsBytes(), cover);
  }

  /// 按 cover 铺满 [cover]（像素）需要的大小解码（比它大的图缩小解码，小图不放大）。尺寸按 EXIF 方向摆正之后算
  @visibleForTesting
  static Future<ui.Image?> decode(Uint8List bytes, ui.Size cover) async {
    ui.ImmutableBuffer? buffer;
    ui.ImageDescriptor? descriptor;
    try {
      buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
      descriptor = await ui.ImageDescriptor.encoded(buffer);
      final w = descriptor.width, h = descriptor.height;
      if (w <= 0 || h <= 0) return null;
      final k = math.min(1.0, math.max(cover.width / w, cover.height / h));
      final codec = await descriptor.instantiateCodec(
        targetWidth: math.max(1, (w * k).round()),
        targetHeight: math.max(1, (h * k).round()),
      );
      final frame = await codec.getNextFrame();
      codec.dispose();
      return frame.image;
    } catch (e) {
      commonPrint.log('glass art decode failed: $e');
      return null;
    } finally {
      descriptor?.dispose();
      buffer?.dispose();
    }
  }
}

class MeowGlassArtError implements Exception {
  const MeowGlassArtError(this.message);

  final String message;

  @override
  String toString() => message;
}
