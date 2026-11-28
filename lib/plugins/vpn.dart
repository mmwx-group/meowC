import 'dart:convert';
import 'dart:io';

import 'package:bett_box/clash/clash.dart';
import 'package:bett_box/models/models.dart';
import 'package:bett_box/state.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

abstract mixin class VpnListener {
  void onDnsChanged(String dns) {}

  void onScreenStateChanged(bool isOn) {}

  void onNetworkChanged() {}
}

class Vpn {
  static final Vpn _instance = Vpn._internal();
  final MethodChannel methodChannel = const MethodChannel('vpn');

  Vpn._internal() {
    methodChannel.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'gc':
          clashCore.requestGc(forceFreeOSMemory: true);
          break;
        case 'closeConnections':
          clashCore.closeConnections();
          break;
        case 'status':
          return clashLibHandler?.getRunTime() != null;
        case 'dnsChanged':
          for (final listener in _listeners) {
            listener.onDnsChanged(call.arguments as String);
          }
          break;
        case 'screenStateChanged':
          final isOn = call.arguments as bool;
          globalState.isScreenOn = isOn;
          for (final listener in _listeners) {
            listener.onScreenStateChanged(isOn);
          }
          break;
        case 'networkChanged':
          for (final listener in _listeners) {
            listener.onNetworkChanged();
          }
          break;
        default:
      }
    });
  }

  factory Vpn() => _instance;

  final ObserverList<VpnListener> _listeners = ObserverList<VpnListener>();

  Future<bool?> start(AndroidVpnOptions options) async {
    return await methodChannel.invokeMethod<bool>('start', {
      'data': jsonEncode(options),
    });
  }

  Future<bool?> stop() => methodChannel.invokeMethod<bool>('stop');

  Future<List<String>> getLocalIpAddresses() async {
    return await methodChannel.invokeListMethod<String>(
          'getLocalIpAddresses',
        ) ??
        const [];
  }

  Future<List<String>> getLocalGateways() async {
    return await methodChannel.invokeListMethod<String>(
          'getLocalGateways',
        ) ??
        const [];
  }

  Future<void> setSmartStopped(bool value) async {
    await methodChannel.invokeMethod<bool>('setSmartStopped', {'value': value});
  }

  Future<bool> isSmartStopped() async {
    return await methodChannel.invokeMethod<bool>('isSmartStopped') ?? false;
  }

  Future<bool?> smartStop() => methodChannel.invokeMethod<bool>('smartStop');

  Future<bool?> smartResume(AndroidVpnOptions options) async {
    return await methodChannel.invokeMethod<bool>('smartResume', {
      'data': jsonEncode(options),
    });
  }

  /// 只用来发 directFetch 的同名通道：不设 handler（界面引擎里没有 [vpn]，也不能 new [Vpn]，
  /// 那会给 'vpn' 通道设 handler、把原生回调抢到界面这边）
  static const _directChannel = MethodChannel('vpn');

  /// MeowX：在 VPN 底下的物理网络上发一次 GET，不进自己的 VPN（android/…/plugins/DirectFetch.kt）。界面引擎、服务引擎都能调
  /// （VpnPlugin 两边都挂着）。返回 status / url / headers / body；VPN 没开、没有物理网络时返回 null。
  /// 连接层失败抛 [SocketException]（拉订阅据此换下一条路）。
  static Future<Map<Object?, Object?>?> directFetch(
    String url, {
    required Map<String, String> headers,
    required Duration connectTimeout,
    required Duration readTimeout,
    bool insecure = false,
  }) async {
    try {
      return await _directChannel.invokeMethod<Map<Object?, Object?>>('directFetch', {
        'url': url,
        'headers': headers,
        'connectTimeoutMs': connectTimeout.inMilliseconds,
        'readTimeoutMs': readTimeout.inMilliseconds,
        'insecure': insecure,
      });
    } on PlatformException catch (e) {
      throw SocketException([if (e.details != null) '${e.details}', if (e.message?.isNotEmpty == true) e.message!].join(': '));
    } on MissingPluginException {
      return null;
    }
  }

  Future<bool> getStatus() async {
    return await methodChannel.invokeMethod<bool>('status') ?? false;
  }

  Future<void> updateNotificationSpeed(
    String profileName,
    String speedInfo,
  ) async {
    await methodChannel.invokeMethod<void>('updateNotificationSpeed', {
      'profileName': profileName,
      'speedInfo': speedInfo,
    });
  }

  void addListener(VpnListener listener) => _listeners.add(listener);

  void removeListener(VpnListener listener) => _listeners.remove(listener);
}

Vpn? get vpn => globalState.isService ? Vpn() : null;
