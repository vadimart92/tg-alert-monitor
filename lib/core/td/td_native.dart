/// FFI bindings for the modern `td_json_client.h` interface of libtdjson.
///
/// Memory rules (from the TDLib docs):
///  * strings returned by `td_receive` / `td_execute` are owned by TDLib and
///    are valid only until the next call on the same thread — copy, never free;
///  * strings passed into `td_send` / `td_execute` are ours — allocate with
///    [String.toNativeUtf8] and free right after the call returns.
library;

import 'dart:ffi' as ffi;

import 'package:ffi/ffi.dart';

typedef _CreateClientIdNative = ffi.Int32 Function();
typedef _CreateClientIdDart = int Function();

typedef _SendNative = ffi.Void Function(ffi.Int32, ffi.Pointer<Utf8>);
typedef _SendDart = void Function(int, ffi.Pointer<Utf8>);

typedef _ReceiveNative = ffi.Pointer<Utf8> Function(ffi.Double);
typedef _ReceiveDart = ffi.Pointer<Utf8> Function(double);

typedef _ExecuteNative = ffi.Pointer<Utf8> Function(ffi.Pointer<Utf8>);
typedef _ExecuteDart = ffi.Pointer<Utf8> Function(ffi.Pointer<Utf8>);

/// Thin wrapper over the four exported symbols of libtdjson.
///
/// `td_receive` is global across clients in a process, so exactly one isolate
/// may call [receive] — see `td_transport.dart`.
class TdNative {
  TdNative._(this._library)
    : _createClientId = _library
          .lookupFunction<_CreateClientIdNative, _CreateClientIdDart>(
            'td_create_client_id',
          ),
      _send = _library.lookupFunction<_SendNative, _SendDart>('td_send'),
      _receive = _library.lookupFunction<_ReceiveNative, _ReceiveDart>(
        'td_receive',
      ),
      _execute = _library.lookupFunction<_ExecuteNative, _ExecuteDart>(
        'td_execute',
      );

  static const String libraryName = 'libtdjson.so';

  static TdNative? _instance;

  /// Opens (once per isolate) and binds libtdjson.
  ///
  /// Throws [ArgumentError] when the `.so` is missing from the APK, which is
  /// the single most useful failure to surface loudly.
  factory TdNative.instance() =>
      _instance ??= TdNative._(ffi.DynamicLibrary.open(libraryName));

  /// Test seam: bind against an already-open library.
  factory TdNative.fromLibrary(ffi.DynamicLibrary library) =>
      TdNative._(library);

  // ignore: unused_field
  final ffi.DynamicLibrary _library;
  final _CreateClientIdDart _createClientId;
  final _SendDart _send;
  final _ReceiveDart _receive;
  final _ExecuteDart _execute;

  /// Allocates a new TDLib client id. The client is created lazily by TDLib on
  /// the first [send].
  int createClientId() => _createClientId();

  /// Queues a request. Non-blocking, thread-safe.
  void send(int clientId, String request) {
    final native = request.toNativeUtf8();
    try {
      _send(clientId, native);
    } finally {
      malloc.free(native);
    }
  }

  /// Blocks up to [timeout] seconds waiting for the next incoming message of
  /// *any* client in this process. Returns `null` on timeout.
  String? receive(double timeout) {
    final result = _receive(timeout);
    if (result == ffi.nullptr) return null;
    // Owned by TDLib; toDartString copies, so nothing to free.
    return result.toDartString();
  }

  /// Synchronous execution. Only valid for the handful of requests TDLib marks
  /// as synchronous (`setLogVerbosityLevel`, `setLogStream`, `getOption` for
  /// `version`/`commit_hash`, ...).
  String? execute(String request) {
    final native = request.toNativeUtf8();
    try {
      final result = _execute(native);
      if (result == ffi.nullptr) return null;
      return result.toDartString();
    } finally {
      malloc.free(native);
    }
  }
}
