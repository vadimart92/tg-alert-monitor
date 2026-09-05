/// Transport layer under [TdClient].
///
/// `td_receive` blocks, so it runs in its own isolate and streams raw JSON
/// lines back over a [SendPort]. `td_send` is thread-safe and is called
/// straight from the owning isolate.
library;

import 'dart:async';
import 'dart:isolate';

import 'td_native.dart';

/// Everything [TdClient] needs from the outside world. Tests substitute a fake.
abstract class TdTransport {
  /// Raw JSON lines coming out of TDLib.
  Stream<String> get incoming;

  /// Queues a raw JSON request.
  void send(String json);

  /// Releases the transport. Safe to call twice.
  Future<void> close();
}

/// Arguments handed to the receive isolate.
class _ReceiveIsolateArgs {
  const _ReceiveIsolateArgs(this.toMain, this.timeoutSeconds);
  final SendPort toMain;
  final double timeoutSeconds;
}

/// Entry point of the receive isolate.
///
/// Loops on the blocking `td_receive`, forwarding every line to the main
/// isolate. Yields to its own event loop after each call so that a `stop`
/// control message can land.
@pragma('vm:entry-point')
Future<void> _receiveIsolateMain(_ReceiveIsolateArgs args) async {
  final control = ReceivePort();
  args.toMain.send(control.sendPort);

  var running = true;
  control.listen((message) {
    if (message == 'stop') running = false;
  });

  final TdNative native;
  try {
    native = TdNative.instance();
  } catch (error) {
    args.toMain.send({'#error': 'failed to open libtdjson: $error'});
    control.close();
    return;
  }

  while (running) {
    String? line;
    try {
      line = native.receive(args.timeoutSeconds);
    } catch (error) {
      args.toMain.send({'#error': 'td_receive failed: $error'});
      break;
    }
    if (line != null) args.toMain.send(line);
    // Let the control port deliver `stop` between blocking calls.
    await Future<void>.delayed(Duration.zero);
  }
  control.close();
}

/// Production [TdTransport]: one client id, one receive isolate.
class IsolateTdTransport implements TdTransport {
  IsolateTdTransport._(
    this._native,
    this.clientId,
    this._isolate,
    this._fromIsolate,
    this._toIsolate,
    this._controller,
    this._subscription,
  );

  /// Spawns the receive isolate and allocates a TDLib client id.
  ///
  /// [onFatal] fires when the receive loop dies; the engine responds by
  /// rebuilding the client from scratch.
  static Future<IsolateTdTransport> start({
    double receiveTimeoutSeconds = 1.0,
    void Function(String message)? onFatal,
  }) async {
    final native = TdNative.instance();
    final clientId = native.createClientId();

    final fromIsolate = ReceivePort();
    final controller = StreamController<String>.broadcast();
    final handshake = Completer<SendPort>();

    final subscription = fromIsolate.listen((message) {
      if (message is SendPort) {
        if (!handshake.isCompleted) handshake.complete(message);
        return;
      }
      if (message is String) {
        if (!controller.isClosed) controller.add(message);
        return;
      }
      if (message is Map && message['#error'] != null) {
        onFatal?.call(message['#error'].toString());
      }
    });

    final isolate = await Isolate.spawn(
      _receiveIsolateMain,
      _ReceiveIsolateArgs(fromIsolate.sendPort, receiveTimeoutSeconds),
      debugName: 'td_receive',
      onError: fromIsolate.sendPort,
      onExit: fromIsolate.sendPort,
    );

    final toIsolate = await handshake.future.timeout(
      const Duration(seconds: 10),
      onTimeout: () => throw StateError('receive isolate did not start'),
    );

    return IsolateTdTransport._(
      native,
      clientId,
      isolate,
      fromIsolate,
      toIsolate,
      controller,
      subscription,
    );
  }

  final TdNative _native;
  final int clientId;
  final Isolate _isolate;
  final ReceivePort _fromIsolate;
  final SendPort _toIsolate;
  final StreamController<String> _controller;
  final StreamSubscription<dynamic> _subscription;

  bool _closed = false;

  @override
  Stream<String> get incoming => _controller.stream;

  @override
  void send(String json) {
    if (_closed) return;
    _native.send(clientId, json);
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _toIsolate.send('stop');
    // The loop can be parked inside a blocking td_receive; give it one timeout
    // window to notice, then take it down hard.
    await Future<void>.delayed(const Duration(milliseconds: 1500));
    _isolate.kill(priority: Isolate.immediate);
    await _subscription.cancel();
    _fromIsolate.close();
    await _controller.close();
  }
}
