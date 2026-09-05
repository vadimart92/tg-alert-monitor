import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tg_alert_monitor/core/bot/bot_api.dart';
import 'package:tg_alert_monitor/core/bot/forward_queue.dart';
import 'package:tg_alert_monitor/core/model/match_entry.dart';

ForwardTask _task(int id) => ForwardTask(
  chatId: -1001234567890,
  messageId: id,
  targetChatId: '-100999',
  html: 'payload $id',
);

const String _okBody = '{"ok":true,"result":{"message_id":1}}';

void main() {
  group('ForwardQueue rate limiting', () {
    test('leaves at least minInterval between consecutive sends', () {
      fakeAsync((async) {
        final sendTimes = <Duration>[];
        final client = MockClient((_) async {
          sendTimes.add(async.elapsed);
          return http.Response(_okBody, 200);
        });

        final queue = ForwardQueue(
          apiProvider: () => HttpBotApi(client, 'token'),
          onStatus: (_, _, _) {},
        );

        for (var id = 1; id <= 4; id++) {
          queue.enqueue(_task(id));
        }
        async.elapse(const Duration(seconds: 30));

        expect(sendTimes, hasLength(4));
        for (var i = 1; i < sendTimes.length; i++) {
          expect(
            sendTimes[i] - sendTimes[i - 1],
            greaterThanOrEqualTo(const Duration(milliseconds: 1500)),
            reason: 'gap between send $i and ${i - 1}',
          );
        }
      });
    });

    test('preserves FIFO order', () {
      fakeAsync((async) {
        final bodies = <String>[];
        final client = MockClient((request) async {
          bodies.add(request.body);
          return http.Response(_okBody, 200);
        });
        final queue = ForwardQueue(
          apiProvider: () => HttpBotApi(client, 'token'),
          onStatus: (_, _, _) {},
        );

        for (var id = 1; id <= 5; id++) {
          queue.enqueue(_task(id));
        }
        async.elapse(const Duration(seconds: 30));

        for (var id = 1; id <= 5; id++) {
          expect(bodies[id - 1], contains('payload $id'));
        }
      });
    });
  });

  group('ForwardQueue retries', () {
    test('honours retry_after on 429 and then succeeds', () {
      fakeAsync((async) {
        final attempts = <Duration>[];
        final client = MockClient((_) async {
          attempts.add(async.elapsed);
          if (attempts.length == 1) {
            return http.Response(
              '{"ok":false,"error_code":429,"description":"Too Many Requests",'
              '"parameters":{"retry_after":7}}',
              429,
            );
          }
          return http.Response(_okBody, 200);
        });

        final statuses = <MatchStatus>[];
        final queue = ForwardQueue(
          apiProvider: () => HttpBotApi(client, 'token'),
          onStatus: (_, status, _) => statuses.add(status),
        );

        queue.enqueue(_task(1));
        async.elapse(const Duration(seconds: 30));

        expect(attempts, hasLength(2));
        expect(
          attempts[1] - attempts[0],
          greaterThanOrEqualTo(const Duration(seconds: 7)),
        );
        expect(statuses, [MatchStatus.sent]);
      });
    });

    test('backs off exponentially on 5xx and eventually fails', () {
      fakeAsync((async) {
        final attempts = <Duration>[];
        final client = MockClient((_) async {
          attempts.add(async.elapsed);
          return http.Response('{"ok":false,"description":"boom"}', 500);
        });

        final statuses = <MatchStatus>[];
        String? lastError;
        final queue = ForwardQueue(
          apiProvider: () => HttpBotApi(client, 'token'),
          maxAttempts: 5,
          onStatus: (_, status, error) {
            statuses.add(status);
            lastError = error;
          },
        );

        queue.enqueue(_task(1));
        async.elapse(const Duration(minutes: 10));

        expect(attempts, hasLength(5));
        // Gaps grow 2s, 4s, 8s, 16s.
        final gaps = [
          for (var i = 1; i < attempts.length; i++)
            attempts[i] - attempts[i - 1],
        ];
        for (var i = 1; i < gaps.length; i++) {
          expect(
            gaps[i],
            greaterThan(gaps[i - 1]),
            reason: 'backoff must grow: $gaps',
          );
        }
        expect(statuses, [MatchStatus.failed]);
        expect(lastError, isNotNull);
      });
    });

    test('caps the backoff at maxBackoff', () {
      fakeAsync((async) {
        final attempts = <Duration>[];
        final client = MockClient((_) async {
          attempts.add(async.elapsed);
          return http.Response('{"ok":false,"description":"boom"}', 503);
        });

        final queue = ForwardQueue(
          apiProvider: () => HttpBotApi(client, 'token'),
          maxAttempts: 10,
          maxBackoff: const Duration(seconds: 60),
          onStatus: (_, _, _) {},
        );

        queue.enqueue(_task(1));
        async.elapse(const Duration(minutes: 20));

        final gaps = [
          for (var i = 1; i < attempts.length; i++)
            attempts[i] - attempts[i - 1],
        ];
        expect(attempts, hasLength(10));
        for (final gap in gaps) {
          expect(gap, lessThanOrEqualTo(const Duration(seconds: 61)));
        }
      });
    });

    test('a network failure is retried', () {
      fakeAsync((async) {
        var calls = 0;
        final client = MockClient((_) async {
          calls++;
          if (calls < 3) throw const SocketExceptionStub();
          return http.Response(_okBody, 200);
        });

        final statuses = <MatchStatus>[];
        final queue = ForwardQueue(
          apiProvider: () => HttpBotApi(client, 'token'),
          onStatus: (_, status, _) => statuses.add(status),
        );

        queue.enqueue(_task(1));
        async.elapse(const Duration(minutes: 2));

        expect(calls, 3);
        expect(statuses, [MatchStatus.sent]);
      });
    });
  });

  group('ForwardQueue permanent failures', () {
    test('403 fails immediately with no retries', () {
      fakeAsync((async) {
        var calls = 0;
        final client = MockClient((_) async {
          calls++;
          return http.Response(
            '{"ok":false,"error_code":403,'
            '"description":"Forbidden: bot is not a member"}',
            403,
          );
        });

        final statuses = <MatchStatus>[];
        String? lastError;
        final queue = ForwardQueue(
          apiProvider: () => HttpBotApi(client, 'token'),
          onStatus: (_, status, error) {
            statuses.add(status);
            lastError = error;
          },
        );

        queue.enqueue(_task(1));
        async.elapse(const Duration(minutes: 5));

        expect(calls, 1);
        expect(statuses, [MatchStatus.failed]);
        expect(lastError, contains('адміністратором'));
      });
    });

    test('401 and 400 also fail immediately', () {
      for (final status in [400, 401]) {
        fakeAsync((async) {
          var calls = 0;
          final client = MockClient((_) async {
            calls++;
            return http.Response(
              '{"ok":false,"error_code":$status,"description":"chat not found"}',
              status,
            );
          });
          final results = <MatchStatus>[];
          ForwardQueue(
            apiProvider: () => HttpBotApi(client, 'token'),
            onStatus: (_, s, _) => results.add(s),
          ).enqueue(_task(1));
          async.elapse(const Duration(minutes: 5));

          expect(calls, 1, reason: 'HTTP $status');
          expect(results, [MatchStatus.failed], reason: 'HTTP $status');
        });
      }
    });
  });

  group('ForwardQueue status reporting', () {
    test('reports the task it was given, so the log can be updated', () {
      fakeAsync((async) {
        final client = MockClient((_) async => http.Response(_okBody, 200));
        final reported = <int>[];
        final queue = ForwardQueue(
          apiProvider: () => HttpBotApi(client, 'token'),
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
        var calls = 0;
        final client = MockClient((_) async {
          calls++;
          return http.Response(_okBody, 200);
        });
        final queue = ForwardQueue(
          apiProvider: () => HttpBotApi(client, 'token'),
          onStatus: (_, _, _) {},
        );

        for (var id = 1; id <= 5; id++) {
          queue.enqueue(_task(id));
        }
        async.elapse(const Duration(milliseconds: 100));
        queue.stop();
        async.elapse(const Duration(seconds: 30));

        expect(calls, lessThan(5));
        expect(queue.pending, 0);
      });
    });
  });
}

/// Stand-in for a transport failure; [HttpBotApi] treats any throw from the
/// client as a retryable network error.
class SocketExceptionStub implements Exception {
  const SocketExceptionStub();
  @override
  String toString() => 'Connection refused';
}
