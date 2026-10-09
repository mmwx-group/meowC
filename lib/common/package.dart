import 'dart:io';

import 'package:package_info_plus/package_info_plus.dart';

extension PackageInfoExtension on PackageInfo {
  // 与 iOS 端一致：`mihomo/1.19.0 MeowX/<版本> (<系统>)`。开头的 mihomo/1.19.0 不能动（主控与第三方机场按前缀或子串靠它
  // 给完整的 clash YAML）；MeowX/<版本> 是官方客户端标记，主控认出它就下发只有官方内核才支持的节点（AnyTLS + REALITY）。
  String get ua =>
      'mihomo/1.19.0 MeowX/$version (${Platform.isAndroid ? 'Android' : Platform.isWindows ? 'Windows' : Platform.operatingSystem})';
}
