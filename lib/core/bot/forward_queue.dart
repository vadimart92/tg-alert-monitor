/// Serialised, rate-limited delivery to the target channel.
library;

import 'dart:async';
import 'dart:collection';

import '../model/match_entry.dart';

/// One queued post.
class ForwardTask {
  const ForwardTask({
    required this.chatId,
    required this.messageId,
    required this.targetChatId,
    required this.html,
    String? botHtml,
    this.link = '',
  }) : botHtml = botHtml ?? html;

  /// Source chat and message — used to address status updates, and to forward
  /// the original through the owner's own session.
  final int chatId;
  final int messageId;

  /// Destination channel.
  final String targetChatId;

  /// Self-contained rendering, used when the original cannot be forwarded.
  final String html;

  /// Shorter rendering for the bot, which leans on Telegram's link preview
  /// instead of repeating the post.
  final String botHtml;

  /// Link to the original, so the sender can decide whether a preview is
  /// worth asking for.
  final String link;
}

/// Raised by a delivery attempt to tell the queue how to react.
class DeliveryFailure implements Exception {
  DeliveryFailure(this.message, {this.isPermanent = false, this.retryAfter});

  final String message;

  /// No retry can help: missing rights, unknown chat, deleted message.
  final bool isPermanent;

  /// Set when the far side asked us to wait a specific time.
  final Duration? retryAfter;

  @override
  String toString() => 'DeliveryFailure($message)';
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
    required this._deliver,
    required this.onStatus,
    this.minInterval = const Duration(milliseconds: 1500),
    this.maxAttempts = 10,
    this.initialBackoff = const Duration(seconds: 2),
    this.maxBackoff = const Duration(seconds: 60),
    this._onLog,
  });

  /// How a task is actually delivered. Injected so the queue keeps only the
  /// ordering, spacing and retry policy, and knows nothing about how a message
  /// reaches Telegram.
  final Future<void> Function(ForwardTask task) _deliver;
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
        await _deliverWithRetries(task);
        _sentAny = true;
      }
    } finally {
      _working = false;
    }
  }

  Future<void> _deliverWithRetries(ForwardTask task) async {
    var backoff = initialBackoff;

    for (var attempt = 1; attempt <= maxAttempts; attempt++) {
      if (_stopped) return;
      try {
        await _deliver(task);
        onStatus(task, MatchStatus.sent, null);
        return;
      } on DeliveryFailure catch (error) {
        if (error.isPermanent) {
          _onLog?.call(
            'delivery failed permanently for '
            '${task.chatId}/${task.messageId}: ${error.message}',
          );
          onStatus(task, MatchStatus.failed, error.message);
          return;
        }

        final wait = error.retryAfter;
        if (wait != null) {
          _onLog?.call('rate limited, waiting ${wait.inSeconds}s');
          await Future<void>.delayed(wait);
          // Flood waits are not the caller's fault: do not burn an attempt.
          attempt--;
          continue;
        }

        if (attempt == maxAttempts) {
          _onLog?.call(
            'delivery gave up after $attempt attempts: ${error.message}',
          );
          onStatus(task, MatchStatus.failed, error.message);
          return;
        }

        _onLog?.call(
          'delivery attempt $attempt failed (${error.message}), '
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
