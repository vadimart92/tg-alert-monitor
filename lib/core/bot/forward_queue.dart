/// Serialised, rate-limited delivery to the target channel.
library;

import 'dart:async';
import 'dart:collection';

import '../model/match_entry.dart';
import 'bot_api.dart';

/// One queued post.
class ForwardTask {
  const ForwardTask({
    required this.chatId,
    required this.messageId,
    required this.targetChatId,
    required this.html,
  });

  /// Source chat and message — used to address status updates.
  final int chatId;
  final int messageId;

  /// Destination channel and rendered payload.
  final String targetChatId;
  final String html;
}

/// Reports the outcome of a task.
typedef ForwardStatusCallback = void Function(
  ForwardTask task,
  MatchStatus status,
  String? error,
);

/// FIFO queue with a single worker.
///
/// Telegram allows roughly 20 messages per minute into one channel, so sends
/// are spaced by [minInterval]. A 429 is honoured exactly as instructed; 5xx
/// and network failures back off exponentially; 4xx fails immediately because
/// no amount of retrying fixes a bad token or a missing admin right.
class ForwardQueue {
  ForwardQueue({
    required this._apiProvider,
    required this.onStatus,
    this.minInterval = const Duration(milliseconds: 1500),
    this.maxAttempts = 10,
    this.initialBackoff = const Duration(seconds: 2),
    this.maxBackoff = const Duration(seconds: 60),
    this._onLog,
  });

  final BotApi Function() _apiProvider;
  final ForwardStatusCallback onStatus;
  final Duration minInterval;
  final int maxAttempts;
  final Duration initialBackoff;
  final Duration maxBackoff;
  final void Function(String message)? _onLog;

  final Queue<ForwardTask> _queue = Queue<ForwardTask>();
  bool _working = false;
  bool _stopped = false;
  bool _sentAny = false;

  int get pending => _queue.length;
  bool get isIdle => !_working && _queue.isEmpty;

  /// Adds a task and kicks the worker if it is asleep.
  void enqueue(ForwardTask task) {
    if (_stopped) return;
    _queue.add(task);
    unawaited(_pump());
  }

  /// Drops everything not yet sent and stops the worker.
  void stop() {
    _stopped = true;
    _queue.clear();
  }

  Future<void> _pump() async {
    if (_working) return;
    _working = true;
    try {
      while (_queue.isNotEmpty && !_stopped) {
        // Space out sends, but do not delay the very first one.
        if (_sentAny) await Future<void>.delayed(minInterval);
        if (_stopped) break;
        final task = _queue.removeFirst();
        await _deliver(task);
        _sentAny = true;
      }
    } finally {
      _working = false;
    }
  }

  Future<void> _deliver(ForwardTask task) async {
    var backoff = initialBackoff;

    for (var attempt = 1; attempt <= maxAttempts; attempt++) {
      if (_stopped) return;
      try {
        await _apiProvider().sendMessage(
          chatId: task.targetChatId,
          html: task.html,
        );
        onStatus(task, MatchStatus.sent, null);
        return;
      } on BotApiException catch (error) {
        if (error.isPermanent) {
          _onLog?.call(
            'forward failed permanently for ${task.chatId}/${task.messageId}: '
            '${error.description}',
          );
          onStatus(task, MatchStatus.failed, error.userMessage);
          return;
        }

        if (error.isRateLimited) {
          final wait = error.retryAfter ?? const Duration(seconds: 5);
          _onLog?.call('rate limited, waiting ${wait.inSeconds}s');
          await Future<void>.delayed(wait);
          // Flood waits are not the caller's fault: do not burn an attempt.
          attempt--;
          continue;
        }

        if (attempt == maxAttempts) {
          _onLog?.call(
            'forward gave up after $attempt attempts: ${error.description}',
          );
          onStatus(task, MatchStatus.failed, error.userMessage);
          return;
        }

        _onLog?.call(
          'forward attempt $attempt failed (${error.description}), '
          'retry in ${backoff.inSeconds}s',
        );
        await Future<void>.delayed(backoff);
        final doubled = backoff * 2;
        backoff = doubled > maxBackoff ? maxBackoff : doubled;
      } catch (error) {
        // Anything unexpected is treated as permanent: better a visible
        // failure in the log than an endless retry loop.
        _onLog?.call('forward crashed: $error');
        onStatus(task, MatchStatus.failed, error.toString());
        return;
      }
    }
  }
}
