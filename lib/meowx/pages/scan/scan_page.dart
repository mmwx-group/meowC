import 'dart:async';
import 'dart:math' as math;

import 'package:bett_box/common/common.dart';
import 'package:bett_box/plugins/app.dart';
import 'package:bett_box/state.dart';
import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../../theme/m3.dart';
import '../../theme/m3_kit.dart';

/// 扫码页（M3 改版后我们自己的一份，取代 Bettbox 的 `lib/pages/scan.dart`）：扫到的原文交回调用方
/// （登录码 `miaomiaowu://…` / 订阅链接由调用方各自解析）；相册选图同样交回。
/// 权限与相机起停的逻辑照搬原页（含 MeowX 在原页上修过的两处：没授权过时主动申请一次；
/// 申请授权那次启动的相机先停掉、等扫码组件挂上再正式启动，否则第一次打开对准了也识别不到）。
class MeowScanPage extends StatefulWidget {
  const MeowScanPage({super.key});

  @override
  State<MeowScanPage> createState() => _MeowScanPageState();
}

class _MeowScanPageState extends State<MeowScanPage> with WidgetsBindingObserver {
  final controller = MobileScannerController(
    detectionSpeed: DetectionSpeed.noDuplicates,
    formats: const [BarcodeFormat.qrCode],
    autoStart: false, // 手动控制启动时机，见 [_checkCameraPermission]
  );

  StreamSubscription<Object?>? _subscription;
  bool _permissionDenied = false;
  bool _permissionChecking = false;
  bool _permissionRequested = false; // 只主动申请一次，拒绝后回到设置引导

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _subscription = controller.barcodes.listen(_handleBarcode);
    WidgetsBinding.instance.addPostFrameCallback((_) => _checkCameraPermission());
  }

  void _handleBarcode(BarcodeCapture capture) {
    // 登录码是自定义 scheme，ML Kit 会判成 text 而不是 url：原样交给调用方
    final raw = capture.barcodes.first.rawValue;
    if (raw != null && raw.isNotEmpty) {
      Navigator.pop<String>(context, raw);
    } else {
      Navigator.pop(context);
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    switch (state) {
      case AppLifecycleState.detached:
      case AppLifecycleState.hidden:
      case AppLifecycleState.paused:
        return;
      case AppLifecycleState.resumed:
        _subscription ??= controller.barcodes.listen(_handleBarcode);
        // 从系统设置回来：再查一次权限
        _checkCameraPermission();
        return;
      case AppLifecycleState.inactive:
        unawaited(_subscription?.cancel());
        _subscription = null;
        if (controller.value.isRunning) unawaited(controller.stop());
        return;
    }
  }

  Future<void> _checkCameraPermission() async {
    if (_permissionChecking) return;
    setState(() => _permissionChecking = true);

    var granted = await app.hasCameraPermission();
    if (!granted && !_permissionRequested) {
      // 没授权过的机器：mobile_scanner 的 start() 会弹系统权限请求，弹完再查一次
      _permissionRequested = true;
      try {
        await controller.start();
      } catch (e) {
        commonPrint.log('Camera permission request: $e');
      }
      granted = await app.hasCameraPermission();
      // 这次 start 只为弹授权框，扫码组件还没挂上：先停掉，下面等组件挂上后再正式启动
      if (controller.value.isRunning) {
        try {
          await controller.stop();
        } catch (e) {
          commonPrint.log('Camera stop after permission request: $e');
        }
      }
    }
    if (!mounted) return;
    setState(() {
      _permissionDenied = !granted;
      _permissionChecking = false;
    });

    if (!granted) {
      if (controller.value.isRunning) await controller.stop();
      return;
    }
    // 等扫码组件挂上（上面的 setState 那一帧画完）再启动
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted || controller.value.isRunning) return;
    try {
      await controller.start();
    } catch (e) {
      commonPrint.log('Camera start error: $e');
    }
  }

  Future<void> _pickFromGallery() async {
    try {
      final raw = await picker.pickerQRCodeRaw();
      if (raw != null && mounted) Navigator.pop<String>(context, raw);
    } catch (e) {
      globalState.showNotifier(e.toString());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_subscription?.cancel());
    _subscription = null;
    unawaited(controller.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cs = context.cs;
    final size = MediaQuery.sizeOf(context);
    final side = math.min(320.0, size.width * 0.7);
    final scanWindow = Rect.fromCenter(center: size.center(Offset.zero), width: side, height: side);
    final camera = !_permissionChecking && !_permissionDenied;
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          Positioned.fill(
            child: _permissionChecking
                ? const ColoredBox(color: Colors.black)
                : _permissionDenied
                ? _message(
                    icon: Icons.no_photography_outlined,
                    title: '相机权限被拒绝',
                    body: '扫描二维码需要相机权限，请在系统设置中授予相机权限。',
                  )
                : MobileScanner(
                    controller: controller,
                    scanWindow: scanWindow,
                    errorBuilder: (context, error) {
                      if (error.errorCode == MobileScannerErrorCode.permissionDenied) {
                        if (!_permissionDenied && mounted) {
                          WidgetsBinding.instance.addPostFrameCallback((_) {
                            if (mounted) setState(() => _permissionDenied = true);
                          });
                        }
                        unawaited(controller.stop());
                        return _message(
                          icon: Icons.no_photography_outlined,
                          title: '相机权限被拒绝',
                          body: '扫描二维码需要相机权限，请在系统设置中授予相机权限。',
                        );
                      }
                      return _message(icon: Icons.error_outline_rounded, title: '相机打不开', body: _errorText(error));
                    },
                  ),
          ),
          if (camera) Positioned.fill(child: CustomPaint(painter: _ScanOverlay(scanWindow: scanWindow, color: cs.primary))),
          if (camera)
            Positioned(
              left: 24,
              right: 24,
              top: scanWindow.bottom + 24,
              child: const Text(
                '对准 MeowX 登录码或订阅二维码',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w600),
              ),
            ),
          // 顶栏：关闭 + 手电筒
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 6, 12, 0),
              child: Row(
                children: [
                  _RoundButton(icon: Icons.close_rounded, tooltip: '关闭', onPressed: () => Navigator.of(context).pop()),
                  const Spacer(),
                  if (camera)
                    ValueListenableBuilder<MobileScannerState>(
                      valueListenable: controller,
                      builder: (context, state, _) {
                        final torch = state.torchState;
                        final on = torch == TorchState.on || torch == TorchState.auto;
                        return _RoundButton(
                          icon: switch (torch) {
                            TorchState.on => Icons.flashlight_on_rounded,
                            TorchState.auto => Icons.flash_auto_rounded,
                            _ => Icons.flashlight_off_rounded,
                          },
                          tooltip: '手电筒',
                          active: on,
                          onPressed: torch == TorchState.unavailable ? null : () => controller.toggleTorch(),
                        );
                      },
                    ),
                ],
              ),
            ),
          ),
          // 底部：从相册选图
          if (camera)
            SafeArea(
              child: Align(
                alignment: Alignment.bottomCenter,
                child: Padding(
                  padding: const EdgeInsets.only(bottom: 32),
                  child: FilledButton.tonalIcon(
                    style: FilledButton.styleFrom(minimumSize: const Size(0, 56), padding: const EdgeInsets.symmetric(horizontal: 24)),
                    onPressed: _pickFromGallery,
                    icon: const Icon(Icons.photo_library_outlined),
                    label: const Text('从相册选择'),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  String _errorText(MobileScannerException error) => switch (error.errorCode) {
    MobileScannerErrorCode.controllerUninitialized => '相机还没准备好',
    MobileScannerErrorCode.unsupported => '这台设备不支持扫码',
    MobileScannerErrorCode.genericError => '相机出错',
    _ => error.errorDetails?.message ?? '未知错误',
  };

  /// 权限被拒 / 相机出错时整屏的说明（M3：深色底上一个图标块 + 标题 + 说明）
  Widget _message({required IconData icon, required String title, required String body}) => ColoredBox(
    color: Colors.black,
    child: Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            M3IconTile(
              icon: icon,
              size: 72,
              shape: M3TileShape.leafA,
              bg: context.cs.errorContainer,
              fg: context.cs.onErrorContainer,
            ),
            const SizedBox(height: 24),
            Text(title, style: const TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.w800)),
            const SizedBox(height: 10),
            Text(body, textAlign: TextAlign.center, style: const TextStyle(color: Colors.white70, fontSize: 14, height: 1.5)),
          ],
        ),
      ),
    ),
  );
}

/// 相机上面的圆钮：半透明黑底白图标，[active] = 主色容器（手电筒开着）。
class _RoundButton extends StatelessWidget {
  const _RoundButton({required this.icon, required this.tooltip, required this.onPressed, this.active = false});
  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;
  final bool active;

  @override
  Widget build(BuildContext context) {
    final cs = context.cs;
    return Tooltip(
      message: tooltip,
      child: Material(
        color: active ? cs.primaryContainer : Colors.black.withValues(alpha: 0.45),
        shape: const CircleBorder(),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onPressed,
          child: SizedBox.square(
            dimension: 48,
            child: Icon(icon, color: active ? cs.onPrimaryContainer : Colors.white.withValues(alpha: onPressed == null ? 0.4 : 1)),
          ),
        ),
      ),
    );
  }
}

/// 扫描框：框外压暗，框是圆角 28 的主色描边。
class _ScanOverlay extends CustomPainter {
  const _ScanOverlay({required this.scanWindow, required this.color});

  final Rect scanWindow;
  final Color color;

  static const radius = Radius.circular(MeowShape.xl);

  @override
  void paint(Canvas canvas, Size size) {
    final frame = RRect.fromRectAndRadius(scanWindow, radius);
    canvas.drawPath(
      Path.combine(PathOperation.difference, Path()..addRect(Offset.zero & size), Path()..addRRect(frame)),
      Paint()..color = Colors.black.withValues(alpha: 0.55),
    );
    canvas.drawRRect(
      frame,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 4,
    );
  }

  @override
  bool shouldRepaint(_ScanOverlay old) => old.scanWindow != scanWindow || old.color != color;
}
