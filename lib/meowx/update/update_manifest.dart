import 'package:bett_box/common/constant.dart' show updateManifestUrl;

import '../state/format.dart';

/// latest.json（MeowX 仓库 scripts/publish-r2.sh 发版时写到 dl.miaomiaowux.com/meowx/）里一个包的条目：
/// kind 是 setup / portable / apk 之类的包类型，size 与 sha256 用来校验下载结果。
class UpdateFile {
  final String kind;
  final String name;
  final String url;
  final int size;
  final String sha256;

  const UpdateFile({
    required this.kind,
    required this.name,
    required this.url,
    required this.size,
    required this.sha256,
  });

  /// 缺 url 视为无效条目 → null；size / sha256 缺失时置 0 / 空，由校验阶段拒绝。
  static UpdateFile? fromJson(Object? json) {
    if (json is! Map) return null;
    final url = (json['url'] as String? ?? '').trim();
    if (url.isEmpty) return null;
    return UpdateFile(
      kind: json['kind'] as String? ?? '',
      name: json['name'] as String? ?? '',
      url: url,
      size: (json['size'] as num?)?.toInt() ?? 0,
      sha256: (json['sha256'] as String? ?? '').trim().toLowerCase(),
    );
  }

  Map<String, dynamic> toJson() => {
    'kind': kind,
    'name': name,
    'url': url,
    'size': size,
    'sha256': sha256,
  };
}

final _updateHost = Uri.parse(updateManifestUrl).host;

/// 一键更新只信任与 latest.json 同源的包地址：https 且主机就是发布域名。
/// 清单被篡改成外链 / 明文地址时不下载、不执行，退回打开下载页。
bool isTrustedUpdateUrl(String url) {
  final u = Uri.tryParse(url);
  return u != null && u.scheme == 'https' && u.host == _updateHost;
}

/// 从平台条目的 files 里挑本机要装的包：便携版只认 kind=portable（没配就 null，绝不拿安装包去覆盖便携目录）；
/// 安装版按编译期 APP_ASSET_SUFFIX 匹配文件名结尾（`windows-amd64-setup.exe`）。地址不受信任的条目一律跳过。
UpdateFile? pickUpdateFile(
  Iterable<Object?> files, {
  required bool portable,
  required String assetSuffix,
}) {
  final candidates = files
      .map(UpdateFile.fromJson)
      .whereType<UpdateFile>()
      .where((f) => isTrustedUpdateUrl(f.url))
      .toList();
  if (portable) {
    for (final f in candidates) {
      if (f.kind == 'portable') return f;
    }
    return null;
  }
  if (assetSuffix.isNotEmpty) {
    for (final f in candidates) {
      if (f.name.endsWith('-$assetSuffix')) return f;
    }
  }
  return null;
}

/// 「发现新版本」弹窗里版本号下面的说明行：当前版本 + 选中的安装包（文件名 · 大小）。
/// 没匹配到本机的包（[file] 为 null，会改去下载页）就只有当前版本一行。
List<String> updateSummaryLines({required String current, UpdateFile? file}) => [
  '当前版本 v$current',
  if (file != null)
    '安装包 ${file.name.isEmpty ? file.kind : file.name}${file.size > 0 ? ' · ${fmtSize(file.size)}' : ''}',
];
