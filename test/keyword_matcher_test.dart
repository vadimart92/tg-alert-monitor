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
      final matcher = KeywordMatcher(['балістика', 'шахед', 'дрони']);
      expect(matcher.match('дрони, шахед, потім балістика'), [
        'балістика',
        'шахед',
        'дрони',
      ]);
    });

    test('a word typed in full still matches its declined forms', () {
      // The keyword is reduced to a stem, so the owner does not have to know
      // that "дрони" is not a substring of "дронами".
      expect(KeywordMatcher(['дрони']).match('над дронами'), ['дрони']);
      expect(KeywordMatcher(['дрон']).match('над дронами'), ['дрон']);
    });

    test('covers the cases an alert channel actually writes', () {
      final matcher = KeywordMatcher(['зенітка', 'ставка']);
      const texts = [
        'Ціль курсом на зенітку',
        'Працює зенітка',
        'Над зеніткою БпЛА',
        'Вибухи біля зенітки',
      ];
      for (final text in texts) {
        expect(matcher.match(text), ['зенітка'], reason: text);
      }
      expect(matcher.match('Зміни у ставці'), ['ставка']);
      expect(matcher.match('Ціль на ставку'), ['ставка']);
    });

    test('the reported keyword is the one the owner typed, not the stem', () {
      expect(KeywordMatcher(['зенітка']).match('на зенітку'), ['зенітка']);
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

  group('KeywordMatcher.stemOf', () {
    test('cuts a trailing inflectional vowel', () {
      expect(KeywordMatcher.stemOf('ракета'), 'ракет');
      expect(KeywordMatcher.stemOf('дрони'), 'дрон');
      expect(KeywordMatcher.stemOf('сила'), 'сил');
    });

    test('also cuts к/г/х, which alternate in the locative case', () {
      // зенітка -> у зенітці, ставка -> у ставці.
      expect(KeywordMatcher.stemOf('зенітка'), 'зеніт');
      expect(KeywordMatcher.stemOf('ставка'), 'став');
    });

    test('keeps the к when cutting it would leave another word', () {
      // «танки» -> «танк». Cutting the к as well gives «тан», which sits
      // inside «стан» — a word every second alert contains.
      expect(KeywordMatcher.stemOf('танки'), 'танк');
      expect(KeywordMatcher.stemOf('Танки'), 'танк');
    });

    test('«танки» matches its own forms and not «стан»', () {
      final matcher = KeywordMatcher(['Танки']);
      for (final text in [
        'Танки',
        'у танках',
        'над танками',
        'колона танків',
      ]) {
        expect(matcher.match(text), ['Танки'], reason: text);
      }
      expect(matcher.match('стан тривоги'), isEmpty);
      expect(matcher.match('тане сніг'), isEmpty);
    });

    test('leaves a keyword that already ends in a consonant alone', () {
      for (final keyword in [
        'шахед',
        'дрон',
        'Київ',
        'танк',
        'ціль',
        'вибух',
      ]) {
        expect(
          KeywordMatcher.stemOf(keyword),
          KeywordMatcher.normalize(keyword),
          reason: keyword,
        );
      }
    });

    test('typing the stem yourself always wins over the automatic guess', () {
      // "перемог" ends in a consonant, so no ending was removed and the
      // alternation rule never fires.
      expect(KeywordMatcher.stemOf('перемог'), 'перемог');
    });

    test('trims adjective endings', () {
      expect(KeywordMatcher.stemOf('балістичний'), 'балістичн');
      expect(KeywordMatcher.stemOf('балістичній'), 'балістичн');
      expect(KeywordMatcher(['балістичний']).match('балістична ракета'), [
        'балістичний',
      ]);
    });

    test('never touches a multi-word phrase', () {
      expect(KeywordMatcher.stemOf('балістика на'), 'балістика на');
      expect(
        KeywordMatcher(['балістика на']).match('увага балістика\nна Київ'),
        ['балістика на'],
      );
    });

    test('refuses to stem down to something that matches everything', () {
      // Nothing is cut when too little would be left.
      expect(KeywordMatcher.stemOf('оса'), 'оса');
      expect(KeywordMatcher.stemOf('ті'), 'ті');
    });

    test(
      'isStemmed reports whether the search term differs from the input',
      () {
        expect(KeywordMatcher.isStemmed('зенітка'), isTrue);
        expect(KeywordMatcher.isStemmed('шахед'), isFalse);
        expect(KeywordMatcher.isStemmed('балістика на'), isFalse);
      },
    );

    test('exclusions are stemmed the same way', () {
      final matcher = KeywordMatcher(['шахед', '-збито']);
      expect(matcher.match('шахед над містом'), ['шахед']);
      // "збито" -> "збит", so declined forms suppress the alert too.
      expect(matcher.match('шахед збитий над містом'), isEmpty);
      expect(matcher.match('збита ціль, шахед'), isEmpty);
    });
  });

  group('KeywordMatcher.sanitize', () {
    test('drops blanks and case-insensitive duplicates, keeping order', () {
      expect(
        KeywordMatcher.sanitize(['Шахед', ' ', 'шахед', 'ШАХЕД', 'Київ']),
        ['Шахед', 'Київ'],
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
