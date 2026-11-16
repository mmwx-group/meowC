import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:bett_box/common/common.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../config/subscription_meta.dart';

/// 各订阅档拉订阅时记下的主控应答头（订阅键 / rev / 实时通道凭证，见 [SubscriptionMeta]），按档案 id 存。
///
/// 存在数据目录的 `meowx-sub-meta.json`（与订阅档同一个目录，只有 App 自己读得到），不放进 Bettbox 的偏好：
/// 偏好是 freezed 生成的模型，加字段要重新生成；这些也不该跟着 WebDAV 备份走（rt 凭证换设备就作废了）。
/// 只在界面所在的 isolate 里读写（Profile.update 与实时同步都在那边）。
class SubscriptionMetaStore {
  SubscriptionMetaStore({Future<String> Function()? path}) : _path = path ?? _defaultPath;

  static Future<String> _defaultPath() async => p.join(await appPath.homeDirPath, 'meowx-sub-meta.json');

  final Future<String> Function() _path;

  /// 档案 id → 记录。读完之前是空的（[load]）。
  final metas = ValueNotifier<Map<String, SubscriptionMeta>>(const {});

  Future<void>? _loading;
  Future<void> _writing = Future.value();

  /// 读一次落盘的记录（重复调用共用同一次）。
  Future<void> load() => _loading ??= _load();

  Future<void> _load() async {
    try {
      final f = File(await _path());
      if (!await f.exists()) return;
      final j = json.decode(await f.readAsString());
      final map = j is Map ? j['profiles'] : null;
      if (map is! Map) return;
      final out = <String, SubscriptionMeta>{
        for (final e in map.entries)
          if (e.value is Map) e.key.toString(): SubscriptionMeta.fromJson((e.value as Map).cast<String, dynamic>()),
      };
      // 读盘期间已经记下的（刚拉完的订阅）以它们为准
      metas.value = {...out, ...metas.value};
    } catch (e) {
      commonPrint.log('MeowX: read subscription meta failed: $e');
    }
  }

  /// 拉完一份订阅（内容已写盘）后记下应答头。出错只记日志，不影响拉订阅本身。
  Future<void> record(String profileId, SubscriptionMeta meta) async {
    try {
      await load();
      metas.value = {...metas.value, profileId: meta};
      await _save();
    } catch (e) {
      commonPrint.log('MeowX: record subscription meta failed: $e');
    }
  }

  /// 去掉删掉的档案的记录。
  Future<void> remove(Set<String> profileIds) async {
    await load();
    final kept = {
      for (final e in metas.value.entries)
        if (!profileIds.contains(e.key)) e.key: e.value,
    };
    if (kept.length == metas.value.length) return;
    metas.value = kept;
    await _save();
  }

  Future<void> _save() {
    final snapshot = metas.value;
    return _writing = _writing.then((_) async {
      try {
        final path = await _path();
        final tmp = File('$path.tmp');
        await tmp.parent.create(recursive: true);
        await tmp.writeAsString(
          json.encode({
            'profiles': {for (final e in snapshot.entries) e.key: e.value.toJson()},
          }),
          flush: true,
        );
        await tmp.rename(path);
      } catch (e) {
        commonPrint.log('MeowX: save subscription meta failed: $e');
      }
    });
  }
}

final subscriptionMetaStore = SubscriptionMetaStore();
