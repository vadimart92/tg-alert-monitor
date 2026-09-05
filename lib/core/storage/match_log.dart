/// `matches.jsonl` — one JSON object per line, newest at the bottom.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../model/match_entry.dart';

/// What the engine needs from the match log. Tests use an in-memory fake.
abstract class MatchSink {
  Future<void> append(MatchEntry entry);

  Future<void> updateStatus(
    int chatId,
    int messageId,
    MatchStatus status, {
    String? error,
  });
}

/// Append-only log with rotation.
///
/// All writes are serialised through [_lock] so that a status update never
/// interleaves with an append and loses a line.
class MatchLog implements MatchSink {
  MatchLog(this.file, {this.rotateAt = 1000, this.keepAfterRotate = 500});

  final File file;

  /// Rotate once the file exceeds this many lines...
  final int rotateAt;

  /// ...keeping this many of the newest.
  final int keepAfterRotate;

  Future<void> _lock = Future<void>.value();

  Future<T> _serialised<T>(Future<T> Function() action) {
    final completer = Completer<T>();
    _lock = _lock.then((_) async {
      try {
        completer.complete(await action());
      } catch (error, stack) {
        completer.completeError(error, stack);
      }
    });
    return completer.future;
  }

  @override
  Future<void> append(MatchEntry entry) => _serialised(() async {
    await file.parent.create(recursive: true);
    await file.writeAsString(
      '${jsonEncode(entry.toJson())}\n',
      mode: FileMode.append,
      flush: true,
    );
    await _rotateIfNeeded();
  });

  @override
  Future<void> updateStatus(
    int chatId,
    int messageId,
    MatchStatus status, {
    String? error,
  }) => _serialised(() async {
    final lines = await _readLines();
    if (lines.isEmpty) return;
    var changed = false;
    // Walk from the end: the entry we are updating was just written.
    for (var i = lines.length - 1; i >= 0; i--) {
      final entry = _parse(lines[i]);
      if (entry == null) continue;
      if (entry.chatId != chatId || entry.messageId != messageId) continue;
      lines[i] = jsonEncode(
        entry.copyWith(status: status, error: error).toJson(),
      );
      changed = true;
      break;
    }
    if (!changed) return;
    await file.writeAsString('${lines.join('\n')}\n', flush: true);
  });

  /// Newest first, at most [limit] entries.
  Future<List<MatchEntry>> read({int limit = 500}) => _serialised(() async {
    final lines = await _readLines();
    final entries = <MatchEntry>[];
    for (var i = lines.length - 1; i >= 0 && entries.length < limit; i--) {
      final entry = _parse(lines[i]);
      if (entry != null) entries.add(entry);
    }
    return entries;
  });

  Future<void> clear() => _serialised(() async {
    if (await file.exists()) await file.delete();
  });

  Future<List<String>> _readLines() async {
    if (!await file.exists()) return <String>[];
    final content = await file.readAsString();
    return content
        .split('\n')
        .where((line) => line.trim().isNotEmpty)
        .toList(growable: true);
  }

  Future<void> _rotateIfNeeded() async {
    final lines = await _readLines();
    if (lines.length <= rotateAt) return;
    final kept = lines.sublist(lines.length - keepAfterRotate);
    await file.writeAsString('${kept.join('\n')}\n', flush: true);
  }

  static MatchEntry? _parse(String line) {
    try {
      final decoded = jsonDecode(line);
      if (decoded is! Map) return null;
      return MatchEntry.fromJson(Map<String, dynamic>.from(decoded));
    } catch (_) {
      return null;
    }
  }
}
