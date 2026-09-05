import 'package:flutter_test/flutter_test.dart';
import 'package:tg_alert_monitor/core/ipc/protocol.dart';

void main() {
  group('Command', () {
    test('every command round-trips through JSON', () {
      final samples = <Command>[
        Command(Cmd.uiAttached),
        Command(Cmd.uiDetached),
        Command(Cmd.authPhone, {'phone': '+380501234567'}),
        Command(Cmd.authCode, {'code': '12345'}),
        Command(Cmd.authResend),
        Command(Cmd.authPassword, {'password': 'secret'}),
        Command(Cmd.authLogout),
        Command(Cmd.foldersList),
        Command(Cmd.foldersChats, {'folderId': 7}),
        Command(Cmd.monitorStart, {
          'config': {
            'folderId': 7,
            'keywords': ['шахед'],
          },
        }),
        Command(Cmd.monitorStop),
        Command(Cmd.monitorConfig, {
          'config': {
            'folderId': 7,
            'keywords': ['шахед'],
          },
        }),
        Command(Cmd.botCheck, {'targetChatId': '@c'}),
        Command(Cmd.botTest, {'targetChatId': '-100123'}),
        Command(Cmd.botTargets),
        Command(Cmd.logGet),
      ];

      // Guards against a command being added to Cmd.all but not covered here.
      expect(samples.map((c) => c.cmd).toSet(), Cmd.all);

      for (final original in samples) {
        final decoded = Command.decode(original.encode());
        expect(decoded.cmd, original.cmd, reason: original.cmd);
        expect(decoded.args, original.args, reason: original.cmd);
      }
    });

    test('typed argument access', () {
      final command = Command.decode(
        Command(Cmd.foldersChats, {'folderId': 7}).encode(),
      );
      expect(command.arg<num>('folderId')?.toInt(), 7);
      expect(command.arg<String>('folderId'), isNull);
      expect(command.arg<String>('missing'), isNull);
    });

    test('an unknown command is rejected without crashing', () {
      expect(
        () => Command.decode('{"cmd":"nope"}'),
        throwsA(isA<ProtocolError>()),
      );
    });

    test('malformed input is rejected without crashing', () {
      for (final bad in [
        '',
        'not json',
        '[1,2]',
        '{"no":"cmd"}',
        '{"cmd":5}',
      ]) {
        expect(
          () => Command.decode(bad),
          throwsA(isA<ProtocolError>()),
          reason: bad,
        );
      }
      expect(() => Command.decode(42), throwsA(isA<ProtocolError>()));
      expect(() => Command.decode(null), throwsA(isA<ProtocolError>()));
    });
  });

  group('Event', () {
    test('every event round-trips through JSON', () {
      final samples = <Event>[
        Event(Ev.state, {
          'auth': 'ready',
          'authDetail': '',
          'userName': 'Вадим',
          'connection': 'ready',
          'monitoring': true,
          'startedAt': '2026-09-05T07:00:00.000',
          'chatCount': 12,
          'matchCount': 3,
          'lastMatchAt': null,
          'tdVersion': '1.8.65',
        }),
        Event(Ev.folders, {
          'items': [
            {'id': 1, 'name': 'Тривога'},
          ],
        }),
        Event(Ev.folderChats, {
          'folderId': 1,
          'items': [
            {'id': -100123, 'title': 'Канал', 'isChannel': true},
          ],
        }),
        Event(Ev.match, {
          'time': '2026-09-05T07:00:00.000',
          'chatId': -100123,
          'chatTitle': 'Канал',
          'messageId': 55,
          'text': 'шахед',
          'keywords': ['шахед'],
          'link': 'https://t.me/c/123/55',
          'status': 'queued',
        }),
        Event(Ev.matchStatus, {
          'chatId': -100123,
          'messageId': 55,
          'status': 'sent',
        }),
        Event(Ev.botInfo, {'botName': 'Bot', 'chatTitle': 'Канал'}),
        Event(Ev.botTargets, {
          'items': [
            {'id': -100123, 'title': 'Тривога', 'isChannel': true},
          ],
        }),
        Event(Ev.error, {'scope': 'bot', 'code': 403, 'message': 'forbidden'}),
        Event(Ev.log, {
          'time': '2026-09-05T07:00:00.000',
          'level': 'info',
          'message': 'hello',
        }),
        Event(Ev.logLines, {'lines': const <Map<String, dynamic>>[]}),
      ];

      expect(samples.map((e) => e.ev).toSet(), Ev.all);

      for (final original in samples) {
        final decoded = Event.decode(original.encode());
        expect(decoded.ev, original.ev, reason: original.ev);
        expect(decoded.data, original.data, reason: original.ev);
      }
    });

    test('an unknown event is rejected without crashing', () {
      expect(
        () => Event.decode('{"ev":"nope"}'),
        throwsA(isA<ProtocolError>()),
      );
      expect(
        () => Event.decode('{"cmd":"state"}'),
        throwsA(isA<ProtocolError>()),
      );
    });

    test('typed field access', () {
      final event = Event.decode(
        Event(Ev.matchStatus, {
          'chatId': -100123,
          'messageId': 55,
          'status': 'sent',
        }).encode(),
      );
      expect(event.field<num>('chatId')?.toInt(), -100123);
      expect(event.field<String>('status'), 'sent');
      expect(event.field<bool>('status'), isNull);
    });
  });
}
