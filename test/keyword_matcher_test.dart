import 'package:flutter_test/flutter_test.dart';
import 'package:tg_alert_monitor/core/matcher/keyword_matcher.dart';

void main() {
  group('KeywordMatcher', () {
    test('matches regardless of case, including Cyrillic', () {
      final matcher = KeywordMatcher(['Шахед']);
      expect(matcher.match('ШАХЕДИ над містом'), ['Шахед']);
      expect(matcher.match('шахед'), ['Шахед']);
      expect(matcher.match('Збили ШаХеД'), ['Шахед']);
    });

    test('covers Ukrainian word forms through the stem', () {
      final matcher = KeywordMatcher(['шахед']);
      for (final text in ['шахед', 'шахеди', 'шахедів', 'шахедами']) {
        expect(matcher.match(text), ['шахед'], reason: text);
      }
    });

    test('returns every hit in configuration order, not text order', () {
      final matcher = KeywordMatcher(['балістика', 'шахед', 'Бровари']);
      expect(matcher.match('Бровари: шахед, потім балістика'), [
        'балістика',
        'шахед',
        'Бровари',
      ]);
    });

    test('a stem keyword matches declined forms of a place name', () {
      // "Бровари" is not a substring of "Броварами": the owner configures the
      // stem, exactly as decision R7 assumes.
      expect(KeywordMatcher(['Бровари']).match('над Броварами'), isEmpty);
      expect(KeywordMatcher(['Бровар']).match('над Броварами'), ['Бровар']);
    });

    test('no keywords means no match', () {
      expect(KeywordMatcher(const <String>[]).match('шахед'), isEmpty);
      expect(KeywordMatcher(const <String>[]).isEmpty, isTrue);
    });

    test('blank keywords are ignored', () {
      final matcher = KeywordMatcher(['  ', '', '\n\t', 'шахед']);
      expect(matcher.match('шахед'), ['шахед']);
      expect(matcher.match('нічого'), isEmpty);
    });

    test('a keyword with a space matches text broken across lines', () {
      final matcher = KeywordMatcher(['балістика на']);
      expect(matcher.match('увага балістика\nна Київ'), ['балістика на']);
      expect(matcher.match('балістика   на схід'), ['балістика на']);
    });

    test('zero-width characters do not hide a keyword', () {
      final matcher = KeywordMatcher(['шахед']);
      expect(matcher.match('ша\u200Bхед'), ['шахед']);
      expect(matcher.match('ша\u200Dхед\uFEFF'), ['шахед']);
      expect(KeywordMatcher(['ша\u200Cхед']).match('шахед'), isNotEmpty);
    });

    test('emoji in the text do not break matching', () {
      final matcher = KeywordMatcher(['шахед']);
      expect(matcher.match('🚨🚨 шахед над містом 💥'), ['шахед']);
    });

    test('a keyword prefixed with - excludes the message', () {
      final matcher = KeywordMatcher(['шахед', '-відбій']);
      expect(matcher.match('шахед над містом'), ['шахед']);
      expect(matcher.match('відбій, шахед збито'), isEmpty);
    });

    test('exclusions alone never produce a match', () {
      expect(KeywordMatcher(['-відбій']).match('відбій'), isEmpty);
      expect(KeywordMatcher(['-відбій']).isEmpty, isTrue);
    });
  });

  group('KeywordMatcher.sanitize', () {
    test('drops blanks and case-insensitive duplicates, keeping order', () {
      expect(
        KeywordMatcher.sanitize(['Шахед', ' ', 'шахед', 'ШАХЕД', 'Бровари']),
        ['Шахед', 'Бровари'],
      );
    });

    test('trims surrounding whitespace', () {
      expect(KeywordMatcher.sanitize(['  шахед  ']), ['шахед']);
    });
  });

  group('KeywordMatcher.normalize', () {
    test('collapses whitespace runs and lowercases', () {
      expect(KeywordMatcher.normalize('  Шахед \n\t над '), 'шахед над');
    });
  });
}
