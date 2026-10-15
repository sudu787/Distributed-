import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:syncsphere_core/syncsphere_core.dart';

/// Scans a room's invite QR code; pops with the parsed [JoinLink].
class ScanScreen extends StatefulWidget {
  const ScanScreen({super.key});

  @override
  State<ScanScreen> createState() => _ScanScreenState();
}

class _ScanScreenState extends State<ScanScreen> {
  final _controller = MobileScannerController(formats: const [BarcodeFormat.qrCode]);
  bool _done = false;
  String? _hint;

  void _onDetect(BarcodeCapture capture) {
    if (_done) return;
    for (final b in capture.barcodes) {
      final raw = b.rawValue;
      if (raw == null) continue;
      final link = JoinLink.tryParse(raw);
      if (link != null) {
        _done = true;
        Navigator.of(context).pop(link);
        return;
      }
      if (mounted) setState(() => _hint = 'That QR code is not a SyncSphere invite.');
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Scan invite')),
      body: Stack(fit: StackFit.expand, children: [
        MobileScanner(
          controller: _controller,
          onDetect: _onDetect,
          errorBuilder: (c, e) => Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Text(
                e.errorCode == MobileScannerErrorCode.permissionDenied
                    ? 'Camera permission is needed to scan. You can also paste the invite link instead.'
                    : 'Camera unavailable: ${e.errorCode.name}',
                textAlign: TextAlign.center,
                style: t.bodyLarge?.copyWith(color: Colors.white),
              ),
            ),
          ),
        ),
        Align(
          alignment: Alignment.bottomCenter,
          child: Container(
            width: double.infinity,
            color: Colors.black54,
            padding: const EdgeInsets.all(16),
            child: Text(
              _hint ?? 'Point the camera at the QR code on the host\'s phone (QR icon at the top of their party).',
              textAlign: TextAlign.center,
              style: t.bodyMedium?.copyWith(color: Colors.white),
            ),
          ),
        ),
      ]),
    );
  }
}
