import 'dart:async';
import 'dart:convert';
import 'dart:isolate';

import 'package:bett_box/clash/message.dart';
import 'package:bett_box/common/common.dart';
import 'package:bett_box/enum/enum.dart';
import 'package:bett_box/models/models.dart';

mixin ClashInterface {
  Future<bool> init(InitParams params);

  Future<bool> preload();

  Future<bool> shutdown();

  Future<bool> get isInit;

  Future<bool> forceGc({bool forceFreeOSMemory = false});

  FutureOr<String> validateConfig(String data, {String? ageSecretKey});

  FutureOr<String> decryptAgeConfig(String data, String ageSecretKey);

  FutureOr<Result> getConfig(String path, {String? ageSecretKey});

  Future<Map<String, String>> generateAgeKeyPair();

  Future<Result<String>> convertAgeSecretKeyToPublicKey(String secretKey);

  Future<String> asyncTestDelay(String url, String proxyName, {String mode = ''});

  FutureOr<String> updateConfig(UpdateParams updateParams);

  FutureOr<String> setupConfig(SetupParams setupParams);

  // MeowX：返回核心的原始回包（整个信封的 JSON 字符串），由 getProxiesGroups 交给 worker isolate 去解。
  FutureOr<String> getProxies();

  FutureOr<String> changeProxy(ChangeProxyParams changeProxyParams);

  Future<bool> startListener();

  Future<bool> stopListener();

  FutureOr<String> getExternalProviders();

  FutureOr<String>? getExternalProvider(String externalProviderName);

  Future<String> updateGeoData(UpdateGeoDataParams params);

  Future<String> sideLoadExternalProvider({
    required String providerName,
    required String data,
  });

  Future<String> updateExternalProvider(String providerName);

  FutureOr<String> parseExternalProviderContent(String providerName);

  FutureOr<String> getTraffic();

  FutureOr<String> getTotalTraffic();

  FutureOr<String> getCountryCode(String ip);

  FutureOr<String> getMemory();

  FutureOr<String> getCoreStatus();

  FutureOr<void> resetTraffic();

  FutureOr<void> startLog();

  FutureOr<void> stopLog();

  Future<bool> crash();

  FutureOr<String> getConnections();

  FutureOr<bool> closeConnection(String id);

  FutureOr<bool> closeConnections();

  FutureOr<bool> resetConnections();

  Future<bool> setState(CoreState state);

  FutureOr<bool> flushFakeIP();

  FutureOr<bool> flushDnsCache();

  Future<String> getMode();
}

mixin AndroidClashInterface {
  Future<bool> updateDns(String value);

  Future<AndroidVpnOptions?> getAndroidVpnOptions();

  Future<String> getCurrentProfileName();

  Future<DateTime?> getRunTime();
}

abstract class ClashHandlerInterface with ClashInterface {
  Map<String, Completer> callbackCompleterMap = {};

  Future<void> handleResult(ActionResult result) async {
    final completer = callbackCompleterMap[result.id];
    try {
      switch (result.method) {
        case ActionMethod.message:
          clashMessage.controller.add(result.data);
          completer?.complete(true);
          return;
        case ActionMethod.getConfig:
        case ActionMethod.convertAgeSecretKeyToPublicKey:
          completer?.complete(result.toResult);
          return;
        case ActionMethod.generateAgeKeyPair:
          completer?.complete(result.data);
          return;
        case ActionMethod.getProxies:
          // MeowX：没走成 handleRawResult 的快路径时的兜底，重新包成同样形状的字符串
          completer?.complete(json.encode({'data': result.data}));
          return;
        default:
          completer?.complete(result.data);
          return;
      }
    } catch (e) {
      commonPrint.log('${result.id} error $e');
    }
  }

  // MeowX：getProxies 的回包有几百 KB 到几 MB（每个节点带延迟历史等十几个字段），不在这里（UI isolate）解码，
  // 原样把字符串交给调用方。核心的 ActionResult 按 id、method、data 的顺序输出（core/action.go），
  // 所以这类回包一定以下面的前缀开头；哪天对不上了就走原来的整包解码，见 handleResult 的 getProxies 分支。
  static const _rawProxiesPrefix = '{"id":"getProxies#';
  static const _rawIdStart = 7; // '{"id":"' 之后

  /// 核心发来的每条消息（回包与推送）都从这里进。
  void handleRawResult(String raw) {
    if (raw.startsWith(_rawProxiesPrefix)) {
      final idEnd = raw.indexOf('"', _rawIdStart);
      if (idEnd > 0) {
        // 没有等它的人（已超时）就丢掉，和 handleResult 里 completer 为空时一样
        final completer = callbackCompleterMap.remove(
          raw.substring(_rawIdStart, idEnd),
        );
        if (completer != null && !completer.isCompleted) {
          completer.complete(raw);
        }
        return;
      }
    }
    handleResult(ActionResult.fromJson(json.decode(raw)));
  }

  void sendMessage(String message);

  FutureOr<void> reStart();

  FutureOr<bool> destroy();

  Future<T> invoke<T>({
    required ActionMethod method,
    dynamic data,
    Duration? timeout,
    FutureOr<T> Function()? onTimeout,
    T? defaultValue,
  }) async {
    final id = '${method.name}#${utils.id}';

    callbackCompleterMap[id] = Completer<T>();

    dynamic mDefaultValue = defaultValue;
    if (mDefaultValue == null) {
      if (T == String) {
        mDefaultValue = '';
      } else if (T == bool) {
        mDefaultValue = false;
      } else if (T == Map) {
        mDefaultValue = <String, dynamic>{};
      }
    }

    sendMessage(json.encode(Action(id: id, method: method, data: data)));

    return (callbackCompleterMap[id] as Completer<T>).safeFuture(
      timeout: timeout,
      onLast: () {
        callbackCompleterMap.remove(id);
      },
      onTimeout:
          onTimeout ??
          () {
            return mDefaultValue;
          },
      functionName: id,
    );
  }

  @override
  Future<bool> init(InitParams params) {
    return invoke<bool>(
      method: ActionMethod.initClash,
      data: json.encode(params),
    );
  }

  @override
  Future<bool> setState(CoreState state) {
    return invoke<bool>(
      method: ActionMethod.setState,
      data: json.encode(state),
    );
  }

  @override
  shutdown() async {
    return await invoke<bool>(
      method: ActionMethod.shutdown,
      timeout: Duration(seconds: 1),
    );
  }

  @override
  Future<bool> get isInit {
    return invoke<bool>(method: ActionMethod.getIsInit);
  }

  @override
  Future<bool> forceGc({bool forceFreeOSMemory = false}) {
    return invoke<bool>(
      method: ActionMethod.forceGc,
      data: forceFreeOSMemory ? 'true' : 'false',
    );
  }

  @override
  FutureOr<String> validateConfig(String data, {String? ageSecretKey}) {
    final params = {
      'data': data,
      'age-secret-key': ageSecretKey ?? '',
    };
    return invoke<String>(
      method: ActionMethod.validateConfig,
      data: json.encode(params),
    );
  }

  @override
  FutureOr<String> decryptAgeConfig(String data, String ageSecretKey) {
    final params = {
      'data': data,
      'age-secret-key': ageSecretKey,
    };
    return invoke<String>(
      method: ActionMethod.decryptAgeConfig,
      data: json.encode(params),
    );
  }

  @override
  Future<String> updateConfig(UpdateParams updateParams) async {
    return await invoke<String>(
      method: ActionMethod.updateConfig,
      data: json.encode(updateParams),
      timeout: const Duration(seconds: 60),
    );
  }

  @override
  Future<Result> getConfig(String path, {String? ageSecretKey}) async {
    final params = {
      'path': path,
      'age-secret-key': ageSecretKey ?? '',
    };
    final res = await invoke<Result>(
      method: ActionMethod.getConfig,
      data: json.encode(params),
      timeout: const Duration(seconds: 60),
      defaultValue: Result.success(<String, dynamic>{}),
    );
    return res;
  }

  @override
  Future<String> setupConfig(SetupParams setupParams) async {
    final data = await Isolate.run(() => json.encode(setupParams));
    return await invoke<String>(
      method: ActionMethod.setupConfig,
      data: data,
      timeout: const Duration(seconds: 60),
    );
  }

  @override
  Future<bool> crash() {
    return invoke<bool>(method: ActionMethod.crash);
  }

  @override
  Future<String> getProxies() {
    return invoke<String>(
      method: ActionMethod.getProxies,
      timeout: Duration(seconds: 5),
    );
  }

  @override
  FutureOr<String> changeProxy(ChangeProxyParams changeProxyParams) {
    return invoke<String>(
      method: ActionMethod.changeProxy,
      data: json.encode(changeProxyParams),
    );
  }

  @override
  FutureOr<String> getExternalProviders() {
    return invoke<String>(method: ActionMethod.getExternalProviders);
  }

  @override
  FutureOr<String> getExternalProvider(String externalProviderName) {
    return invoke<String>(
      method: ActionMethod.getExternalProvider,
      data: externalProviderName,
    );
  }

  @override
  Future<String> updateGeoData(UpdateGeoDataParams params) {
    return invoke<String>(
      method: ActionMethod.updateGeoData,
      data: json.encode(params),
      timeout: Duration(minutes: 1),
    );
  }

  @override
  Future<String> sideLoadExternalProvider({
    required String providerName,
    required String data,
  }) {
    return invoke<String>(
      method: ActionMethod.sideLoadExternalProvider,
      data: json.encode({'providerName': providerName, 'data': data}),
    );
  }

  @override
  Future<String> updateExternalProvider(String providerName) {
    return invoke<String>(
      method: ActionMethod.updateExternalProvider,
      data: providerName,
      timeout: Duration(minutes: 1),
    );
  }

  @override
  Future<String> parseExternalProviderContent(String providerName) {
    return invoke<String>(
      method: ActionMethod.parseExternalProviderContent,
      data: providerName,
    );
  }

  @override
  FutureOr<String> getConnections() {
    return invoke<String>(method: ActionMethod.getConnections);
  }

  @override
  Future<bool> closeConnections() {
    return invoke<bool>(method: ActionMethod.closeConnections);
  }

  @override
  Future<bool> resetConnections() {
    return invoke<bool>(method: ActionMethod.resetConnections);
  }

  @override
  Future<bool> closeConnection(String id) {
    return invoke<bool>(method: ActionMethod.closeConnection, data: id);
  }

  @override
  FutureOr<String> getTotalTraffic() {
    return invoke<String>(method: ActionMethod.getTotalTraffic);
  }

  @override
  FutureOr<String> getTraffic() {
    return invoke<String>(method: ActionMethod.getTraffic);
  }

  @override
  resetTraffic() {
    invoke(method: ActionMethod.resetTraffic);
  }

  @override
  startLog() {
    invoke(method: ActionMethod.startLog);
  }

  @override
  stopLog() {
    invoke<bool>(method: ActionMethod.stopLog);
  }

  @override
  Future<bool> startListener() {
    return invoke<bool>(method: ActionMethod.startListener);
  }

  @override
  stopListener() {
    return invoke<bool>(method: ActionMethod.stopListener);
  }

  @override
  Future<String> asyncTestDelay(String url, String proxyName, {String mode = ''}) {
    final delayParams = {
      'proxy-name': proxyName,
      'timeout': httpTimeoutDuration.inMilliseconds,
      'test-url': url,
      'mode': mode,
    };
    return invoke<String>(
      method: ActionMethod.asyncTestDelay,
      data: json.encode(delayParams),
      timeout: Duration(milliseconds: 6000),
      onTimeout: () {
        return json.encode(Delay(name: proxyName, value: -1, url: url));
      },
    );
  }

  @override
  FutureOr<String> getCountryCode(String ip) {
    return invoke<String>(method: ActionMethod.getCountryCode, data: ip);
  }

  @override
  FutureOr<String> getMemory() {
    return invoke<String>(method: ActionMethod.getMemory);
  }

  @override
  FutureOr<String> getCoreStatus() {
    return invoke<String>(method: ActionMethod.getCoreStatus);
  }

  @override
  FutureOr<bool> flushFakeIP() {
    return invoke<bool>(method: ActionMethod.flushFakeIP);
  }

  @override
  FutureOr<bool> flushDnsCache() {
    return invoke<bool>(method: ActionMethod.flushDnsCache);
  }

  @override
  Future<String> getMode() {
    return invoke<String>(method: ActionMethod.getMode);
  }

  @override
  Future<Map<String, String>> generateAgeKeyPair() async {
    final res = await invoke<Map>(
      method: ActionMethod.generateAgeKeyPair,
    );
    return res.map((key, value) => MapEntry(key.toString(), value.toString()));
  }

  @override
  Future<Result<String>> convertAgeSecretKeyToPublicKey(String secretKey) async {
    final res = await invoke<Result>(
      method: ActionMethod.convertAgeSecretKeyToPublicKey,
      data: secretKey,
      defaultValue: Result.error('error'),
    );
    return Result<String>(
      data: res.data?.toString(),
      type: res.type,
      message: res.message,
    );
  }
}
