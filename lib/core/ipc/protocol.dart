/// The JSON dialect spoken between the UI isolate and the service isolate.
///
/// Everything crossing `sendDataToTask` / `sendDataToMain` is a JSON string, so
/// both ends encode and decode through this file and nowhere else.
library;

import 'dart:convert';

/// Malformed or unknown traffic. Callers catch this and log; the isolate must
/// never die because the other side sent nonsense.
class ProtocolError implements Exception {
  ProtocolError(this.message);
  final String message;

  @override
  String toString() => 'ProtocolError: $message';
}

/// Command names, UI -> service.
abstract final class Cmd {
  static const String uiAttached = 'ui.attached';
  static const String uiDetached = 'ui.detached';
  static const String authPhone = 'auth.phone';
  static const String authCode = 'auth.code';
  static const String authResend = 'auth.resend';
  static const String authPassword = 'auth.password';
  static const String authLogout = 'auth.logout';
  static const String foldersList = 'folders.list';
  static const String foldersChats = 'folders.chats';
  static const String monitorStart = 'monitor.start';
  static const String monitorStop = 'monitor.stop';

  /// Applies configuration changes (keywords, bot token, target chat, maxAge)
  /// to a running engine without restarting monitoring.
  static const String monitorConfig = 'monitor.config';
  static const String botCheck = 'bot.check';
  static const String botTest = 'bot.test';

  /// Lists channels the bot was added to, for the target-chat picker.
  static const String botTargets = 'bot.targets';
  static const String logGet = 'log.get';

  /// Builds a shareable [SetupPayload] out of the current configuration.
  static const String setupExport = 'setup.export';

  /// Applies a scanned [SetupPayload]: joins channels, builds the folder.
  static const String setupApply = 'setup.apply';

  /// Fires a local notification with the siren, to prove it works.
  static const String diagAlert = 'diag.alert';

  /// Delivers the newest message of a monitored chat down the real path.
  static const String diagForward = 'diag.forward';

  /// Reports what the engine currently considers monitorable.
  static const String diagState = 'diag.state';

  static const Set<String> all = {
    uiAttached,
    uiDetached,
    authPhone,
    authCode,
    authResend,
    authPassword,
    authLogout,
    foldersList,
    foldersChats,
    monitorStart,
    monitorStop,
    monitorConfig,
    botCheck,
    botTest,
    botTargets,
    logGet,
    setupExport,
    setupApply,
    diagAlert,
    diagForward,
    diagState,
  };
}

/// Event names, service -> UI.
abstract final class Ev {
  static const String state = 'state';
  static const String folders = 'folders';
  static const String folderChats = 'folderChats';
  static const String match = 'match';
  static const String matchStatus = 'matchStatus';
  static const String botInfo = 'botInfo';
  static const String botTargets = 'botTargets';
  static const String error = 'error';
  static const String log = 'log';
  static const String logLines = 'logLines';

  /// Answer to [Cmd.setupExport].
  static const String setupPayload = 'setupPayload';

  /// One channel handled, while [Cmd.setupApply] runs.
  static const String setupProgress = 'setupProgress';

  /// [Cmd.setupApply] finished, successfully or not.
  static const String setupDone = 'setupDone';

  /// Answer to [Cmd.diagState].
  static const String diagState = 'diagState';

  /// Outcome of [Cmd.diagAlert] or [Cmd.diagForward].
  static const String diagResult = 'diagResult';

  static const Set<String> all = {
    state,
    folders,
    folderChats,
    match,
    matchStatus,
    botInfo,
    botTargets,
    error,
    log,
    logLines,
    setupPayload,
    setupProgress,
    setupDone,
    diagState,
    diagResult,
  };
}

/// Scopes carried by an [Ev.error].
abstract final class ErrorScope {
  static const String auth = 'auth';
  static const String bot = 'bot';
  static const String td = 'td';
  static const String folder = 'folder';
  static const String service = 'service';
  static const String setup = 'setup';
}

/// A UI -> service message.
class Command {
  Command(this.cmd, [Map<String, dynamic>? args])
    : args = args ?? const <String, dynamic>{};

  final String cmd;
  final Map<String, dynamic> args;

  T? arg<T>(String key) {
    final value = args[key];
    return value is T ? value : null;
  }

  String encode() => jsonEncode({'cmd': cmd, ...args});

  /// Parses a command string.
  ///
  /// Throws [ProtocolError] for anything that is not a known command.
  static Command decode(Object? raw) {
    final map = _decodeMap(raw);
    final cmd = map.remove('cmd');
    if (cmd is! String) throw ProtocolError('missing "cmd" field');
    if (!Cmd.all.contains(cmd)) throw ProtocolError('unknown command "$cmd"');
    return Command(cmd, map);
  }

  @override
  String toString() => 'Command($cmd, ${args.keys.toList()})';
}

/// A service -> UI message.
class Event {
  Event(this.ev, [Map<String, dynamic>? data])
    : data = data ?? const <String, dynamic>{};

  final String ev;
  final Map<String, dynamic> data;

  T? field<T>(String key) {
    final value = data[key];
    return value is T ? value : null;
  }

  String encode() => jsonEncode({'ev': ev, ...data});

  /// Parses an event string. Throws [ProtocolError] for unknown events.
  static Event decode(Object? raw) {
    final map = _decodeMap(raw);
    final ev = map.remove('ev');
    if (ev is! String) throw ProtocolError('missing "ev" field');
    if (!Ev.all.contains(ev)) throw ProtocolError('unknown event "$ev"');
    return Event(ev, map);
  }

  @override
  String toString() => 'Event($ev, ${data.keys.toList()})';
}

Map<String, dynamic> _decodeMap(Object? raw) {
  if (raw is Map) return Map<String, dynamic>.from(raw);
  if (raw is! String) {
    throw ProtocolError('expected a JSON string, got ${raw.runtimeType}');
  }
  final Object? decoded;
  try {
    decoded = jsonDecode(raw);
  } catch (error) {
    throw ProtocolError('invalid JSON: $error');
  }
  if (decoded is! Map) throw ProtocolError('expected a JSON object');
  return Map<String, dynamic>.from(decoded);
}
