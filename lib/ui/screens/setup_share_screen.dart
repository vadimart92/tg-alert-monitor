/// Shows this phone's configuration as a QR code for a second phone to scan.
library;

import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../core/ipc/protocol.dart';
import '../../core/model/setup_payload.dart';
import '../../l10n/app_localizations.dart';
import '../service_bridge.dart';

class SetupShareScreen extends StatefulWidget {
  const SetupShareScreen({super.key, required this.bridge});

  final ServiceBridge bridge;

  @override
  State<SetupShareScreen> createState() => _SetupShareScreenState();
}

class _SetupShareScreenState extends State<SetupShareScreen> {
  L get l => L.of(context);

  @override
  void initState() {
    super.initState();
    // The usernames are not in the cached config: only the service can ask
    // TDLib for them, so the payload is built there.
    widget.bridge.requestSetupPayload();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(l.setupShareTitle)),
      body: ListenableBuilder(
        listenable: widget.bridge,
        builder: (context, _) => _body(widget.bridge),
      ),
    );
  }

  Widget _body(ServiceBridge bridge) {
    final error = bridge.lastError;
    if (error != null && error.scope == ErrorScope.setup) {
      return _message(error.message, isError: true);
    }

    final payload = bridge.setupPayload;
    if (payload == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (payload.isEmpty) return _message(l.setupNothingToShare);

    final encoded = payload.encode();
    if (encoded.length > SetupPayload.maxEncodedLength) {
      return _message(l.setupTooBig, isError: true);
    }

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text(l.setupShareIntro(payload.folderName)),
        const SizedBox(height: 16),
        Center(
          // A white quiet zone regardless of the app theme: a QR inverted for
          // dark mode is unreadable to many scanners.
          child: Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(12),
            ),
            child: QrImageView(
              data: encoded,
              version: QrVersions.auto,
              size: 260,
              backgroundColor: Colors.white,
              // Fail loudly rather than render a code that cannot be read.
              errorStateBuilder: (context, _) => SizedBox(
                width: 260,
                height: 260,
                child: Center(
                  child: Text(
                    l.setupTooBig,
                    style: const TextStyle(color: Colors.black),
                    textAlign: TextAlign.center,
                  ),
                ),
              ),
            ),
          ),
        ),
        const SizedBox(height: 12),
        Center(
          child: Text(
            l.setupShareSummary(
              payload.channels.length,
              payload.keywords.length,
            ),
            style: TextStyle(color: Theme.of(context).hintColor),
          ),
        ),
        if (bridge.setupSkipped.isNotEmpty) ...[
          const SizedBox(height: 16),
          Card(
            color: Theme.of(context).colorScheme.secondaryContainer,
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Text(
                l.setupSkipped(bridge.setupSkipped.join(', ')),
                style: const TextStyle(fontSize: 12),
              ),
            ),
          ),
        ],
      ],
    );
  }

  Widget _message(String text, {bool isError = false}) => Center(
    child: Padding(
      padding: const EdgeInsets.all(32),
      child: Text(
        text,
        textAlign: TextAlign.center,
        style: isError
            ? TextStyle(color: Theme.of(context).colorScheme.error)
            : null,
      ),
    ),
  );
}
