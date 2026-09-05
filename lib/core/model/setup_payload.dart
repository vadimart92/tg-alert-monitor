/// The thing a QR code carries when one phone hands its setup to another.
///
/// Pure Dart, so both the encoder in the UI and the decoder in the scanner are
/// covered by ordinary tests.
library;

import 'dart:convert';
import 'dart:io';

/// Raised for anything that is not a payload this build understands.
class SetupPayloadError implements Exception {
  SetupPayloadError(this.message);
  final String message;

  @override
  String toString() => 'SetupPayloadError: $message';
}

/// One monitored channel, addressed the only way another account can resolve.
///
/// A chat id is meaningless on a second account: TDLib will not look up a
/// supergroup the user has never seen. A public `@username` it can resolve
/// and join, which is why a private channel cannot travel in the QR at all.
class SetupChannel {
  const SetupChannel({required this.username, this.title = ''});

  /// Without the leading `@`.
  final String username;

  /// Only for the confirmation screen; the username is what is resolved.
  final String title;

  Map<String, dynamic> toJson() => {
    'u': username,
    if (title.isNotEmpty) 't': title,
  };

  static SetupChannel fromJson(Map<String, dynamic> json) => SetupChannel(
    username: (json['u'] as String? ?? '').trim(),
    title: json['t'] as String? ?? '',
  );

  @override
  bool operator ==(Object other) =>
      other is SetupChannel &&
      other.username == username &&
      other.title == title;

  @override
  int get hashCode => Object.hash(username, title);

  @override
  String toString() => '@$username';
}

/// Everything the receiving phone needs to end up watching the same thing.
class SetupPayload {
  const SetupPayload({
    this.folderName = '',
    this.channels = const <SetupChannel>[],
    this.keywords = const <String>[],
    this.maxAgeMinutes = 10,
  });

  /// Marks our own QR codes and pins the format. A future change bumps the
  /// digit, so an old build says "this is newer than me" instead of crashing
  /// on a field it does not know.
  static const String prefix = 'tgam1:';

  /// Refuse to render anything a phone camera will struggle with. A QR at
  /// error-correction level M tops out near this many bytes, and past roughly
  /// half of it the modules get too fine to scan across a room.
  static const int maxEncodedLength = 1200;

  final String folderName;
  final List<SetupChannel> channels;
  final List<String> keywords;
  final int maxAgeMinutes;

  bool get isEmpty => channels.isEmpty && keywords.isEmpty;

  Map<String, dynamic> toJson() => {
    'f': folderName,
    'c': [for (final channel in channels) channel.toJson()],
    'k': keywords,
    'a': maxAgeMinutes,
  };

  static SetupPayload fromJson(Map<String, dynamic> json) => SetupPayload(
    folderName: json['f'] as String? ?? '',
    channels: [
      for (final item in (json['c'] as List? ?? const []))
        if (item is Map) SetupChannel.fromJson(Map<String, dynamic>.from(item)),
    ],
    keywords: [for (final k in (json['k'] as List? ?? const [])) k.toString()],
    maxAgeMinutes: (json['a'] as num?)?.toInt() ?? 10,
  );

  /// `tgam1:` followed by base64url of the gzipped JSON.
  ///
  /// Gzip roughly halves it — Cyrillic keywords cost two bytes a character in
  /// UTF-8, and the JSON keys repeat — which is the difference between a QR
  /// that scans at arm's length and one that does not.
  String encode() {
    final json = utf8.encode(jsonEncode(toJson()));
    final zipped = gzip.encode(json);
    return '$prefix${base64Url.encode(zipped)}';
  }

  /// Parses [raw] as scanned from a QR code.
  ///
  /// Throws [SetupPayloadError] for every other QR code in the world, which is
  /// what the scanner shows the user instead of silently doing nothing.
  static SetupPayload decode(String raw) {
    final trimmed = raw.trim();
    if (!trimmed.startsWith(prefix)) {
      throw SetupPayloadError('not a TG Alert Monitor code');
    }

    final Object? decoded;
    try {
      final zipped = base64Url.decode(trimmed.substring(prefix.length));
      decoded = jsonDecode(utf8.decode(gzip.decode(zipped)));
    } catch (error) {
      throw SetupPayloadError('damaged code: $error');
    }

    if (decoded is! Map) throw SetupPayloadError('expected a JSON object');
    return SetupPayload.fromJson(Map<String, dynamic>.from(decoded));
  }
}
