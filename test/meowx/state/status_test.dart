import 'dart:async';

import 'package:bett_box/enum/enum.dart';
import 'package:bett_box/meowx/state/status.dart';
import 'package:bett_box/models/models.dart';
import 'package:bett_box/providers/providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

// 订阅原始配置的缓存、组当前选中的解析：各 Notifier 换成不碰 globalState / 核心的替身。

class _Profiles extends Profiles {
  _Profiles(this.initial);
  final List<Profile> initial;

  @override
  List<Profile> build() => initial;

  @override
  void onUpdate(List<Profile> value) {}
}

class _CurrentId extends CurrentProfileId {
  _CurrentId(this.initial);
  final String? initial;

  @override
  String? build() => initial;

  @override
  void onUpdate(String? value) {}
}

class _Groups extends Groups {
  _Groups(this.initial);
  final List<Group> initial;

  @override
  List<Group> build() => initial;

  @override
  void onUpdate(List<Group> value) {}
}

Profile _profile(String id, {DateTime? updated, String? key}) => Profile(
  id: id,
  label: id,
  autoUpdateDuration: const Duration(days: 1),
  lastUpdateDate: updated ?? DateTime(2026, 10, 1),
  ageSecretKey: key,
);

Map<String, dynamic> _config(String mode, String nodeType) => {
  'dns': {'enhanced-mode': mode},
  'proxies': [
    {'name': '香港 01', 'type': nodeType, 'tls': true, 'flow': 'xtls-rprx-vision'},
  ],
};

/// 等挂着的取数与随后的通知走完。
Future<void> _settle() => Future<void>.delayed(Duration.zero);

void main() {
  group('profileRawConfigProvider', () {
    late List<(String, String?)> calls;
    late ProviderContainer container;
    // 核心怎么答；默认每份订阅各有一份配置，个别用例换成丢包 / 报错 / 空表
    late Future<Map<String, dynamic>> Function(String id, String? key) respond;

    void setProfiles(List<Profile> profiles) => container.read(profilesProvider.notifier).value = profiles;
    Profile profile(String id) => container.read(profilesProvider).firstWhere((p) => p.id == id);

    setUp(() {
      calls = [];
      respond = (id, key) async => id == 'p1' ? _config('fake-ip', 'vless') : _config('redir-host', 'trojan');
      final delays = rawConfigRetryDelays;
      rawConfigRetryDelays = const [Duration(milliseconds: 5), Duration(milliseconds: 5)];
      addTearDown(() => rawConfigRetryDelays = delays);
      container = ProviderContainer(
        overrides: [
          profilesProvider.overrideWith(() => _Profiles([_profile('p1'), _profile('p2')])),
          currentProfileIdProvider.overrideWith(() => _CurrentId('p1')),
          rawConfigFetcherProvider.overrideWithValue((id, key) {
            calls.add((id, key));
            return respond(id, key);
          }),
        ],
      );
      addTearDown(container.dispose);
      // 首页的 DNS 格、节点页的网格在真实界面里一直订着这两个
      container.listen(declaredDnsModeProvider, (_, _) {});
      container.listen(proxyMetaProvider, (_, _) {});
    });

    test('点节点 / 换组 / 订阅的其它元信息变了都不重取', () async {
      await _settle();
      expect(calls, [('p1', null)]);
      expect(container.read(declaredDnsModeProvider), 'fake-ip');
      final metas = container.read(proxyMetaProvider);
      expect(metas['香港 01']?.securitySubtitle, 'tls · vision');

      setProfiles([profile('p1').copyWith(selectedMap: {'节点选择': '香港 01'}), profile('p2')]);
      await _settle();
      setProfiles([profile('p1').copyWith(currentGroupName: '自动选择'), profile('p2')]);
      await _settle();
      setProfiles([profile('p1').copyWith(label: '改了名', unfoldSet: {'自动选择'}), profile('p2')]);
      await _settle();

      expect(calls, hasLength(1));
      // 没重取，节点元信息还是同一张表，网格不会因此重建
      expect(identical(container.read(proxyMetaProvider), metas), isTrue);
    });

    test('订阅文件更新（lastUpdateDate 变）或换了解密密钥才重取', () async {
      await _settle();
      expect(calls, hasLength(1));

      setProfiles([profile('p1').copyWith(lastUpdateDate: DateTime(2026, 10, 8)), profile('p2')]);
      await _settle();
      expect(calls, [('p1', null), ('p1', null)]);

      setProfiles([profile('p1').copyWith(ageSecretKey: 'AGE-SECRET-KEY-1'), profile('p2')]);
      await _settle();
      expect(calls.last, ('p1', 'AGE-SECRET-KEY-1'));
      expect(calls, hasLength(3));
    });

    test('切换订阅各取一次；切走的那份释放，切回来再取', () async {
      await _settle();
      container.read(currentProfileIdProvider.notifier).value = 'p2';
      await _settle();
      expect(calls, [('p1', null), ('p2', null)]);
      expect(container.read(declaredDnsModeProvider), 'redir-host');

      container.read(currentProfileIdProvider.notifier).value = 'p1';
      await _settle();
      expect(calls, [('p1', null), ('p2', null), ('p1', null)]);
      expect(container.read(declaredDnsModeProvider), 'fake-ip');
    });

    test('核心硬重启期间不发请求，重启完问新核心；重启前发出去、丢在旧 socket 上的那次不作数', () async {
      await _settle();
      // 桌面切订阅：请求先发出去，随后核心硬重启把 socket 关了，这次请求永远等不到回包
      var lost = 0;
      final ok = respond;
      respond = (id, key) {
        if (id == 'p2' && lost++ == 0) return Completer<Map<String, dynamic>>().future;
        return ok(id, key);
      };
      container.read(currentProfileIdProvider.notifier).value = 'p2';
      await _settle();
      expect(calls, [('p1', null), ('p2', null)]);
      expect(container.read(declaredDnsModeProvider), isNull);

      container.read(isRestartingCoreProvider.notifier).state = true;
      await _settle();
      expect(calls, hasLength(2));

      container.read(isRestartingCoreProvider.notifier).state = false;
      await _settle();
      expect(calls, [('p1', null), ('p2', null), ('p2', null)]);
      expect(container.read(declaredDnsModeProvider), 'redir-host');
      expect(container.read(proxyMetaProvider)['香港 01']?.type, 'trojan');
    });

    test('重启标志先立起来再切订阅：重启完才发第一次；已有的那份在重启期间照旧显示', () async {
      await _settle();
      container.read(isRestartingCoreProvider.notifier).state = true;
      await _settle();
      // 重启核心（没换订阅）期间沿用上一份，不闪成空表
      expect(container.read(declaredDnsModeProvider), 'fake-ip');
      expect(calls, hasLength(1));

      container.read(currentProfileIdProvider.notifier).value = 'p2';
      await _settle();
      expect(calls, hasLength(1));

      container.read(isRestartingCoreProvider.notifier).state = false;
      await _settle();
      expect(calls, [('p1', null), ('p2', null)]);
      expect(container.read(declaredDnsModeProvider), 'redir-host');
    });

    test('超时回来的空表 / 核心报错不当成结果存下，隔一会儿重试到取到为止', () async {
      await _settle();
      var n = 0;
      final ok = respond;
      respond = (id, key) async {
        if (id != 'p2') return ok(id, key);
        n++;
        if (n == 1) return <String, dynamic>{};
        if (n == 2) throw 'open profile: no such file';
        return ok(id, key);
      };
      container.read(currentProfileIdProvider.notifier).value = 'p2';
      await _settle();
      expect(container.read(declaredDnsModeProvider), isNull);

      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(calls.where((c) => c.$1 == 'p2'), hasLength(3));
      expect(container.read(declaredDnsModeProvider), 'redir-host');
    });

    test('一直取不到：重试次数有上限，之后认空表；切走的订阅不再重试', () async {
      await _settle();
      respond = (id, key) async => <String, dynamic>{};
      container.read(currentProfileIdProvider.notifier).value = 'p2';
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(calls.where((c) => c.$1 == 'p2'), hasLength(1 + rawConfigRetryDelays.length));
      expect(container.read(profileRawConfigProvider('p2')).hasValue, isTrue);
      expect(container.read(proxyMetaProvider), isEmpty);

      // 还在重试途中就切走：那份已释放，剩下的重试不发
      rawConfigRetryDelays = const [Duration(milliseconds: 20), Duration(milliseconds: 20)];
      setProfiles([profile('p1'), profile('p2'), _profile('p3')]);
      container.read(currentProfileIdProvider.notifier).value = 'p3';
      await _settle();
      expect(calls.where((c) => c.$1 == 'p3'), hasLength(1));
      container.read(currentProfileIdProvider.notifier).value = 'missing';
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(calls.where((c) => c.$1 == 'p3'), hasLength(1));
    });

    test('订阅不存在 → 空表，不问核心', () async {
      container.read(currentProfileIdProvider.notifier).value = 'missing';
      await _settle();
      expect(calls.where((c) => c.$1 == 'missing'), isEmpty);
      expect(container.read(declaredDnsModeProvider), isNull);
      expect(container.read(proxyMetaProvider), isEmpty);
    });
  });

  group('getSelectedProxyNameProvider', () {
    const all = [Proxy(name: '香港 01', type: 'Vless'), Proxy(name: '东京 01', type: 'Trojan')];
    final groups = [
      const Group(name: '节点选择', type: GroupType.Selector, now: '香港 01', all: all),
      const Group(name: '自动选择', type: GroupType.URLTest, now: '东京 01', all: all),
      const Group(name: '故障转移', type: GroupType.Fallback, now: '', all: all),
      const Group(name: '没回报', type: GroupType.Selector, all: all),
    ];

    ProviderContainer make(Map<String, String> selected) {
      final container = ProviderContainer(
        overrides: [
          groupsProvider.overrideWith(() => _Groups(groups)),
          currentProfileProvider.overrideWithValue(
            Profile(id: 'p1', autoUpdateDuration: const Duration(days: 1), selectedMap: selected),
          ),
        ],
      );
      addTearDown(container.dispose);
      return container;
    }

    test('select 组认本地记下的选择，没记过用核心回报的 now；url-test / fallback 认 now，now 为空才用记下的', () {
      final none = make(const {});
      expect(none.read(getSelectedProxyNameProvider('节点选择')), '香港 01');
      expect(none.read(getSelectedProxyNameProvider('自动选择')), '东京 01');
      expect(none.read(getSelectedProxyNameProvider('故障转移')), '');
      expect(none.read(getSelectedProxyNameProvider('没回报')), '');
      expect(none.read(getSelectedProxyNameProvider('不存在的组')), isNull);

      final picked = make(const {'节点选择': '东京 01', '自动选择': '香港 01', '故障转移': '香港 01', '没回报': '东京 01'});
      expect(picked.read(getSelectedProxyNameProvider('节点选择')), '东京 01');
      expect(picked.read(getSelectedProxyNameProvider('自动选择')), '东京 01');
      expect(picked.read(getSelectedProxyNameProvider('故障转移')), '香港 01');
      expect(picked.read(getSelectedProxyNameProvider('没回报')), '东京 01');
    });

    test('核心回报的 now 变了跟着变；只是成员表换了一份不通知', () {
      final container = make(const {});
      final seen = <String?>[];
      container.listen(getSelectedProxyNameProvider('自动选择'), (_, next) => seen.add(next));

      container.read(groupsProvider.notifier).value = [
        for (final g in groups) g.copyWith(all: [...all, const Proxy(name: '大阪 01', type: 'Hysteria2')]),
      ];
      expect(container.read(getSelectedProxyNameProvider('自动选择')), '东京 01');
      expect(seen, isEmpty);

      container.read(groupsProvider.notifier).value = [
        for (final g in groups) g.name == '自动选择' ? g.copyWith(now: '香港 01') : g,
      ];
      expect(container.read(getSelectedProxyNameProvider('自动选择')), '香港 01');
      expect(seen, ['香港 01']);
    });
  });
}
