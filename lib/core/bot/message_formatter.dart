/// Builds the HTML payload posted to the target channel.
library;

/// Formats a keyword hit for `sendMessage` with `parse_mode: HTML`.
class MessageFormatter {
  /// Hard limit of the Bot API `text` field.
  static const int telegramLimit = 4096;

  /// Product limit for the quoted message body (spec 7.9).
  static const int bodyLimit = 3500;

  static const String ellipsis = '…';

  /// Escapes the three characters that matter for Telegram's HTML parse mode.
  ///
  /// `&` must go first, otherwise the `&` of `&lt;` gets escaped again.
  static String escapeHtml(String value) => value
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;');

  // Telegram recognises a hashtag as `#` followed by letters, digits or
  // underscores; a space or a hyphen ends the tag, so those become underscores.
  static final RegExp _tagSeparators = RegExp(
    r'[\s\-\u2010-\u2015]+',
    unicode: true,
  );
  static final RegExp _nonTagCharacters = RegExp(
    r'[^\p{L}\p{N}_]+',
    unicode: true,
  );
  static final RegExp _repeatedUnderscores = RegExp(r'_{2,}');
  static final RegExp _edgeUnderscores = RegExp(r'^_+|_+$');
  static final RegExp _noLetters = RegExp(r'^[\p{N}_]+$', unicode: true);

  /// Renders [keyword] as a Telegram hashtag, or `null` when nothing taggable
  /// is left.
  ///
  /// `тест-ключ` becomes `#тест_ключ` and `балістика на` becomes
  /// `#балістика_на`, because Telegram would otherwise cut the tag at the
  /// hyphen or the space. A keyword made only of digits or punctuation cannot
  /// be a tag at all, and the caller falls back to plain text.
  static String? hashtag(String keyword) {
    final tag = keyword
        .trim()
        .replaceAll(_tagSeparators, '_')
        .replaceAll(_nonTagCharacters, '')
        .replaceAll(_repeatedUnderscores, '_')
        .replaceAll(_edgeUnderscores, '');
    if (tag.isEmpty || _noLetters.hasMatch(tag)) return null;
    return '#$tag';
  }

  /// The keyword line: hashtags where possible, escaped plain text otherwise.
  ///
  /// Tags make the target channel searchable per keyword.
  static String renderKeywords(List<String> keywords) =>
      [for (final keyword in keywords) hashtag(keyword) ?? escapeHtml(keyword)]
          .join(' ');

  static String _twoDigits(int value) => value.toString().padLeft(2, '0');

  /// `HH:mm` in local time.
  static String formatTime(DateTime time) =>
      '${_twoDigits(time.hour)}:${_twoDigits(time.minute)}';

  /// Never splits a surrogate pair, so an emoji is dropped whole.
  static int _safeCut(String value, int limit) {
    if (limit >= value.length) return value.length;
    if (limit <= 0) return 0;
    final unit = value.codeUnitAt(limit - 1);
    final isHighSurrogate = unit >= 0xD800 && unit <= 0xDBFF;
    return isHighSurrogate ? limit - 1 : limit;
  }

  /// Assembles the post.
  ///
  /// The result is guaranteed to be at most [telegramLimit] characters: the
  /// body is trimmed to fit whatever the header and footer leave over, and the
  /// trimming accounts for the growth caused by HTML escaping.
  static String format({
    required String chatTitle,
    required List<String> keywords,
    required String text,
    required String link,
    required DateTime time,
  }) {
    final header =
        '🔔 <b>${escapeHtml(chatTitle)}</b>\n'
        '🔑 ${renderKeywords(keywords)}\n\n';
    final footer = link.isEmpty
        ? '\n\n${formatTime(time)}'
        : '\n\n<a href="${escapeHtml(link)}">Відкрити оригінал</a>'
              ' · ${formatTime(time)}';

    final budget = _min(
      bodyLimit,
      telegramLimit - header.length - footer.length,
    );
    if (budget <= 0) {
      // Pathological title/keywords: keep the header, drop the body.
      final headerOnly = header.trimRight() + footer;
      return headerOnly.length <= telegramLimit
          ? headerOnly
          : headerOnly.substring(0, _safeCut(headerOnly, telegramLimit));
    }

    final fullyEscaped = escapeHtml(text);
    if (fullyEscaped.length <= budget) return '$header$fullyEscaped$footer';

    // Escaping expands text by an amount that depends on the characters
    // present (`&` becomes five characters), so the largest prefix that fits
    // cannot be computed arithmetically — find it by bisection instead.
    final bodyBudget = budget - ellipsis.length;
    var low = 0;
    var high = text.length;
    while (low < high) {
      final candidate = _safeCut(text, (low + high + 1) ~/ 2);
      if (candidate <= low) break;
      if (escapeHtml(text.substring(0, candidate)).length <= bodyBudget) {
        low = candidate;
      } else {
        high = candidate - 1;
      }
    }

    final body = escapeHtml(text.substring(0, _safeCut(text, low)));
    return '$header$body$ellipsis$footer';
  }

  static final RegExp _anchorTag = RegExp(r'<a href="([^"]*)">([^<]*)</a>');
  static final RegExp _otherTags = RegExp(r'</?[a-zA-Z]+>');

  /// Converts our own HTML rendering back to plain text.
  ///
  /// Used when the copy is posted through the user session rather than a bot,
  /// where the text is sent unformatted and raw tags would be visible.
  static String stripHtml(String html) => html
      .replaceAllMapped(_anchorTag, (m) => '${m[2]}: ${m[1]}')
      .replaceAll(_otherTags, '')
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&amp;', '&');

  static int _min(int a, int b) => a < b ? a : b;
}
