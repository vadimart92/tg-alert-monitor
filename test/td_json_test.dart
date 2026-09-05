import 'package:flutter_test/flutter_test.dart';
import 'package:tg_alert_monitor/core/td/td_json.dart';

void main() {
  group('extractText', () {
    test('reads messageText', () {
      expect(
        extractText({
          '@type': 'messageText',
          'text': {'@type': 'formattedText', 'text': 'шахед над містом'},
        }),
        'шахед над містом',
      );
    });

    test('reads the caption of media messages', () {
      for (final type in [
        'messagePhoto',
        'messageVideo',
        'messageDocument',
        'messageAnimation',
      ]) {
        expect(
          extractText({
            '@type': type,
            'caption': {'@type': 'formattedText', 'text': 'підпис'},
          }),
          'підпис',
          reason: type,
        );
      }
    });

    test('media without a caption yields null', () {
      expect(
        extractText({
          '@type': 'messagePhoto',
          'caption': {'@type': 'formattedText', 'text': ''},
        }),
        isNull,
      );
      expect(extractText({'@type': 'messageVideo'}), isNull);
    });

    test('unsupported content types yield null', () {
      expect(extractText({'@type': 'messageSticker'}), isNull);
      expect(extractText({'@type': 'messagePoll'}), isNull);
      expect(extractText({'@type': 'messageChatAddMembers'}), isNull);
    });

    test('malformed json does not throw', () {
      expect(extractText(null), isNull);
      expect(extractText('not a map'), isNull);
      expect(extractText(<String, dynamic>{}), isNull);
      expect(extractText({'@type': 'messageText'}), isNull);
      expect(extractText({'@type': 'messageText', 'text': 'raw'}), isNull);
      expect(
        extractText({
          '@type': 'messageText',
          'text': {'text': 42},
        }),
        isNull,
      );
    });
  });

  group('folderName', () {
    test('reads the nested chatFolderName.text.text', () {
      expect(
        folderName({
          'id': 3,
          'name': {
            '@type': 'chatFolderName',
            'text': {'@type': 'formattedText', 'text': 'Тривога'},
          },
        }),
        'Тривога',
      );
    });

    test('falls back to a plain title and never throws', () {
      expect(folderName({'title': 'Старий формат'}), 'Старий формат');
      expect(folderName({'name': 'Проста назва'}), 'Проста назва');
      expect(folderName(null), '');
      expect(folderName(<String, dynamic>{}), '');
    });
  });

  group('fallbackLink', () {
    test('builds a t.me/c link from a -100 supergroup id', () {
      expect(fallbackLink(-1001234567890, 55), 'https://t.me/c/1234567890/55');
    });

    test('returns empty for chats without a public link form', () {
      expect(fallbackLink(123456, 55), '');
      expect(fallbackLink(-4567, 55), '');
    });
  });

  group('serverMessageId', () {
    test('undoes the 20-bit shift TDLib applies to message ids', () {
      expect(serverMessageId(55 << 20), 55);
      expect(serverMessageId(1048576), 1);
    });
  });

  group('chat helpers', () {
    test('isChannel is true only for broadcast supergroups', () {
      expect(
        isChannel({
          'type': {'@type': 'chatTypeSupergroup', 'is_channel': true},
        }),
        isTrue,
      );
      expect(
        isChannel({
          'type': {'@type': 'chatTypeSupergroup', 'is_channel': false},
        }),
        isFalse,
      );
      expect(
        isChannel({
          'type': {'@type': 'chatTypePrivate'},
        }),
        isFalse,
      );
      expect(isChannel(null), isFalse);
    });

    test('chatTitle tolerates missing fields', () {
      expect(chatTitle({'title': 'Тест'}), 'Тест');
      expect(chatTitle(<String, dynamic>{}), '');
      expect(chatTitle(null), '');
    });
  });
}
