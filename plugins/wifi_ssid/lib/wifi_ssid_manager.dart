// 移植自 FlClash plugins/wifi_ssid（MIT，© 2025 FlClash）。MeowX 加了 [WifiNetworkState] 与两个跳设置页的方法。
import 'package:flutter/services.dart';

/// The platform permission state required to read the current Wi-Fi SSID.
enum WifiSsidPermission { granted, denied, permanentlyDenied }

/// 物理网络（不含 VPN）与读 SSID 的前提条件。
class WifiNetworkState {
  const WifiNetworkState({
    this.wifi = false,
    this.cellular = false,
    this.ethernet = false,
    this.fineLocation = false,
    this.backgroundLocation = false,
    this.locationEnabled = false,
  });

  factory WifiNetworkState.fromMap(Map<Object?, Object?> m) => WifiNetworkState(
    wifi: m['wifi'] == true,
    cellular: m['cellular'] == true,
    ethernet: m['ethernet'] == true,
    fineLocation: m['fineLocation'] == true,
    backgroundLocation: m['backgroundLocation'] == true,
    locationEnabled: m['locationEnabled'] == true,
  );

  final bool wifi;
  final bool cellular;
  final bool ethernet;

  /// 「使用时允许」的精确定位（没有它任何时候都读不到 SSID）
  final bool fineLocation;

  /// 「始终允许」（Android 10+ 在后台读 SSID 要它；更早的系统恒为 true）
  final bool backgroundLocation;

  /// 系统的定位服务开关
  final bool locationEnabled;
}

class WifiSsidManager {
  WifiSsidManager._();

  static final WifiSsidManager instance = WifiSsidManager._();

  static const _channel = MethodChannel('wifi_ssid');
  static const _getSsidMethod = 'getSsid';
  static const _checkPermissionMethod = 'checkPermission';
  static const _requestPermissionMethod = 'requestPermission';
  static const _getNetworkStateMethod = 'getNetworkState';

  /// Returns the current WiFi SSID, or null if not connected to WiFi.
  Future<String?> getSsid() {
    return _channel.invokeMethod<String>(_getSsidMethod);
  }

  Future<WifiSsidPermission> checkPermission() async {
    final result = await _channel.invokeMethod<int>(_checkPermissionMethod);
    return _decodePermission(result);
  }

  Future<WifiSsidPermission> requestPermission() async {
    final result = await _channel.invokeMethod<int>(_requestPermissionMethod);
    return _decodePermission(result);
  }

  Future<WifiNetworkState> getNetworkState() async {
    final result = await _channel.invokeMapMethod<Object?, Object?>(_getNetworkStateMethod);
    return WifiNetworkState.fromMap(result ?? const {});
  }

  /// 本应用的系统设置页（权限被永久拒绝、或要改成「始终允许」时）。
  Future<bool> openAppSettings() async => await _channel.invokeMethod<bool>('openAppSettings') ?? false;

  /// 系统的定位服务设置页。
  Future<bool> openLocationSettings() async => await _channel.invokeMethod<bool>('openLocationSettings') ?? false;

  WifiSsidPermission _decodePermission(int? value) {
    return switch (value) {
      0 => WifiSsidPermission.granted,
      2 => WifiSsidPermission.permanentlyDenied,
      null || 1 => WifiSsidPermission.denied,
      _ => throw PlatformException(
        code: 'INVALID_PERMISSION_STATE',
        message: 'Native wifi_ssid returned an invalid permission state.',
        details: value,
      ),
    };
  }
}

final wifiSsidManager = WifiSsidManager.instance;
