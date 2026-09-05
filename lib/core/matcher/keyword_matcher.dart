/// Case-insensitive substring matching of keywords against message text.
///
/// Decision R7 in the spec: plain substrings, no regular expressions. Ukrainian
/// word forms (`шахед`, `шахеди`, `шахедів`) are all covered by one stem.
library;

/// A keyword prefixed with `-` acts as an exclusion: if it occurs in the text,
/// the message never matches.
const String exclusionPrefix = '-';

class _Keyword {
  const _Keyword(this.original, this.normalized);
  final String original;
  final String normalized;
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
      final normalized = normalize(body);
      if (normalized.isEmpty) continue;
      (isExclusion ? _excludes : _includes).add(
        _Keyword(body.trim(), normalized),
      );
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

  bool get isEmpty => _includes.isEmpty;
  bool get isNotEmpty => _includes.isNotEmpty;

  /// All keywords found in [text], in the order they were configured.
  /// Returns an empty list when nothing matches or an exclusion fires.
  List<String> match(String text) {
    if (_includes.isEmpty) return const <String>[];
    final haystack = normalize(text);
    if (haystack.isEmpty) return const <String>[];
    for (final ex in _excludes) {
      if (haystack.contains(ex.normalized)) return const <String>[];
    }
    final hits = <String>[];
    for (final kw in _includes) {
      if (haystack.contains(kw.normalized)) hits.add(kw.original);
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
