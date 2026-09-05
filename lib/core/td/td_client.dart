/// Request/response correlation over a [TdTransport].
library;

import 'dart:async';
import 'dart:convert';

import 'td_transport.dart';

/// A TDLib `error` object returned for one of our requests.
class TdError implements Exception {
  TdError(this.code, this.message, {this.request});

  final int code;
  final String message;
  final String? request;

  @override
  String toString() =>
      'TdError($code, $message${request == null ? '' : ', for $request'})';
}

/// No response arrived within the deadline.
class TdTimeout implements Exception {
  TdTimeout(this.request);

  final String request;

  @override
  String toString() => 'TdTimeout(for $request)';
}

/// Wraps a [TdTransport] with `@extra` correlation and an updates stream.
class TdClient {
  TdClient(
    this._transport, {
    this.defaultTimeout = const Duration(seconds: 30),
  }) {
    _subscription = _transport.incoming.listen(
      _onLine,
      onError: (Object error, StackTrace stack) {
        if (!_updates.isClosed) _updates.addError(error, stack);
      },
    );
  }

  final TdTransport _transport;
  final Duration defaultTimeout;

  late final StreamSubscription<String> _subscription;
  final Map<String, _Pending> _pending = <String, _Pending>{};
  final StreamController<Map<String, dynamic>> _updates =
      StreamController<Map<String, dynamic>>.broadcast();

  int _extraCounter = 0;
  bool _closed = false;

  /// Every incoming message that is not a reply to one of our requests.
  Stream<Map<String, dynamic>> get updates => _updates.stream;

  void _onLine(String line) {
    final Map<String, dynamic> message;
    try {
      final decoded = jsonDecode(line);
      if (decoded is! Map) return;
      message = Map<String, dynamic>.from(decoded);
    } catch (_) {
      // A line we cannot parse is not worth killing the connection over.
      return;
    }

    final extra = message['@extra'];
    if (extra is String) {
      final pending = _pending.remove(extra);
      if (pending == null) {
        // Late reply to a request that already timed out — drop it.
        return;
      }
      pending.timer.cancel();
      message.remove('@extra');
      if (message['@type'] == 'error') {
        pending.completer.completeError(
          TdError(
            (message['code'] as num?)?.toInt() ?? 0,
            message['message'] as String? ?? 'unknown error',
            request: pending.requestType,
          ),
        );
      } else {
        pending.completer.complete(message);
      }
      return;
    }

    if (!_updates.isClosed) _updates.add(message);
  }

  /// Sends [request] and completes with its reply.
  ///
  /// Throws [TdError] when TDLib answers with an error object, [TdTimeout] when
  /// nothing arrives in time.
  Future<Map<String, dynamic>> send(
    Map<String, dynamic> request, {
    Duration? timeout,
  }) {
    if (_closed) {
      return Future<Map<String, dynamic>>.error(
        StateError('TdClient is closed'),
      );
    }

    final extra = (++_extraCounter).toString();
    final requestType = request['@type']?.toString() ?? 'unknown';
    final completer = Completer<Map<String, dynamic>>();
    final effectiveTimeout = timeout ?? defaultTimeout;

    final timer = Timer(effectiveTimeout, () {
      final pending = _pending.remove(extra);
      if (pending == null) return;
      pending.completer.completeError(TdTimeout(requestType));
    });

    _pending[extra] = _Pending(completer, timer, requestType);
    _transport.send(jsonEncode({...request, '@extra': extra}));
    return completer.future;
  }

  /// Fire-and-forget: no `@extra`, so the reply (if any) surfaces as an update.
  void sendAsync(Map<String, dynamic> request) {
    if (_closed) return;
    _transport.send(jsonEncode(request));
  }

  /// Cancels pending requests and releases the transport.
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    for (final pending in _pending.values) {
      pending.timer.cancel();
      if (!pending.completer.isCompleted) {
        pending.completer.completeError(StateError('TdClient closed'));
      }
    }
    _pending.clear();
    await _subscription.cancel();
    await _updates.close();
    await _transport.close();
  }
}

class _Pending {
  _Pending(this.completer, this.timer, this.requestType);
  final Completer<Map<String, dynamic>> completer;
  final Timer timer;
  final String requestType;
}
