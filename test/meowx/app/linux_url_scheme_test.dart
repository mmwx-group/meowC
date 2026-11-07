import 'package:bett_box/meowx/app/linux_url_scheme.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('AppImage 深链入口', () {
    test('普通路径：Exec 加引号带 %u，登记三个 scheme，带 TryExec、不进菜单', () {
      final entry = appImageUrlHandlerEntry('/home/u/Apps/MeowX-0.5.0-linux-amd64.AppImage');
      expect(entry, contains('Exec="/home/u/Apps/MeowX-0.5.0-linux-amd64.AppImage" %u\n'));
      expect(entry, contains('TryExec=/home/u/Apps/MeowX-0.5.0-linux-amd64.AppImage\n'));
      expect(entry, contains('MimeType=x-scheme-handler/miaomiaowu;x-scheme-handler/clash;x-scheme-handler/clashmeta;\n'));
      expect(entry, contains('NoDisplay=true\n'));
      expect(entry, startsWith('[Desktop Entry]\n'));
    });

    // 这两条的写法在 Ubuntu 22.04 的 GLib 2.72 上用 gio launch 实测过：能拉起、参数对；文件删掉后入口不再被认
    test('特殊字符：引号里 " ` \$ \\ 加反斜杠，字面反斜杠在文件里是四个', () {
      final entry = appImageUrlHandlerEntry(r'/home/u/My Apps/a$b"d`e\f.AppImage');
      expect(entry, contains(r'Exec="/home/u/My Apps/a\\$b\\"d\\`e\\\\f.AppImage" %u' '\n'));
      expect(entry, contains(r'TryExec=/home/u/My Apps/a$b"d`e\\f.AppImage' '\n'));
    });

    test('路径里有 % 或换行：不登记（GLib 拿没展开 %% 的 Exec 找程序，入口会整个不认）', () {
      expect(appImageUrlHandlerEntry('/home/u/MeowX%20(1).AppImage'), isNull);
      expect(appImageUrlHandlerEntry('/home/u/a\nb.AppImage'), isNull);
    });
  });

  group('启动参数里的深链', () {
    test('取第一个认得的 scheme，其余参数不管；scheme 不分大小写', () {
      final got = linuxLaunchLink(['--hidden', 'https://example.com', 'miaomiaowu://login?host=p.example.com&code=1', 'clash://install-config?url=x']);
      expect(got?.host, 'login');
      expect(got?.queryParameters['code'], '1');
      expect(linuxLaunchLink(['ClashMeta://install-config?url=https%3A%2F%2Fa.example%2Fs'])?.queryParameters['url'], 'https://a.example/s');
      expect(linuxLaunchLink(['--exit']), isNull);
      expect(linuxLaunchLink([]), isNull);
    });
  });
}
