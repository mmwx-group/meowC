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

    test('特殊字符：引号里 " ` \$ \\ 加反斜杠、% 写成 %%，字面反斜杠在文件里是四个', () {
      final entry = appImageUrlHandlerEntry(r'/home/u/My Apps/a$b%c"d`e\f.AppImage');
      expect(entry, contains(r'Exec="/home/u/My Apps/a\\$b%%c\\"d\\`e\\\\f.AppImage" %u' '\n'));
      expect(entry, contains(r'TryExec=/home/u/My Apps/a$b%c"d`e\\f.AppImage' '\n'));
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
