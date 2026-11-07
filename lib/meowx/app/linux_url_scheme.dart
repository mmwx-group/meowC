import 'dart:io';

import 'package:bett_box/common/print.dart';

/// Linux 上交给 MeowX 的深链：网页「登录客户端」与订阅一键导入（与安卓 / Windows 同一组）。
const linuxUrlSchemes = ['miaomiaowu', 'clash', 'clashmeta'];

/// 被深链拉起时（App 没开着）网址在启动参数里：取第一个认得的 scheme。
Uri? linuxLaunchLink(List<String> args) {
  for (final arg in args) {
    final uri = Uri.tryParse(arg);
    if (uri != null && linuxUrlSchemes.contains(uri.scheme)) return uri;
  }
  return null;
}

/// AppImage 没有安装这一步，桌面环境不知道它能开这几个 scheme：每次启动把自己登记成处理程序，
/// 写一个只管深链的桌面入口到 ~/.local/share/applications（不进应用菜单；AppImage 挪了位置，下次启动跟着改）。
/// deb 版由包里的桌面入口登记，不走这里。
/// 入口带 TryExec：AppImage 删掉之后桌面环境自己忽略它，不会把深链交给不存在的文件。
Future<void> registerAppImageUrlSchemes() async {
  final appImage = Platform.environment['APPIMAGE'];
  if (appImage == null || appImage.isEmpty) return;
  final content = appImageUrlHandlerEntry(appImage);
  if (content == null) return;
  final home = Platform.environment['HOME'];
  final dataHome = Platform.environment['XDG_DATA_HOME'];
  final base = (dataHome != null && dataHome.isNotEmpty) ? dataHome : (home == null ? null : '$home/.local/share');
  if (base == null) return;
  try {
    final dir = Directory('$base/applications');
    final file = File('${dir.path}/meowx-appimage.desktop');
    if (await file.exists() && await file.readAsString() == content) return;
    await dir.create(recursive: true);
    await file.writeAsString(content);
    // 刷新 mimeinfo.cache：浏览器问「谁能开 miaomiaowu://」查的是它。没装 desktop-file-utils 就算了，GIO 自己也会扫入口
    try {
      await Process.run('update-desktop-database', [dir.path]);
    } on ProcessException catch (_) {}
    commonPrint.log('AppImage url schemes registered: ${file.path}');
  } catch (e) {
    commonPrint.log('AppImage url schemes register failed: $e');
  }
}

/// 深链处理程序的桌面入口（纯函数，有单测）。路径里有 % 或换行时给 null、不登记：
/// GLib 加载入口时拿还没展开 %% 的 Exec 去找程序，找不到就整个入口不认（2.72 实测）。
String? appImageUrlHandlerEntry(String appImage) {
  if (appImage.contains('%') || appImage.contains('\n')) return null;
  final mime = linuxUrlSchemes.map((s) => 'x-scheme-handler/$s;').join();
  return '[Desktop Entry]\n'
      'Type=Application\n'
      'Name=MeowX\n'
      'Comment=MeowX (AppImage) link handler\n'
      'TryExec=${_escapeString(appImage)}\n'
      'Exec=${_escapeString(_quoteExecArg(appImage))} %u\n'
      'Icon=meowx\n'
      'Terminal=false\n'
      'NoDisplay=true\n'
      'MimeType=$mime\n'
      'StartupWMClass=com.miaomiaowux.app\n';
}

/// Exec 里的一个参数：整个加双引号，引号里的 " ` $ \ 前面加反斜杠（Desktop Entry 规范「The Exec key」）。
String _quoteExecArg(String arg) {
  final escaped = arg.replaceAllMapped(RegExp(r'["`$\\]'), (m) => '\\${m[0]}');
  return '"$escaped"';
}

/// string 类型的值：读的时候先解反斜杠转义，所以字面的反斜杠要写成两个。
String _escapeString(String value) => value.replaceAll('\\', '\\\\');
