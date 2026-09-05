import 'package:flutter_test/flutter_test.dart';
import 'package:tg_alert_monitor/core/bot/message_formatter.dart';

void main() {
  final time = DateTime(2026, 9, 5, 7, 4);

  group('escapeHtml', () {
    test('escapes &, < and > without double-escaping', () {
      expect(
        MessageFormatter.escapeHtml('<b>Ланка & <i>вогонь</i></b>'),
        '&lt;b&gt;Ланка &amp; &lt;i&gt;вогонь&lt;/i&gt;&lt;/b&gt;',
      );
    });

    test('leaves ordinary text alone', () {
      expect(MessageFormatter.escapeHtml('шахед 🚨'), 'шахед 🚨');
    });
  });

  group('hashtag', () {
    test('turns a plain keyword into a tag', () {
      expect(MessageFormatter.hashtag('шахед'), '#шахед');
      expect(MessageFormatter.hashtag('  Дрон  '), '#Дрон');
    });

    test('joins words with underscores, since a space would end the tag', () {
      expect(MessageFormatter.hashtag('балістика на'), '#балістика_на');
      expect(MessageFormatter.hashtag('тест-ключ'), '#тест_ключ');
      expect(MessageFormatter.hashtag('a\u2014b'), '#a_b');
    });

    test('drops characters Telegram would not accept in a tag', () {
      expect(MessageFormatter.hashtag('шахед!'), '#шахед');
      expect(MessageFormatter.hashtag('<b>шахед</b>'), '#bшахедb');
      expect(MessageFormatter.hashtag('шахед, балістика'), '#шахед_балістика');
    });

    test('collapses and trims underscores', () {
      expect(MessageFormatter.hashtag('шахед  --  дрон'), '#шахед_дрон');
      expect(MessageFormatter.hashtag('_шахед_'), '#шахед');
    });

    test('returns null when nothing taggable is left', () {
      expect(MessageFormatter.hashtag('123'), isNull);
      expect(MessageFormatter.hashtag('!!!'), isNull);
      expect(MessageFormatter.hashtag('   '), isNull);
      expect(MessageFormatter.hashtag('_'), isNull);
    });

    test('keeps digits when a letter is present', () {
      expect(MessageFormatter.hashtag('шахед136'), '#шахед136');
    });
  });

  group('renderKeywords', () {
    test('renders every keyword as a space-separated tag', () {
      expect(
        MessageFormatter.renderKeywords(['шахед', 'тест-ключ']),
        '#шахед #тест_ключ',
      );
    });

    test('falls back to escaped text for untaggable keywords', () {
      expect(MessageFormatter.renderKeywords(['<&>']), '&lt;&amp;&gt;');
    });
  });

  group('format', () {
    test('includes the chat title, keywords, link and time', () {
      final result = MessageFormatter.format(
        chatTitle: 'Тривога Київ',
        keywords: ['шахед', 'балістика'],
        text: 'Шахед над містом',
        link: 'https://t.me/c/1234567890/55',
        time: time,
      );

      expect(result, contains('<b>Тривога Київ</b>'));
      expect(result, contains('#шахед #балістика'));
      expect(result, contains('Шахед над містом'));
      expect(
        result,
        contains(
          '<a href="https://t.me/c/1234567890/55">Відкрити оригінал</a>',
        ),
      );
      expect(result, contains('07:04'));
    });

    test('escapes user-controlled fields', () {
      final result = MessageFormatter.format(
        chatTitle: 'A & <b>B</b>',
        keywords: ['<>'],
        text: 'сирена <b>гучна</b> & довга',
        link: 'https://t.me/c/1/2',
        time: time,
      );

      expect(result, contains('<b>A &amp; &lt;b&gt;B&lt;/b&gt;</b>'));
      // "<>" has nothing taggable left, so it falls back to escaped text.
      expect(result, contains('&lt;&gt;'));
      expect(result, contains('сирена &lt;b&gt;гучна&lt;/b&gt; &amp; довга'));
      // Only our own markup survives as real tags.
      expect('<b>'.allMatches(result).length, 1);
    });

    test('truncates a long body with an ellipsis', () {
      final result = MessageFormatter.format(
        chatTitle: 'Канал',
        keywords: ['шахед'],
        text: 'я' * 5000,
        link: 'https://t.me/c/1/2',
        time: time,
      );

      expect(result, contains('…'));
      expect(result.length, lessThanOrEqualTo(MessageFormatter.telegramLimit));
      expect(result, contains('Відкрити оригінал'));
    });

    test(
      'stays under the Bot API limit even when escaping expands the text',
      () {
        // Every character becomes 5 characters once escaped.
        final result = MessageFormatter.format(
          chatTitle: 'Канал',
          keywords: ['шахед'],
          text: '&' * 4000,
          link: 'https://t.me/c/1/2',
          time: time,
        );

        expect(
          result.length,
          lessThanOrEqualTo(MessageFormatter.telegramLimit),
        );
        expect(result, contains('&amp;'));
        expect(result, contains('…'));
      },
    );

    test('a short body is left untouched', () {
      final result = MessageFormatter.format(
        chatTitle: 'Канал',
        keywords: ['шахед'],
        text: 'коротко',
        link: 'https://t.me/c/1/2',
        time: time,
      );
      expect(result, isNot(contains('…')));
      expect(result, contains('коротко'));
    });

    test('never splits a surrogate pair when truncating', () {
      final result = MessageFormatter.format(
        chatTitle: 'Канал',
        keywords: ['шахед'],
        text: '🚨' * 3000,
        link: 'https://t.me/c/1/2',
        time: time,
      );

      expect(result.length, lessThanOrEqualTo(MessageFormatter.telegramLimit));
      // A lone surrogate would render as U+FFFD after a round trip.
      expect(result.runes.any((r) => r >= 0xD800 && r <= 0xDFFF), isFalse);
    });

    test('an empty link drops the anchor but keeps the time', () {
      final result = MessageFormatter.format(
        chatTitle: 'Канал',
        keywords: ['шахед'],
        text: 'текст',
        link: '',
        time: time,
      );
      expect(result, isNot(contains('<a href')));
      expect(result, contains('07:04'));
    });
  });
}
