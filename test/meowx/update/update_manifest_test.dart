import 'package:bett_box/meowx/update/update_manifest.dart';
import 'package:flutter_test/flutter_test.dart';

const _files = [
  {
    'kind': 'setup',
    'arch': 'amd64',
    'name': 'MeowX-0.1.3-windows-amd64-setup.exe',
    'url': 'https://dl.miaomiaowux.com/meowx/windows/MeowX-0.1.3-windows-amd64-setup.exe',
    'size': 46893269,
    'sha256': '07E18A54A7B2E4986F51D5A9612745B6ADA4794E5B3EEC72823DC16CDC90E663',
  },
  {
    'kind': 'portable',
    'arch': 'amd64',
    'name': 'MeowX-0.1.3-windows-amd64-portable.zip',
    'url': 'https://dl.miaomiaowux.com/meowx/windows/MeowX-0.1.3-windows-amd64-portable.zip',
    'size': 60210602,
    'sha256': 'e088b9fb4b48a72e3dc696492d63e55509a16281a08714e919b127766c18606e',
  },
];

void main() {
  test('安装版：按编译期后缀匹配到 setup 包', () {
    final f = pickUpdateFile(_files, portable: false, assetSuffix: 'windows-amd64-setup.exe');
    expect(f?.kind, 'setup');
    expect(f?.name, 'MeowX-0.1.3-windows-amd64-setup.exe');
    expect(f?.size, 46893269);
    // sha256 统一小写，后面和 Digest.toString() 直接比
    expect(f?.sha256, '07e18a54a7b2e4986f51d5a9612745b6ada4794e5b3eec72823dc16cdc90e663');
  });

  test('便携版：只认 kind=portable，与后缀无关', () {
    final f = pickUpdateFile(_files, portable: true, assetSuffix: 'windows-amd64-setup.exe');
    expect(f?.kind, 'portable');
    expect(f?.url, endsWith('-portable.zip'));
  });

  test('便携版没配便携包 → null，绝不回落到安装包', () {
    expect(pickUpdateFile([_files[0]], portable: true, assetSuffix: 'windows-amd64-setup.exe'), isNull);
  });

  test('后缀不匹配 / 后缀为空 → null', () {
    expect(pickUpdateFile(_files, portable: false, assetSuffix: 'windows-arm64-setup.exe'), isNull);
    expect(pickUpdateFile(_files, portable: false, assetSuffix: ''), isNull);
  });

  test('缺 url 的条目跳过；非 Map 元素忽略', () {
    final f = pickUpdateFile(
      [
        null,
        'junk',
        {'kind': 'portable', 'name': 'x.zip'},
        _files[1],
      ],
      portable: true,
      assetSuffix: '',
    );
    expect(f?.name, 'MeowX-0.1.3-windows-amd64-portable.zip');
  });

  group('地址钉死在发布域名', () {
    test('isTrustedUpdateUrl：只认 https + dl.miaomiaowux.com', () {
      expect(isTrustedUpdateUrl('https://dl.miaomiaowux.com/meowx/windows/a.exe'), isTrue);
      expect(isTrustedUpdateUrl('https://dl.miaomiaowux.com:443/meowx/windows/a.exe'), isTrue);
      // 明文
      expect(isTrustedUpdateUrl('http://dl.miaomiaowux.com/meowx/windows/a.exe'), isFalse);
      // 别的主机 / 前后缀混淆 / userinfo 伪装
      expect(isTrustedUpdateUrl('https://dl.example/meowx/windows/a.exe'), isFalse);
      expect(isTrustedUpdateUrl('https://dl.miaomiaowux.com.evil.com/a.exe'), isFalse);
      expect(isTrustedUpdateUrl('https://evil.com/dl.miaomiaowux.com/a.exe'), isFalse);
      expect(isTrustedUpdateUrl('https://dl.miaomiaowux.com@evil.com/a.exe'), isFalse);
      expect(isTrustedUpdateUrl('https://127.0.0.1/a.exe'), isFalse);
      expect(isTrustedUpdateUrl(''), isFalse);
      expect(isTrustedUpdateUrl('::not a url::'), isFalse);
    });

    test('pickUpdateFile：http / 外域的条目一律跳过（安装版与便携版）', () {
      final http = {..._files[0], 'url': 'http://dl.miaomiaowux.com/meowx/windows/MeowX-0.1.3-windows-amd64-setup.exe'};
      final foreign = {..._files[1], 'url': 'https://dl.example/meowx/windows/MeowX-0.1.3-windows-amd64-portable.zip'};
      expect(pickUpdateFile([http], portable: false, assetSuffix: 'windows-amd64-setup.exe'), isNull);
      expect(pickUpdateFile([foreign], portable: true, assetSuffix: ''), isNull);
      // 前面是坏条目、后面有好的 → 取好的
      final f = pickUpdateFile([http, _files[0]], portable: false, assetSuffix: 'windows-amd64-setup.exe');
      expect(f?.url, startsWith('https://dl.miaomiaowux.com/'));
    });
  });

  test('toJson / fromJson 往返', () {
    final f = UpdateFile.fromJson(_files[1])!;
    final back = UpdateFile.fromJson(f.toJson())!;
    expect(back.kind, f.kind);
    expect(back.name, f.name);
    expect(back.url, f.url);
    expect(back.size, f.size);
    expect(back.sha256, f.sha256);
    expect(UpdateFile.fromJson(null), isNull);
  });

  test('新版本弹窗的说明行：当前版本 + 选中的包（文件名 · 大小）', () {
    final apk = UpdateFile.fromJson({
      'kind': 'apk',
      'name': 'MeowX-0.1.9-android-arm64-v8a.apk',
      'url': 'https://dl.miaomiaowux.com/meowx/android/MeowX-0.1.9-android-arm64-v8a.apk',
      'size': 62143969,
      'sha256': '02abab64ff90ff9d8aedb4ec6d01468ec24b747b032cfbe729aba0cff8a36440',
    });
    expect(updateSummaryLines(current: '0.1.8', file: apk), [
      '当前版本 v0.1.8',
      '安装包 MeowX-0.1.9-android-arm64-v8a.apk · 59.3 MB',
    ]);
    // 没匹配到本机的包（会改去下载页）：只有当前版本一行
    expect(updateSummaryLines(current: '0.1.8'), ['当前版本 v0.1.8']);
    // 清单缺 size / name 时不写出「0 KB」这类假数字
    final bare = UpdateFile.fromJson({'kind': 'apk', 'url': 'https://dl.miaomiaowux.com/meowx/android/x.apk'});
    expect(updateSummaryLines(current: '0.1.8', file: bare), ['当前版本 v0.1.8', '安装包 apk']);
  });
}
