import 'package:bett_box/meowx/state/mesh.dart';
import 'package:bett_box/meowx/state/meow_settings.dart';
import 'package:bett_box/meowx/state/status.dart';
import 'package:bett_box/models/meow.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _Meow extends MeowSetting {
  _Meow(this.initial);
  final MeowSettings initial;

  @override
  MeowSettings build() => initial;

  @override
  void onUpdate(MeowSettings value) {}
}

ProviderContainer _container(MeowSettings meow) {
  final c = ProviderContainer(
    overrides: [
      isRunningProvider.overrideWithValue(false),
      meowSettingProvider.overrideWith(() => _Meow(meow)),
    ],
  );
  addTearDown(c.dispose);
  return c;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('喵窝关着：存下规范化后的自定义名，入网时用的 hostname 不动；不合法的不存；留空清掉', () async {
    final c = _container(const MeowSettings(mesh: MeowMesh(hostname: 'sm-s9180')));
    final mesh = c.read(meshProvider.notifier);
    expect(await mesh.setCustomHostname('Living Room'), isNull);
    expect(c.read(meowSettingProvider).mesh.customHostname, 'living-room');
    expect(c.read(meowSettingProvider).mesh.hostname, 'sm-s9180');
    expect(await mesh.setCustomHostname('客厅'), '设备名只能用英文字母、数字和横线');
    expect(c.read(meowSettingProvider).mesh.customHostname, 'living-room');
    expect(await mesh.setCustomHostname('  '), isNull);
    expect(c.read(meowSettingProvider).mesh.customHostname, '');
  });

  test('喵窝开着：生成运行配置用的 hostname 跟着换成新名字，留空换回自动名', () async {
    final c = _container(
      const MeowSettings(mesh: MeowMesh(enabled: true, controlUrl: 'https://ctl.example', hostname: 'old-name')),
    );
    final mesh = c.read(meshProvider.notifier);
    expect(await mesh.setCustomHostname('NAS-Home'), isNull);
    var m = c.read(meowSettingProvider).mesh;
    expect((m.customHostname, m.hostname), ('nas-home', 'nas-home'));
    expect(meshRuntime.injection(c.read(meowSettingProvider))!.hostname, 'nas-home');
    expect(await mesh.setCustomHostname(''), isNull);
    m = c.read(meowSettingProvider).mesh;
    expect(m.customHostname, '');
    expect(m.hostname, await MeshController.deviceHostname());
  });
}
