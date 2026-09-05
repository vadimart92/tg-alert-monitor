/// Scans another phone's QR code and applies what it carries.
///
/// Three steps, in one screen: the camera, a confirmation of what is about to
/// happen, and the progress of it happening. Joining channels on someone's
/// Telegram account is not something to do off a camera frame without asking.
library;

import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../../core/model/setup_payload.dart';
import '../../l10n/app_localizations.dart';
import '../service_bridge.dart';
import 'login_screen.dart';

enum _Step { scanning, confirming, applying, finished }

class SetupScanScreen extends StatefulWidget {
  const SetupScanScreen({super.key, required this.bridge});

  final ServiceBridge bridge;

  @override
  State<SetupScanScreen> createState() => _SetupScanScreenState();
}

class _SetupScanScreenState extends State<SetupScanScreen> {
  final MobileScannerController _camera = MobileScannerController(
    formats: const [BarcodeFormat.qrCode],
    detectionSpeed: DetectionSpeed.noDuplicates,
  );

  _Step _step = _Step.scanning;
  SetupPayload? _payload;
  String? _scanError;

  L get l => L.of(context);

  @override
  void initState() {
    super.initState();
    widget.bridge.clearSetupResult();
  }

  @override
  void dispose() {
    _camera.dispose();
    super.dispose();
  }

  void _onDetect(BarcodeCapture capture) {
    if (_step != _Step.scanning) return;
    for (final barcode in capture.barcodes) {
      final raw = barcode.rawValue;
      if (raw == null || raw.isEmpty) continue;
      try {
        final payload = SetupPayload.decode(raw);
        setState(() {
          _payload = payload;
          _scanError = null;
          _step = _Step.confirming;
        });
        _camera.stop();
        return;
      } on SetupPayloadError {
        // Any other QR code in the world lands here. Say so, and keep looking.
        setState(() => _scanError = l.setupBadCode);
      }
    }
  }

  void _apply() {
    final payload = _payload;
    if (payload == null) return;
    setState(() => _step = _Step.applying);
    widget.bridge.applySetup(payload);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(l.setupScanTitle)),
      body: ListenableBuilder(
        listenable: widget.bridge,
        builder: (context, _) {
          final bridge = widget.bridge;
          // The service answers with setupDone whether it worked or not.
          if (_step == _Step.applying && bridge.setupResult != null) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted) setState(() => _step = _Step.finished);
            });
          }
          return switch (_step) {
            _Step.scanning => _scanner(),
            _Step.confirming => _confirmation(bridge),
            _Step.applying => _progress(bridge),
            _Step.finished => _result(bridge),
          };
        },
      ),
    );
  }

  Widget _scanner() => Stack(
    fit: StackFit.expand,
    children: [
      MobileScanner(
        controller: _camera,
        onDetect: _onDetect,
        errorBuilder: (context, error) => Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Text(
              // The plugin reports a denied permission the same way as a
              // broken camera; the actionable reading is the permission.
              error.errorCode == MobileScannerErrorCode.permissionDenied
                  ? l.setupCameraDenied
                  : '${error.errorCode}',
              textAlign: TextAlign.center,
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
            _scanError ?? l.setupScanHint,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: _scanError == null ? Colors.white : Colors.orangeAccent,
            ),
          ),
        ),
      ),
    ],
  );

  Widget _confirmation(ServiceBridge bridge) {
    final payload = _payload!;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text(
          l.setupPreviewTitle,
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const SizedBox(height: 8),
        Text(l.setupPreviewBody(payload.folderName)),
        const SizedBox(height: 16),
        Text(
          l.setupShareSummary(payload.channels.length, payload.keywords.length),
          style: TextStyle(color: Theme.of(context).hintColor),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 6,
          runSpacing: 4,
          children: [
            for (final channel in payload.channels)
              Chip(
                label: Text(
                  channel.title.isEmpty
                      ? '@${channel.username}'
                      : channel.title,
                ),
              ),
          ],
        ),
        const Divider(height: 28),
        Wrap(
          spacing: 6,
          runSpacing: 4,
          children: [
            for (final keyword in payload.keywords) Chip(label: Text(keyword)),
          ],
        ),
        const SizedBox(height: 24),
        if (!bridge.isReady) ...[
          Card(
            color: Theme.of(context).colorScheme.secondaryContainer,
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Text(l.setupSignInFirst),
            ),
          ),
          const SizedBox(height: 8),
          OutlinedButton(
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute<void>(
                builder: (_) => LoginScreen(bridge: bridge),
              ),
            ),
            child: Text(l.telegramSignIn),
          ),
          const SizedBox(height: 8),
        ],
        FilledButton.icon(
          onPressed: bridge.isReady ? _apply : null,
          icon: const Icon(Icons.download_done),
          label: Text(l.setupApply),
        ),
      ],
    );
  }

  Widget _progress(ServiceBridge bridge) {
    final progress = bridge.setupProgress;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(),
            const SizedBox(height: 16),
            if (progress != null)
              Text(
                l.setupApplying(
                  progress.title,
                  progress.done + 1,
                  progress.total,
                ),
                textAlign: TextAlign.center,
              ),
          ],
        ),
      ),
    );
  }

  Widget _result(ServiceBridge bridge) {
    final result = bridge.setupResult!;
    final error = result.error;

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Icon(
          error == null ? Icons.check_circle : Icons.error,
          size: 48,
          color: error == null
              ? Colors.green
              : Theme.of(context).colorScheme.error,
        ),
        const SizedBox(height: 12),
        Text(
          error ?? l.setupDoneTitle,
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.titleMedium,
        ),
        if (error == null) ...[
          const SizedBox(height: 8),
          Text(
            l.setupDoneBody(result.channels, result.joined),
            textAlign: TextAlign.center,
          ),
        ],
        if (result.failed.isNotEmpty) ...[
          const SizedBox(height: 16),
          Card(
            color: Theme.of(context).colorScheme.errorContainer,
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Text(l.setupFailed(result.failed.join(', '))),
            ),
          ),
        ],
        const SizedBox(height: 24),
        FilledButton(
          onPressed: () => Navigator.pop(context),
          child: Text(l.done),
        ),
      ],
    );
  }
}
