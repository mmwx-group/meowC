import 'dart:async';
import 'dart:math';

import 'package:bett_box/common/common.dart';
import 'package:bett_box/plugins/app.dart';
import 'package:bett_box/state.dart';
import 'package:bett_box/widgets/activate_box.dart';
import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

class ScanPage extends StatefulWidget {
  const ScanPage({super.key});

  @override
  State<ScanPage> createState() => _ScanPageState();
}

class _ScanPageState extends State<ScanPage> with WidgetsBindingObserver {
  MobileScannerController controller = MobileScannerController(
    detectionSpeed: DetectionSpeed.noDuplicates,
    formats: const [BarcodeFormat.qrCode],
    autoStart: false, // Disable autoStart to manually control initialization
  );

  StreamSubscription<Object?>? _subscription;
  bool _permissionDenied = false;
  bool _permissionChecking = false;
  bool _permissionRequested = false;   // 只主动申请一次，拒绝后回到设置引导

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _subscription = controller.barcodes.listen(_handleBarcode);
    // Check permission and start camera
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _checkCameraPermission();
    });
  }

  void _handleBarcode(BarcodeCapture barcodeCapture) {
    final barcode = barcodeCapture.barcodes.first;
    // MeowX：登录码是 miaomiaowu:// 自定义 scheme，ML Kit 会判成 text 而不是 url，原样交给调用方解析
    final raw = barcode.rawValue;
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
        // Recheck permission when returning from settings
        _checkCameraPermission();
        return;
      case AppLifecycleState.inactive:
        unawaited(_subscription?.cancel());
        _subscription = null;
        if (controller.value.isRunning) {
          unawaited(controller.stop());
        }
        return;
    }
  }

  Future<void> _checkCameraPermission() async {
    if (_permissionChecking) return; // Prevent concurrent checks
    
    setState(() {
      _permissionChecking = true;
    });
    
    var granted = await app.hasCameraPermission();
    if (!granted && !_permissionRequested) {
      // MeowX：原逻辑只查不申请，没授权过的机器会直接落到「权限被拒」页。
      // mobile_scanner 的 start() 会弹系统权限请求，弹完再查一次。
      _permissionRequested = true;
      try {
        await controller.start();
      } catch (e) {
        commonPrint.log('Camera permission request: $e');
      }
      granted = await app.hasCameraPermission();
      // MeowX：这次 start 只为弹授权框，那时扫码组件还没挂上（页面在「检查权限」的黑底）。相机先于组件跑起来，
      // 扫描框没对上，第一次打开对准了也识别不到、退出重进才好。先停掉，下面等组件挂上后再正式启动。
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
      if (controller.value.isRunning) {
        await controller.stop();
      }
    } else {
      // Start camera only if not already running
      // MeowX：等扫码组件挂上（上面的 setState 那一帧画完）再启动，相机不先于组件跑起来
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted) return;
      if (!controller.value.isRunning) {
        try {
          await controller.start();
        } catch (e) {
          // Handle start error silently
          commonPrint.log('Camera start error: $e');
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    double sideLength = min(400, MediaQuery.of(context).size.width * 0.67);
    final scanWindow = Rect.fromCenter(
      center: MediaQuery.sizeOf(context).center(Offset.zero),
      width: sideLength,
      height: sideLength,
    );
    return Scaffold(
      body: Stack(
        children: [
          Center(
            child: _permissionChecking
                ? Container(color: Colors.black)
                : (_permissionDenied
                      ? _buildPermissionDeniedView(context)
                      : MobileScanner(
                          controller: controller,
                          scanWindow: scanWindow,
                          errorBuilder: (context, error) {
                            if (error.errorCode ==
                                MobileScannerErrorCode.permissionDenied) {
                              if (!_permissionDenied && mounted) {
                                WidgetsBinding.instance.addPostFrameCallback((
                                  _,
                                ) {
                                  if (!mounted) return;
                                  setState(() {
                                    _permissionDenied = true;
                                  });
                                });
                              }
                              unawaited(controller.stop());
                              return _buildPermissionDeniedView(context);
                            }
                            return _buildErrorView(context, error);
                          },
                        )),
          ),
          if (!_permissionDenied)
            CustomPaint(painter: ScannerOverlay(scanWindow: scanWindow)),
          AppBar(
            backgroundColor: Colors.transparent,
            automaticallyImplyLeading: false,
            leading: IconButton(
              style: const ButtonStyle(
                iconSize: WidgetStatePropertyAll(32),
                foregroundColor: WidgetStatePropertyAll(Colors.white),
              ),
              onPressed: () {
                Navigator.of(context).pop();
              },
              icon: const Icon(Icons.close),
            ),
            actions: [
              if (!_permissionDenied)
                ValueListenableBuilder<MobileScannerState>(
                  valueListenable: controller,
                  builder: (context, state, _) {
                    var icon = const Icon(Icons.flash_off);
                    var backgroundColor = Colors.black12;
                    switch (state.torchState) {
                      case TorchState.off:
                        icon = const Icon(Icons.flash_off);
                        backgroundColor = Colors.black12;
                      case TorchState.on:
                        icon = const Icon(Icons.flash_on);
                        backgroundColor = Colors.orange;
                      case TorchState.unavailable:
                        icon = const Icon(Icons.flash_off);
                        backgroundColor = Colors.transparent;
                      case TorchState.auto:
                        icon = const Icon(Icons.flash_auto);
                        backgroundColor = Colors.orange;
                    }
                    return Container(
                      margin: const EdgeInsets.symmetric(horizontal: 8),
                      child: ActivateBox(
                        active: state.torchState != TorchState.unavailable,
                        child: IconButton(
                          color: Colors.white,
                          icon: icon,
                          style: ButtonStyle(
                            foregroundColor: const WidgetStatePropertyAll(
                              Colors.white,
                            ),
                            backgroundColor: WidgetStatePropertyAll(
                              backgroundColor,
                            ),
                          ),
                          onPressed: () => controller.toggleTorch(),
                        ),
                      ),
                    );
                  },
                ),
            ],
          ),
          if (!_permissionDenied)
            Container(
              margin: const EdgeInsets.only(bottom: 32),
              alignment: Alignment.bottomCenter,
              child: IconButton(
                color: Colors.white,
                style: const ButtonStyle(
                  foregroundColor: WidgetStatePropertyAll(Colors.white),
                  backgroundColor: WidgetStatePropertyAll(Colors.grey),
                ),
                padding: const EdgeInsets.all(16),
                iconSize: 32.0,
                // MeowX：相册选图的结果也交回给打开扫码页的调用方（登录 / 导入各自解析）
                onPressed: () async {
                  try {
                    final raw = await picker.pickerQRCodeRaw();
                    if (raw != null && context.mounted) {
                      Navigator.pop<String>(context, raw);
                    }
                  } catch (e) {
                    globalState.showNotifier(e.toString());
                  }
                },
                icon: const Icon(Icons.photo_camera_back),
              ),
            ),
        ],
      ),
    );
  }

  /// 构建权限被拒绝的视图
  Widget _buildPermissionDeniedView(BuildContext context) {
    return Container(
      color: Colors.black,
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(
                Icons.camera_alt_outlined,
                size: 80,
                color: Colors.white54,
              ),
              const SizedBox(height: 24),
              Text(
                appLocalizations.cameraPermissionDenied,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 12),
              Text(
                appLocalizations.cameraPermissionDesc,
                style: const TextStyle(color: Colors.white70, fontSize: 14),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Build error view
  Widget _buildErrorView(BuildContext context, MobileScannerException error) {
    String errorMessage = 'Camera init failed';
    switch (error.errorCode) {
      case MobileScannerErrorCode.controllerUninitialized:
        errorMessage = 'Camera uninitialized';
        break;
      case MobileScannerErrorCode.genericError:
        errorMessage = 'Camera error';
        break;
      case MobileScannerErrorCode.unsupported:
        errorMessage = 'Scan not supported';
        break;
      default:
        errorMessage = error.errorDetails?.message ?? 'Unknown error';
    }

    return Container(
      color: Colors.black,
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.error_outline, size: 80, color: Colors.red),
              const SizedBox(height: 24),
              Text(
                errorMessage,
                style: const TextStyle(color: Colors.white, fontSize: 16),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_subscription?.cancel());
    _subscription = null;
    unawaited(controller.dispose());
    super.dispose();
  }
}

class ScannerOverlay extends CustomPainter {
  const ScannerOverlay({required this.scanWindow, this.borderRadius = 12.0});

  final Rect scanWindow;
  final double borderRadius;

  @override
  void paint(Canvas canvas, Size size) {
    final backgroundPath = Path()..addRect(Rect.largest);

    final cutoutPath = Path()
      ..addRRect(
        RRect.fromRectAndCorners(
          scanWindow,
          topLeft: Radius.circular(borderRadius),
          topRight: Radius.circular(borderRadius),
          bottomLeft: Radius.circular(borderRadius),
          bottomRight: Radius.circular(borderRadius),
        ),
      );

    final backgroundPaint = Paint()
      ..color = Colors.black.opacity50
      ..style = PaintingStyle.fill
      ..blendMode = BlendMode.dstOut;

    final backgroundWithCutout = Path.combine(
      PathOperation.difference,
      backgroundPath,
      cutoutPath,
    );

    final borderPaint = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.stroke
      ..strokeWidth = 4.0;

    final borderRect = RRect.fromRectAndCorners(
      scanWindow,
      topLeft: Radius.circular(borderRadius),
      topRight: Radius.circular(borderRadius),
      bottomLeft: Radius.circular(borderRadius),
      bottomRight: Radius.circular(borderRadius),
    );

    canvas.drawPath(backgroundWithCutout, backgroundPaint);
    canvas.drawRRect(borderRect, borderPaint);
  }

  @override
  bool shouldRepaint(ScannerOverlay oldDelegate) {
    return scanWindow != oldDelegate.scanWindow ||
        borderRadius != oldDelegate.borderRadius;
  }
}
