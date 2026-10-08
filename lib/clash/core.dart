import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:bett_box/clash/clash.dart';
import 'package:bett_box/clash/interface.dart';
import 'package:bett_box/common/common.dart';
import 'package:bett_box/enum/enum.dart';
import 'package:bett_box/models/models.dart';
import 'package:bett_box/state.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart';

/// MeowX：一次拉到的代理组，带内容摘要（内容相同 ⇔ 摘要相同，用来判断要不要通知界面）。
typedef GroupsSnapshot = ({List<Group> groups, int digest});

const GroupsSnapshot emptyGroupsSnapshot = (groups: <Group>[], digest: 0);

/// MeowX：代理组内容的摘要（FNV-1a 64 位；VM 上 int 乘法自然回绕）。覆盖 Group / Proxy 的全部字段——模型加了字段这里要跟着加。
/// 不用 hashCode / Object.hash：它们不保证跨 isolate 一致，而每次刷新都是在一个新的 worker isolate 里算的。
int groupsDigest(List<Group> groups) {
  const prime = 0x100000001b3;
  var hash = 0xcbf29ce484222325;
  // 字符串按 UTF-16 码元喂；码元最大 0xffff，更大的数留给标记：字段结束 / null / 组结束，
  // 这样「ab」+「c」与「a」+「bc」、null 与空串算出来都不同
  void add(String? value) {
    if (value == null) {
      hash = (hash ^ 0x10001) * prime;
      return;
    }
    for (var i = 0; i < value.length; i++) {
      hash = (hash ^ value.codeUnitAt(i)) * prime;
    }
    hash = (hash ^ 0x10000) * prime;
  }

  for (final group in groups) {
    add(group.name);
    add(group.type.name);
    add(group.now);
    add(group.hidden?.toString());
    add(group.testUrl);
    add(group.icon);
    for (final proxy in group.all) {
      add(proxy.name);
      add(proxy.type);
      add(proxy.now);
    }
    hash = (hash ^ 0x10002) * prime;
  }
  return hash;
}

/// MeowX：在 worker isolate 里跑。[rawResult] 是 getProxies 的原始回包（信封 JSON，节点表在 `data` 里）；
/// 外部 provider 的节点要么给原始 JSON [providersRaw]，要么给已经建好的 [providers]（优先）。
/// 组的取法与原来一致：GLOBAL 打头，后面按 GLOBAL.all 的顺序列出其中的组；各组成员引用同一份 Proxy 实例。
GroupsSnapshot parseGroupsSnapshot(
  String rawResult, {
  String providersRaw = '',
  List<ExternalProvider>? providers,
}) {
  final envelope = json.decode(rawResult);
  final data = envelope is Map ? envelope['data'] : null;
  if (data is! Map || data.isEmpty) return emptyGroupsSnapshot;

  final allProxies = Map<String, dynamic>.from(data);
  void addProviderProxies(String providerName, List<dynamic>? proxies) {
    if (proxies == null) return;
    for (final proxy in proxies) {
      if (proxy is Map) {
        final proxyMap = Map<String, dynamic>.from(proxy);
        final name = proxyMap['name'];
        if (name != null) {
          allProxies[name] = proxyMap;
          final suffix = '[$providerName]';
          if (!name.endsWith(suffix)) {
            allProxies['$name$suffix'] = proxyMap;
          }
        }
      }
    }
  }

  if (providers != null) {
    for (final provider in providers) {
      addProviderProxies(provider.name, provider.proxies);
    }
  } else if (providersRaw.isNotEmpty) {
    for (final provider in json.decode(providersRaw) as List<dynamic>) {
      addProviderProxies(
        provider['name'] as String,
        provider['proxies'] as List<dynamic>?,
      );
    }
  }

  final globalProxy = allProxies[UsedProxy.GLOBAL.name];
  if (globalProxy == null) return emptyGroupsSnapshot;

  final allList = globalProxy['all'] as List?;
  if (allList == null) return emptyGroupsSnapshot;

  final groupTypes = GroupTypeExtension.valueList;
  final groupNames = [
    UsedProxy.GLOBAL.name,
    ...allList.where((e) {
      final proxy = allProxies[e];
      if (proxy is Map) {
        return groupTypes.contains(proxy['type']);
      }
      return false;
    }),
  ];
  // 同一个节点在几十个组里各出现一次，只建一个 Proxy，各组共用
  final proxyCache = <dynamic, Proxy>{};
  final groups = <Group>[];
  for (final groupName in groupNames) {
    final proxyData = allProxies[groupName] as Map?;
    if (proxyData == null) continue;
    final group = Map<String, dynamic>.from(
      proxyData.cast<String, dynamic>(),
    );
    final members = <Proxy>[];
    for (final name in (group['all'] ?? []) as List) {
      final p = allProxies[name];
      if (p is! Map) continue;
      members.add(
        proxyCache[name] ??= Proxy.fromJson(Map<String, dynamic>.from(p)),
      );
    }
    group['all'] = const <dynamic>[];
    groups.add(Group.fromJson(group).copyWith(all: members));
  }
  return (groups: groups, digest: groupsDigest(groups));
}

class ClashCore {
  static ClashCore? _instance;
  late ClashHandlerInterface clashInterface;

  ClashCore._internal() {
    if (system.isAndroid) {
      clashInterface = clashLib!;
    } else {
      clashInterface = clashService!;
    }
  }

  factory ClashCore() {
    _instance ??= ClashCore._internal();
    return _instance!;
  }

  Future<bool> preload() {
    return clashInterface.preload();
  }

  static Future<void> initGeo() async {
    final homePath = await appPath.homeDirPath;
    final homeDir = Directory(homePath);
    if (!await homeDir.exists()) {
      await homeDir.create(recursive: true);
    }
    const geoFileNameList = [mmdbFileName, geoSiteFileName, asnFileName, bundleMRSFileName];
    try {
      for (final geoFileName in geoFileNameList) {
        final geoFile = File(join(homePath, geoFileName));
        if (await geoFile.exists()) continue;
        final data = await rootBundle.load('assets/data/$geoFileName');
        await geoFile.writeAsBytes(data.buffer.asUint8List(), flush: true);
      }
    } catch (e) {
      exit(0);
    }
  }

  Future<bool> init() async {
    await initGeo();
    if (globalState.config.appSetting.openLogs) {
      clashCore.startLog();
    } else {
      clashCore.stopLog();
    }
    final homeDirPath = await appPath.homeDirPath;
    return await clashInterface.init(
      InitParams(homeDir: homeDirPath, version: globalState.appState.version),
    );
  }

  Future<bool> setState(CoreState state) async {
    return await clashInterface.setState(state);
  }

  Future<void> shutdown() async {
    await clashInterface.shutdown();
  }

  FutureOr<bool> get isInit => clashInterface.isInit;

  FutureOr<String> validateConfig(String data, {String? ageSecretKey}) {
    return clashInterface.validateConfig(data, ageSecretKey: ageSecretKey);
  }

  FutureOr<String> decryptAgeConfig(String data, String ageSecretKey) {
    return clashInterface.decryptAgeConfig(data, ageSecretKey);
  }

  Future<String> updateConfig(UpdateParams updateParams) async {
    return await clashInterface.updateConfig(updateParams);
  }

  Future<String> setupConfig(SetupParams setupParams) async {
    return await clashInterface.setupConfig(setupParams);
  }

  Future<List<Group>> getProxiesGroups({
    List<ExternalProvider>? preloadedProviders,
  }) async {
    final snapshot = await getGroupsSnapshot(
      preloadedProviders: preloadedProviders,
    );
    return snapshot.groups;
  }

  // MeowX：代理组 + 内容摘要。getProxies 的原始回包（字符串，跨 isolate 不拷贝）整个交给 worker：
  // 解信封、并入外部 provider 的节点、建 Group 都在那边做，UI isolate 只收结果。
  // 以前是在 UI isolate 解出整棵 Map，再被 Isolate.run 的闭包捕获、启动时整棵深拷贝一遍。
  Future<GroupsSnapshot> getGroupsSnapshot({
    List<ExternalProvider>? preloadedProviders,
  }) async {
    final raw = await clashInterface.getProxies();
    if (raw.isEmpty) return emptyGroupsSnapshot;
    // 核心还没初始化时回的是空表：信封只有百来个字符，就地看一眼，省得再去拉 provider、起 isolate
    if (raw.length < 256) {
      final data = (json.decode(raw) as Map)['data'];
      if (data is! Map || data.isEmpty) return emptyGroupsSnapshot;
    }

    // 没有预取的 provider 就把它的原始字符串一并交给 worker 解，不在这边先建一遍对象再拷过去
    final providersRaw = preloadedProviders == null
        ? await clashInterface.getExternalProviders()
        : '';

    return Isolate.run(
      () => parseGroupsSnapshot(
        raw,
        providersRaw: providersRaw,
        providers: preloadedProviders,
      ),
    );
  }

  FutureOr<String> changeProxy(ChangeProxyParams changeProxyParams) async {
    return await clashInterface.changeProxy(changeProxyParams);
  }

  Future<Mode> getMode() async {
    final modeStr = await clashInterface.getMode();
    return Mode.values.firstWhere(
      (m) => m.name == modeStr.toLowerCase(),
      orElse: () => Mode.rule,
    );
  }

  Future<List<TrackerInfo>> getConnections() async {
    final res = await clashInterface.getConnections();
    if (res.isEmpty) {
      return [];
    }
    // MeowX：连接多时快照有几百 KB，JSON 解析放到独立 isolate，别卡 UI 线程
    try {
      return await Isolate.run(() {
        final connectionsData = json.decode(res) as Map;
        final connectionsRaw = connectionsData['connections'] as List? ?? [];
        return connectionsRaw.map((e) => TrackerInfo.fromJson(e)).toList();
      });
    } catch (e) {
      commonPrint.log('Failed to parse connections: $e');
      return [];
    }
  }

  void closeConnection(String id) {
    clashInterface.closeConnection(id);
  }

  Future<void> closeConnections() async {
    await clashInterface.closeConnections();
  }

  void resetConnections() {
    clashInterface.resetConnections();
  }

  Future<List<ExternalProvider>> getExternalProviders() async {
    final externalProvidersRawString = await clashInterface
        .getExternalProviders();
    if (externalProvidersRawString.isEmpty) {
      return [];
    }
    try {
      return Isolate.run<List<ExternalProvider>>(() {
        final externalProviders =
            (json.decode(externalProvidersRawString) as List<dynamic>)
                .map((item) => ExternalProvider.fromJson(item))
                .toList();
        return externalProviders;
      });
    } catch (e) {
      commonPrint.log('Failed to parse external providers: $e');
      return [];
    }
  }

  Future<ExternalProvider?> getExternalProvider(
    String externalProviderName,
  ) async {
    final externalProvidersRawString = await clashInterface.getExternalProvider(
      externalProviderName,
    );
    if (externalProvidersRawString.isEmpty) {
      return null;
    }
    try {
      return ExternalProvider.fromJson(json.decode(externalProvidersRawString));
    } catch (e) {
      commonPrint.log('Failed to parse external provider: $e');
      return null;
    }
  }

  Future<String> updateGeoData(UpdateGeoDataParams params) {
    return clashInterface.updateGeoData(params);
  }

  Future<String> sideLoadExternalProvider({
    required String providerName,
    required String data,
  }) {
    return clashInterface.sideLoadExternalProvider(
      providerName: providerName,
      data: data,
    );
  }

  Future<String> updateExternalProvider({required String providerName}) async {
    return clashInterface.updateExternalProvider(providerName);
  }

  Future<String> parseExternalProviderContent(String providerName) {
    return clashInterface.parseExternalProviderContent(providerName);
  }

  Future<void> startListener() async {
    await clashInterface.startListener();
  }

  Future<void> stopListener() async {
    await clashInterface.stopListener();
  }

  Future<Delay> getDelay(String url, String proxyName, {String mode = ''}) async {
    final data = await clashInterface.asyncTestDelay(url, proxyName, mode: mode);
    if (data.isEmpty) {
      throw Exception('Empty delay response');
    }
    try {
      return Delay.fromJson(json.decode(data));
    } catch (e) {
      commonPrint.log('Failed to parse delay: $e');
      rethrow;
    }
  }

  Future<Map<String, dynamic>> getConfig(String id, {String? ageSecretKey}) async {
    final profilePath = await appPath.getProfilePath(id);
    final res = await clashInterface.getConfig(profilePath, ageSecretKey: ageSecretKey);
    if (res.isSuccess) {
      final data = res.data;
      if (data is Map<String, dynamic>) {
        return data;
      }
      if (data is Map) {
        return Map<String, dynamic>.from(data);
      }
      return <String, dynamic>{};
    } else {
      throw res.message;
    }
  }

  Future<Traffic> getTraffic() async {
    final trafficString = await clashInterface.getTraffic();
    if (trafficString.isEmpty) {
      return Traffic();
    }
    try {
      return Traffic.fromMap(json.decode(trafficString));
    } catch (e) {
      commonPrint.log('Failed to parse traffic: $e');
      return Traffic();
    }
  }

  Future<IpInfo?> getCountryCode(String ip) async {
    final countryCode = await clashInterface.getCountryCode(ip);
    if (countryCode.isEmpty) {
      return null;
    }
    return IpInfo(ip: ip, countryCode: countryCode);
  }

  Future<Traffic> getTotalTraffic() async {
    final totalTrafficString = await clashInterface.getTotalTraffic();
    if (totalTrafficString.isEmpty) {
      return Traffic();
    }
    try {
      return Traffic.fromMap(json.decode(totalTrafficString));
    } catch (e) {
      commonPrint.log('Failed to parse total traffic: $e');
      return Traffic();
    }
  }

  Future<int> getMemory() async {
    final value = await clashInterface.getMemory();
    if (value.isEmpty) {
      return 0;
    }
    return int.parse(value);
  }

  Future<CoreStatus?> getCoreStatus() async {
    final value = await clashInterface.getCoreStatus();
    if (value.isEmpty) {
      return null;
    }
    final decoded = json.decode(value);
    if (decoded is! Map) {
      return null;
    }
    return CoreStatus.fromJson(Map<String, dynamic>.from(decoded));
  }

  void resetTraffic() {
    clashInterface.resetTraffic();
  }

  void startLog() {
    clashInterface.startLog();
  }

  void stopLog() {
    clashInterface.stopLog();
  }

  Future<void> requestGc({bool forceFreeOSMemory = false}) async {
    await clashInterface.forceGc(forceFreeOSMemory: forceFreeOSMemory);
  }

  Future<void> flushFakeIP() async {
    await clashInterface.flushFakeIP();
  }

  Future<void> flushDnsCache() async {
    await clashInterface.flushDnsCache();
  }

  Future<Map<String, String>> generateAgeKeyPair() {
    return clashInterface.generateAgeKeyPair();
  }

  Future<Result<String>> convertAgeSecretKeyToPublicKey(String secretKey) {
    return clashInterface.convertAgeSecretKeyToPublicKey(secretKey);
  }

  Future<void> destroy() async {
    await clashInterface.destroy();
  }
}

final clashCore = ClashCore();