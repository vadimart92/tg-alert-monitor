/// Per-keyword alert sounds, on disk.
///
/// A sound is generated in the UI isolate and played in the service isolate,
/// so the two ends need somewhere to meet. That somewhere is the filesystem
/// rather than SharedPreferences: the audio is a file already, and a file the
/// service can simply stat is always current — there is no cache to reload and
/// nothing to keep in step with the keyword list.
///
/// One keyword owns two files, named after a hash of the keyword:
///
/// ```
/// <support>/keyword_sounds/kw_<hash>.wav    what is played
/// <support>/keyword_sounds/kw_<hash>.json   {"keyword": …, "phrase": …}
/// ```
///
/// The sidecar exists because the hash is one-way: without it the app could
/// play a sound but never tell you what it says or which word it belongs to.
library;

import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../matcher/keyword_matcher.dart';

/// One generated sound, as read back from disk.
class KeywordSound {
  const KeywordSound({
    required this.keyword,
    required this.phrase,
    required this.file,
  });

  /// As the owner typed it in the keyword list.
  final String keyword;

  /// What the voice says. Usually built from the keyword, but editable: the
  /// searched word and the spoken word are not always the same thing.
  final String phrase;

  final File file;

  Map<String, dynamic> toJson() => {'keyword': keyword, 'phrase': phrase};
}

class KeywordSoundStore {
  KeywordSoundStore(this.directory);

  /// Lives next to the TDLib database and the match log.
  static const String directoryName = 'keyword_sounds';

  static const String _prefix = 'kw_';
  static const String _audioExtension = '.wav';
  static const String _metaExtension = '.json';

  final Directory directory;

  /// The real location, in either isolate.
  static Future<KeywordSoundStore> open() async {
    final support = await getApplicationSupportDirectory();
    return KeywordSoundStore(
      Directory('${support.path}/$directoryName'),
    );
  }

  /// A keyword's audio file, whether or not it has been generated yet.
  ///
  /// Keyed by the normalised keyword, so a sound made for «Чайки» is still
  /// found after the owner retypes the word as «чайки».
  File audioFileFor(String keyword) =>
      File('${directory.path}/${_stem(keyword)}$_audioExtension');

  File _metaFileFor(String keyword) =>
      File('${directory.path}/${_stem(keyword)}$_metaExtension');

  /// The sound of [keyword], or `null` when it has none.
  Future<KeywordSound?> read(String keyword) async {
    final audio = audioFileFor(keyword);
    if (!await _isPlayable(audio)) return null;
    var phrase = keyword;
    try {
      final meta = _metaFileFor(keyword);
      if (await meta.exists()) {
        final decoded = jsonDecode(await meta.readAsString());
        if (decoded is Map && decoded['phrase'] is String) {
          phrase = decoded['phrase'] as String;
        }
      }
    } catch (_) {
      // A damaged sidecar costs the phrase, not the sound.
    }
    return KeywordSound(keyword: keyword, phrase: phrase, file: audio);
  }

  /// Which of [keywords] have a sound. One stat per keyword, no I/O beyond it.
  Future<Set<String>> withSound(Iterable<String> keywords) async {
    final out = <String>{};
    for (final keyword in keywords) {
      if (await _isPlayable(audioFileFor(keyword))) out.add(keyword);
    }
    return out;
  }

  /// The file to play for a match, or `null` to fall back to the siren.
  ///
  /// The first matched keyword that has a sound wins, and keywords arrive in
  /// the order the owner listed them — so the word at the top of the list is
  /// the one that gets to speak when a message matches several.
  Future<File?> soundForMatch(Iterable<String> keywords) async {
    for (final keyword in keywords) {
      final audio = audioFileFor(keyword);
      if (await _isPlayable(audio)) return audio;
    }
    return null;
  }

  /// A zero-byte file is what a failed synthesis leaves behind, and playing it
  /// would swallow the alert entirely.
  static Future<bool> _isPlayable(File file) async {
    try {
      return await file.exists() && await file.length() > 0;
    } catch (_) {
      return false;
    }
  }

  /// Creates the directory and returns where [keyword]'s audio must be written.
  ///
  /// The caller (the TTS engine) writes the file itself, which is why this
  /// hands back a path rather than taking bytes.
  Future<File> prepare(String keyword) async {
    await directory.create(recursive: true);
    return audioFileFor(keyword);
  }

  /// Records what the generated audio says. Called after a successful synthesis.
  Future<void> writePhrase(String keyword, String phrase) async {
    await directory.create(recursive: true);
    await _metaFileFor(keyword).writeAsString(
      jsonEncode(
        KeywordSound(
          keyword: keyword,
          phrase: phrase,
          file: audioFileFor(keyword),
        ).toJson(),
      ),
    );
  }

  /// Drops a keyword's sound; the alert falls back to the siren again.
  Future<void> remove(String keyword) async {
    for (final file in [audioFileFor(keyword), _metaFileFor(keyword)]) {
      try {
        if (await file.exists()) await file.delete();
      } catch (_) {
        // Nothing to do about it, and nothing depends on it either.
      }
    }
  }

  /// Deletes sounds of keywords that are no longer in [keywords].
  ///
  /// Without this a removed keyword leaves its audio behind forever, and the
  /// owner has no way of seeing the orphan, let alone deleting it.
  Future<void> prune(Iterable<String> keywords) async {
    if (!await directory.exists()) return;
    final live = {for (final keyword in keywords) _stem(keyword)};
    await for (final entity in directory.list()) {
      if (entity is! File) continue;
      final name = entity.uri.pathSegments.last;
      if (!name.startsWith(_prefix)) continue;
      final stem = name.split('.').first;
      if (live.contains(stem)) continue;
      try {
        await entity.delete();
      } catch (_) {
        // Best effort: an orphan that survives is harmless.
      }
    }
  }

  /// `kw_<hash>` — an ASCII name for a keyword that is usually Cyrillic.
  ///
  /// Hashed rather than transliterated: the name has to be stable, unique and
  /// legal on every filesystem, and none of that survives «балістика на» being
  /// turned into a filename directly.
  static String _stem(String keyword) =>
      '$_prefix${_hash(KeywordMatcher.normalize(keyword))}';

  /// 32-bit FNV-1a over the UTF-16 code units, as eight hex digits.
  ///
  /// Not cryptography — just a short, stable name. A collision would mean two
  /// keywords sharing one sound; with the dozens of keywords this app holds
  /// that is around one chance in a hundred billion.
  static String _hash(String value) {
    var hash = 0x811c9dc5;
    for (final unit in value.codeUnits) {
      hash = ((hash ^ unit) * 0x01000193) & 0xFFFFFFFF;
    }
    return hash.toRadixString(16).padLeft(8, '0');
  }
}
