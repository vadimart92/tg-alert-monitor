/// Ring-buffer logger with secret masking.
///
/// Message texts never reach this log — only ids — so that `log.get` and the
/// system log screen stay safe to read and share.
library;

/// One line of the system log.
class LogLine {
  const LogLine(this.time, this.level, this.message);

  final DateTime time;
  final String level;
  final String message;

  Map<String, dynamic> toJson() => {
    'time': time.toIso8601String(),
    'level': level,
    'message': message,
  };

  static LogLine fromJson(Map<String, dynamic> json) => LogLine(
    DateTime.tryParse(json['time'] as String? ?? '') ??
        DateTime.fromMillisecondsSinceEpoch(0),
    json['level'] as String? ?? 'info',
    json['message'] as String? ?? '',
  );

  @override
  String toString() => '[$level] $message';
}

class AppLogger {
  AppLogger({this.capacity = 300, this.onLine, this.printer});

  final int capacity;

  /// Called for every accepted line — the service forwards it to the UI.
  final void Function(LogLine line)? onLine;

  /// Injectable sink; defaults to `print` in debug builds.
  final void Function(String line)? printer;

  final List<LogLine> _lines = <LogLine>[];
  final Set<String> _secrets = <String>{};

  /// Bot tokens have a recognisable shape; mask them wherever they appear.
  static final RegExp _tokenPattern = RegExp(r'\d{6,}:[A-Za-z0-9_-]{30,}');

  /// Registers a literal secret (bot token, api_hash) for masking.
  void addSecret(String? secret) {
    if (secret == null) return;
    final trimmed = secret.trim();
    if (trimmed.length < 8) return;
    _secrets.add(trimmed);
  }

  void clearSecrets() => _secrets.clear();

  /// Replaces every known secret and token-shaped substring with `***`.
  String mask(String value) {
    var masked = value;
    for (final secret in _secrets) {
      masked = masked.replaceAll(secret, '***');
    }
    return masked.replaceAll(_tokenPattern, '***');
  }

  void info(String message) => log('info', message);
  void warn(String message) => log('warn', message);
  void error(String message) => log('error', message);

  void log(String level, String message) {
    final line = LogLine(DateTime.now(), level, mask(message));
    _lines.add(line);
    if (_lines.length > capacity) {
      _lines.removeRange(0, _lines.length - capacity);
    }
    final sink = printer;
    if (sink != null) sink('[$level] ${line.message}');
    onLine?.call(line);
  }

  /// Newest last.
  List<LogLine> get lines => List<LogLine>.unmodifiable(_lines);

  List<Map<String, dynamic>> toJson() => [
    for (final line in _lines) line.toJson(),
  ];

  void clear() => _lines.clear();
}
