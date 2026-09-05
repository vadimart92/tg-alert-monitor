import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tg_alert_monitor/core/bot/forward_queue.dart';
import 'package:tg_alert_monitor/core/model/match_entry.dart';

ForwardTask _task(int id) => ForwardTask(
  chatId: -1001234567890,
  messageId: id,
  targetChatId: '-100999',
  html: 'payload $id',
);

/// Scripted delivery: records when each attempt happened and fails on demand,
/// so the queue's ordering, spacing and retry policy can be observed without
/// any real transport.
class FakeDelivery {
  FakeDelivery(this._clock);

  final Duration Function() _clock;

  /// One entry per attempt, including retries.
  final List<Duration> attempts = <Duration>[];
  final List<ForwardTask> delivered = <ForwardTask>[];

  /// Failure to raise for a given attempt number; `null` lets it succeed.
  DeliveryFailure? Function(int attempt)? failWith;

  Future<void> call(ForwardTask task) async {
    attempts.add(_clock());
    final failure = failWith?.call(attempts.length);
    if (failure != null) throw failure;
    delivered.add(task);
  }

  List<Duration> get gaps => [
    for (var i = 1; i < attempts.length; i++) attempts[i] - attempts[i - 1],
  ];
}

void main() {
  group('ForwardQueue rate limiting', () {
    test('leaves at least minInterval between consecutive sends', () {
      fakeAsync((async) {
        final delivery = FakeDelivery(() => async.elapsed);
        final queue = ForwardQueue(
          deliver: delivery.call,
          onStatus: (_, _, _) {},
        );

        for (var id = 1; id <= 4; id++) {
          queue.enqueue(_task(id));
        }
        async.elapse(const Duration(seconds: 30));

        expect(delivery.attempts, hasLength(4));
        for (final gap in delivery.gaps) {
          expect(gap, greaterThanOrEqualTo(const Duration(milliseconds: 1500)));
        }
      });
    });

    test('preserves FIFO order', () {
      fakeAsync((async) {
        final delivery = FakeDelivery(() => async.elapsed);
        final queue = ForwardQueue(
          deliver: delivery.call,
          onStatus: (_, _, _) {},
        );

        for (var id = 1; id <= 5; id++) {
          queue.enqueue(_task(id));
        }
        async.elapse(const Duration(seconds: 30));

        expect(delivery.delivered.map((t) => t.messageId), [1, 2, 3, 4, 5]);
      });
    });
  });

  group('ForwardQueue retries', () {
    test('waits exactly as long as a rate limit asks, then succeeds', () {
      fakeAsync((async) {
        final delivery = FakeDelivery(() => async.elapsed)
          ..failWith = (attempt) => attempt == 1
              ? DeliveryFailure(
                  'Too Many Requests',
                  retryAfter: const Duration(seconds: 7),
                )
              : null;

        final statuses = <MatchStatus>[];
        ForwardQueue(
          deliver: delivery.call,
          onStatus: (_, status, _) => statuses.add(status),
        ).enqueue(_task(1));
        async.elapse(const Duration(seconds: 30));

        expect(delivery.attempts, hasLength(2));
        expect(
          delivery.gaps.single,
          greaterThanOrEqualTo(const Duration(seconds: 7)),
        );
        expect(statuses, [MatchStatus.sent]);
      });
    });

    test('backs off exponentially on a transient failure, then gives up', () {
      fakeAsync((async) {
        final delivery = FakeDelivery(() => async.elapsed)
          ..failWith = (_) => DeliveryFailure('boom');

        final statuses = <MatchStatus>[];
        String? lastError;
        ForwardQueue(
          deliver: delivery.call,
          maxAttempts: 5,
          onStatus: (_, status, error) {
            statuses.add(status);
            lastError = error;
          },
        ).enqueue(_task(1));
        async.elapse(const Duration(minutes: 10));

        expect(delivery.attempts, hasLength(5));
        final gaps = delivery.gaps;
        for (var i = 1; i < gaps.length; i++) {
          expect(
            gaps[i],
            greaterThan(gaps[i - 1]),
            reason: 'backoff must grow: $gaps',
          );
        }
        expect(statuses, [MatchStatus.failed]);
        expect(lastError, 'boom');
      });
    });

    test('caps the backoff at maxBackoff', () {
      fakeAsync((async) {
        final delivery = FakeDelivery(() => async.elapsed)
          ..failWith = (_) => DeliveryFailure('boom');

        ForwardQueue(
          deliver: delivery.call,
          maxAttempts: 10,
          maxBackoff: const Duration(seconds: 60),
          onStatus: (_, _, _) {},
        ).enqueue(_task(1));
        async.elapse(const Duration(minutes: 20));

        expect(delivery.attempts, hasLength(10));
        for (final gap in delivery.gaps) {
          expect(gap, lessThanOrEqualTo(const Duration(seconds: 61)));
        }
      });
    });

    test('a transient failure that clears is retried and delivered', () {
      fakeAsync((async) {
        final delivery = FakeDelivery(() => async.elapsed)
          ..failWith = (attempt) =>
              attempt < 3 ? DeliveryFailure('no network') : null;

        final statuses = <MatchStatus>[];
        ForwardQueue(
          deliver: delivery.call,
          onStatus: (_, status, _) => statuses.add(status),
        ).enqueue(_task(1));
        async.elapse(const Duration(minutes: 2));

        expect(delivery.attempts, hasLength(3));
        expect(statuses, [MatchStatus.sent]);
      });
    });
  });

  group('ForwardQueue permanent failures', () {
    test('a permanent failure is not retried', () {
      fakeAsync((async) {
        final delivery = FakeDelivery(() => async.elapsed)
          ..failWith = (_) => DeliveryFailure(
            'Немає права публікувати в цільовому каналі.',
            isPermanent: true,
          );

        final statuses = <MatchStatus>[];
        String? lastError;
        ForwardQueue(
          deliver: delivery.call,
          onStatus: (_, status, error) {
            statuses.add(status);
            lastError = error;
          },
        ).enqueue(_task(1));
        async.elapse(const Duration(minutes: 5));

        expect(delivery.attempts, hasLength(1));
        expect(statuses, [MatchStatus.failed]);
        expect(lastError, contains('права публікувати'));
      });
    });

    test('an unexpected error is reported rather than retried forever', () {
      fakeAsync((async) {
        final statuses = <MatchStatus>[];
        ForwardQueue(
          deliver: (_) async => throw StateError('bug'),
          onStatus: (_, status, _) => statuses.add(status),
        ).enqueue(_task(1));
        async.elapse(const Duration(minutes: 5));

        expect(statuses, [MatchStatus.failed]);
      });
    });

    test('one failing task does not block the rest of the queue', () {
      fakeAsync((async) {
        final delivery = FakeDelivery(() => async.elapsed)
          ..failWith = (attempt) =>
              attempt == 1 ? DeliveryFailure('nope', isPermanent: true) : null;

        final queue = ForwardQueue(
          deliver: delivery.call,
          onStatus: (_, _, _) {},
        );
        queue.enqueue(_task(1));
        queue.enqueue(_task(2));
        async.elapse(const Duration(seconds: 30));

        expect(delivery.delivered.map((t) => t.messageId), [2]);
      });
    });
  });

  group('ForwardQueue status reporting', () {
    test('reports the task it was given, so the log can be updated', () {
      fakeAsync((async) {
        final delivery = FakeDelivery(() => async.elapsed);
        final reported = <int>[];
        final queue = ForwardQueue(
          deliver: delivery.call,
          onStatus: (task, _, _) => reported.add(task.messageId),
        );

        queue.enqueue(_task(11));
        queue.enqueue(_task(22));
        async.elapse(const Duration(seconds: 30));

        expect(reported, [11, 22]);
      });
    });

    test('stop() drops everything not yet sent', () {
      fakeAsync((async) {
        final delivery = FakeDelivery(() => async.elapsed);
        final queue = ForwardQueue(
          deliver: delivery.call,
          onStatus: (_, _, _) {},
        );

        for (var id = 1; id <= 5; id++) {
          queue.enqueue(_task(id));
        }
        async.elapse(const Duration(milliseconds: 100));
        queue.stop();
        async.elapse(const Duration(seconds: 30));

        expect(delivery.attempts.length, lessThan(5));
        expect(queue.pending, 0);
      });
    });
  });
}
