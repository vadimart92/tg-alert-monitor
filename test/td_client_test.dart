import 'package:flutter_test/flutter_test.dart';
import 'package:tg_alert_monitor/core/td/td_client.dart';

import 'fakes/fakes.dart';

void main() {
  late FakeTdTransport transport;
  late TdClient client;

  setUp(() {
    transport = FakeTdTransport();
    client = TdClient(transport);
  });

  tearDown(() async => client.close());

  test('correlates a response by @extra', () async {
    transport.responders['getMe'] = (_) => {
      '@type': 'user',
      'first_name': 'Вадим',
    };

    final response = await client.send({'@type': 'getMe'});

    expect(response['first_name'], 'Вадим');
    // The correlation id is an implementation detail, stripped from the result.
    expect(response.containsKey('@extra'), isFalse);
    expect(transport.sentOfType('getMe').single['@extra'], isNotNull);
  });

  test('messages without @extra go to the updates stream', () async {
    final updates = <Map<String, dynamic>>[];
    client.updates.listen(updates.add);

    transport.push({'@type': 'updateConnectionState'});
    transport.push({'@type': 'updateNewMessage'});
    await pumpEventQueue();

    expect(updates.map((u) => u['@type']), [
      'updateConnectionState',
      'updateNewMessage',
    ]);
  });

  test('an error response becomes a TdError', () async {
    transport.responders['getChat'] = (_) => {
      '@type': 'error',
      'code': 400,
      'message': 'CHAT_NOT_FOUND',
    };

    await expectLater(
      client.send({'@type': 'getChat', 'chat_id': 1}),
      throwsA(
        isA<TdError>()
            .having((e) => e.code, 'code', 400)
            .having((e) => e.message, 'message', 'CHAT_NOT_FOUND')
            .having((e) => e.request, 'request', 'getChat'),
      ),
    );
  });

  test('an unanswered request times out', () async {
    await expectLater(
      client.send({
        '@type': 'getChats',
      }, timeout: const Duration(milliseconds: 50)),
      throwsA(isA<TdTimeout>().having((e) => e.request, 'request', 'getChats')),
    );
  });

  test('concurrent requests do not get crossed', () async {
    transport.responders['getChat'] = (request) => {
      '@type': 'chat',
      'id': request['chat_id'],
      'title': 'chat-${request['chat_id']}',
    };

    final results = await Future.wait([
      for (var id = 1; id <= 20; id++)
        client.send({'@type': 'getChat', 'chat_id': id}),
    ]);

    for (var index = 0; index < results.length; index++) {
      expect(results[index]['id'], index + 1);
      expect(results[index]['title'], 'chat-${index + 1}');
    }
  });

  test('a late reply to a timed-out request is dropped, not delivered as an update', () async {
    final updates = <Map<String, dynamic>>[];
    client.updates.listen(updates.add);

    // Capture the @extra, answer only after the request has already timed out.
    transport.responders['getChats'] = (_) => null;
    final pending = client.send({
      '@type': 'getChats',
    }, timeout: const Duration(milliseconds: 20));
    await expectLater(pending, throwsA(isA<TdTimeout>()));

    final extra = transport.sentOfType('getChats').single['@extra'];
    transport.push({'@type': 'chats', 'chat_ids': const [], '@extra': extra});
    await pumpEventQueue();

    expect(updates, isEmpty);
  });

  test('unparseable lines are ignored', () async {
    final updates = <Map<String, dynamic>>[];
    client.updates.listen(updates.add);

    transport.pushRaw('not json at all');
    transport.pushRaw('[1,2,3]');
    transport.push({'@type': 'updateOk'});
    await pumpEventQueue();

    expect(updates.single['@type'], 'updateOk');
  });

  test('close fails pending requests and shuts the transport down', () async {
    transport.responders['getChats'] = (_) => null;
    final pending = client.send({'@type': 'getChats'});
    // Attach the expectation first: an unobserved error would otherwise be
    // reported as an unhandled async exception before we could assert on it.
    final expectation = expectLater(pending, throwsA(isA<StateError>()));

    await client.close();

    await expectation;
    expect(transport.closed, isTrue);
  });
}
