import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

/// Opens whatever reads a device's setup QR code and returns its text, or null
/// when the person backed out. A seam so widget tests can hand in a code.
typedef SetupCodeScan = Future<String?> Function(BuildContext context);

/// The camera, pointed at the QR code a device shows while its setup window is
/// open. Returns the first code that looks like a setup payload; anything else
/// in view (a poster, a Wi-Fi sticker) is ignored rather than reported.
Future<String?> scanSetupCodeWithCamera(BuildContext context) =>
    Navigator.of(context).push<String>(
      MaterialPageRoute(builder: (_) => const SetupCodeScannerPage()),
    );

class SetupCodeScannerPage extends StatefulWidget {
  const SetupCodeScannerPage({super.key});

  @override
  State<SetupCodeScannerPage> createState() => _SetupCodeScannerPageState();
}

class _SetupCodeScannerPageState extends State<SetupCodeScannerPage> {
  final _controller = MobileScannerController(
    formats: const [BarcodeFormat.qrCode],
    detectionSpeed: DetectionSpeed.noDuplicates,
  );
  bool _done = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _onDetect(BarcodeCapture capture) {
    if (_done) return;
    for (final barcode in capture.barcodes) {
      final text = barcode.rawValue;
      // A setup payload is a JSON object; nothing else is ours to read.
      if (text != null && text.trimLeft().startsWith('{')) {
        _done = true;
        Navigator.of(context).pop(text);
        return;
      }
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('扫描设备屏幕上的二维码')),
        body: Column(
          children: [
            Expanded(
              child: MobileScanner(
                controller: _controller,
                onDetect: _onDetect,
                errorBuilder: (context, error) => Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(
                      error.errorCode == MobileScannerErrorCode.permissionDenied
                          ? '没有相机权限。可以返回后输入设备屏幕上的 8 位数字。'
                          : '相机打不开。可以返回后输入设备屏幕上的 8 位数字。',
                      textAlign: TextAlign.center,
                    ),
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                '把二维码放进画面里。二维码只在设备的设置模式里显示，每次打开都会换新。',
                style: Theme.of(context).textTheme.bodySmall,
                textAlign: TextAlign.center,
              ),
            ),
          ],
        ),
      );
}
