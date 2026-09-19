/// Case-insensitive substring matching of keywords against message text.
///
/// Decision R7 in the spec: plain substrings, no regular expressions. Ukrainian
/// word forms (`шахед`, `шахеди`, `шахедів`) are all covered by one stem.
library;

/// A keyword prefixed with `-` acts as an exclusion: if it occurs in the text,
/// the message never matches.
const String exclusionPrefix = '-';

class _Keyword {
  const _Keyword(this.original, this.pattern);

  /// As the owner typed it — used for display and for the hashtag.
  final String original;

  /// What is actually searched for: the stem, so declined forms match.
  final String pattern;
}

class KeywordMatcher {
  KeywordMatcher(Iterable<String> keywords)
    : _includes = <_Keyword>[],
      _excludes = <_Keyword>[] {
    for (final raw in keywords) {
      final trimmed = raw.trim();
      final isExclusion =
          trimmed.startsWith(exclusionPrefix) && trimmed.length > 1;
      final body = isExclusion ? trimmed.substring(1) : trimmed;
      final pattern = stemOf(body);
      if (pattern.isEmpty) continue;
      (isExclusion ? _excludes : _includes).add(_Keyword(body.trim(), pattern));
    }
  }

  final List<_Keyword> _includes;
  final List<_Keyword> _excludes;

  // Zero-width space, ZWNJ, ZWJ and the BOM / zero-width no-break space.
  static final RegExp _zeroWidth = RegExp('[\u200B-\u200D\uFEFF]');
  static final RegExp _whitespace = RegExp(r'\s+');

  /// Lowercases, strips zero-width characters and collapses whitespace runs so
  /// that a keyword still matches text broken across lines.
  static String normalize(String value) => value
      .replaceAll(_zeroWidth, '')
      .toLowerCase()
      .replaceAll(_whitespace, ' ')
      .trim();

  // Ukrainian inflection, handled where it is free: the stem is derived once,
  // when the keyword list changes, so matching still costs one substring scan
  // per keyword and nothing extra per message.
  static const String _vowels = 'аяуюеєиіїо';

  /// Consonants that alternate before the locative ending: зеніт*к*а but
  /// у зеніт*ц*і. Cutting the stem before them covers both.
  static const String _alternating = 'кгх';

  /// Shortest stem worth searching for; below this a stem matches far too much.
  static const int _minStemLength = 3;

  /// Same, for the к/г/х cut — one character longer, deliberately.
  ///
  /// Dropping an ending only removes grammar. Dropping the consonant in front
  /// of it removes part of the word itself, and on a short word that lands on
  /// a different word entirely: `танки` -> `танк` is the one wanted, `тан`
  /// (which sits inside «стан») is not. `ставка` -> `став` is still four
  /// characters, so the cases the rule exists for keep working.
  static const int _minStemBeforeAlternation = 4;

  /// The substring actually searched for a given keyword.
  ///
  /// `зенітка` becomes `зеніт`, which matches «на зенітку», «у зенітці» and
  /// «над зеніткою». A keyword that already ends in a consonant is left alone,
  /// so typing the stem yourself always wins over the automatic guess.
  ///
  /// Multi-word keywords are never stemmed: `балістика на` is a phrase, and
  /// trimming its last word would change what it means.
  static String stemOf(String keyword) {
    var stem = normalize(keyword);
    if (stem.isEmpty || stem.contains(' ')) return stem;

    // Adjectives: балістичний -> балістичн, covering -а/-е/-і as well.
    if (stem.length >= _minStemLength + 2 &&
        (stem.endsWith('ий') || stem.endsWith('ій'))) {
      return stem.substring(0, stem.length - 2);
    }

    if (!_vowels.contains(stem[stem.length - 1])) return stem;
    if (stem.length - 1 < _minStemLength) return stem;
    stem = stem.substring(0, stem.length - 1);

    // Only after an ending was removed does the alternation matter.
    if (_alternating.contains(stem[stem.length - 1]) &&
        stem.length - 1 >= _minStemBeforeAlternation) {
      stem = stem.substring(0, stem.length - 1);
    }
    return stem;
  }

  /// True when [keyword] is searched for as something shorter than typed, so
  /// the UI can show what is really being matched.
  static bool isStemmed(String keyword) =>
      stemOf(keyword) != normalize(keyword);

  bool get isEmpty => _includes.isEmpty;
  bool get isNotEmpty => _includes.isNotEmpty;

  /// All keywords found in [text], in the order they were configured.
  /// Returns an empty list when nothing matches or an exclusion fires.
  List<String> match(String text) {
    if (_includes.isEmpty) return const <String>[];
    final haystack = normalize(text);
    if (haystack.isEmpty) return const <String>[];
    for (final ex in _excludes) {
      if (haystack.contains(ex.pattern)) return const <String>[];
    }
    final hits = <String>[];
    for (final kw in _includes) {
      if (haystack.contains(kw.pattern)) hits.add(kw.original);
    }
    return hits;
  }

  /// Removes blanks and case-insensitive duplicates, preserving order.
  static List<String> sanitize(Iterable<String> keywords) {
    final seen = <String>{};
    final out = <String>[];
    for (final raw in keywords) {
      final trimmed = raw.trim();
      if (trimmed.isEmpty) continue;
      if (!seen.add(normalize(trimmed))) continue;
      out.add(trimmed);
    }
    return out;
  }
}
