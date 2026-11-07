import 'dart:async';

import 'package:app_links/app_links.dart';
import 'package:bett_box/meowx/app/linux_url_scheme.dart';

import 'print.dart';
import 'system.dart';
import 'window.dart';

typedef InstallConfigCallBack = void Function(String url);

class LinkManager {
  static LinkManager? _instance;
  late AppLinks _appLinks;
  StreamSubscription? subscription;

  /// MeowX（Linux）：App 没开着、被深链拉起时网址在启动参数里。app_links 的 Linux 实现
  /// 只收已经开着时别的进程转来的（见 linux/my_application.cc），这一条要自己接
  Uri? _launchLink;

  LinkManager._internal() {
    _appLinks = AppLinks();
  }

  /// MeowX（Linux，main 里调）：从启动参数里取深链；并让 app_links 先挂上接收端——它的 Linux 实现
  /// 第一次用到才注册，之前别的进程转来的深链（启动中、首次启动的免责声明还没同意时）会丢，
  /// 挂上之后收到的第一条留到 initAppLinksListen 时交出
  void initLinux(List<String> args) {
    _launchLink = linuxLaunchLink(args);
    _appLinks.getLatestLink();
  }

  Future<void> initAppLinksListen(
    Function(String url) installConfigCallBack, {
    Function(Uri uri)? loginCallBack,
  }) async {
    commonPrint.log('initAppLinksListen');
    destroy();
    void handle(Uri uri) {
      // MeowX：miaomiaowu://login?host=<主控>&code=<一次性码>
      if (uri.scheme == 'miaomiaowu' && uri.host == 'login') {
        loginCallBack?.call(uri);
        return;
      }
      if (uri.host == 'install-config') {
        final parameters = uri.queryParameters;
        final url = parameters['url'];
        if (url != null) {
          installConfigCallBack(url);
        }
      }
    }

    subscription = _appLinks.uriLinkStream.listen((uri) {
      commonPrint.log('onAppLink: $uri');
      // MeowX：Linux 上是开着时点了深链，窗口可能收在托盘里，叫到前面（Windows 由 app_links 自己做）
      if (system.isLinux) window?.show();
      handle(uri);
    });
    final launch = _launchLink;
    _launchLink = null;
    if (launch != null) {
      commonPrint.log('launchLink: $launch');
      handle(launch);
    }
  }

  void destroy() {
    subscription?.cancel();
    subscription = null;
  }

  factory LinkManager() {
    _instance ??= LinkManager._internal();
    return _instance!;
  }
}

final linkManager = LinkManager();
