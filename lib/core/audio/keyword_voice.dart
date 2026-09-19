/// Turns a keyword into a spoken alert, using the phone's own TTS engine.
///
/// Runs in the UI isolate only, and only when the owner presses the button:
/// synthesis takes a second or two and needs a screen to report its failures
/// to. What the service isolate later plays is the .wav left behind, so a
/// missing or broken TTS engine can never cost anyone an alert — at worst the
/// siren sounds instead of the word.
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter_tts/flutter_tts.dart';

/// Why generating a sound did not work. Mapped to a localised sentence by the
/// UI: this file must not know which language the owner reads.
enum VoiceFailure {
  /// No TTS engine on the phone, or it refused to start.
  ///
  /// A missing *voice* is not here on purpose: the engine's default reads the
  /// phrase instead, and a sound the owner can listen to and reject is more
  /// use than an error. [KeywordVoice.supports] is what warns them.
  noEngine,

  /// Synthesis neither finished nor reported an error.
  ///
  /// Not hypothetical: when the Android engine fails mid-utterance the plugin
  /// never completes its future, so a timeout is the only way back.
  timedOut,

  /// It said it worked and produced nothing playable.
  empty,
}

class VoiceException implements Exception {
  const VoiceException(this.failure, [this.detail]);

  final VoiceFailure failure;
  final String? detail;

  @override
  String toString() => 'VoiceException(${failure.name}, $detail)';
}

class KeywordVoice {
  KeywordVoice({FlutterTts? tts}) : _tts = tts ?? FlutterTts();

  /// Android's normal speaking rate: the plugin maps 1.0 to 0.5 so that the
  /// same number means the same speed on every platform.
  static const double speechRate = 0.5;

  /// Generous: a cold TTS engine has to start a service and may have to load a
  /// voice, and the phrase is only a few words long.
  static const Duration timeout = Duration(seconds: 25);

  /// Waiting for one engine to report itself ready. Shorter than [timeout]:
  /// several may be tried in a row before anything is spoken.
  static const Duration engineTimeout = Duration(seconds: 8);

  final FlutterTts _tts;

  /// Resolutions already paid for, by wanted language tag. Each miss costs a
  /// round of starting TTS services, and the sheet asks the same question
  /// twice: once to warn, once to generate.
  final Map<String, VoiceChoice?> _resolved = <String, VoiceChoice?>{};

  /// What the last [synthesize] actually spoke with.
  VoiceChoice? get voice => _lastVoice;
  VoiceChoice? _lastVoice;

  /// Writes [phrase] to [file] as a .wav. Throws [VoiceException] on failure.
  ///
  /// [preferred] is a BCP-47 tag such as `uk-UA`. When the phone has no voice
  /// for it the engine's own default is used instead — an English voice
  /// reading a Ukrainian word is poor, but it is a sound the owner can listen
  /// to and judge, which a refusal is not.
  Future<void> synthesize({
    required String phrase,
    required File file,
    String? preferred,
  }) async {
    final text = phrase.trim();
    if (text.isEmpty) throw const VoiceException(VoiceFailure.empty);

    try {
      final voice = preferred == null ? null : await _resolve(preferred);
      _lastVoice = voice;
      if (voice != null) {
        if (voice.engine != null) await _tts.setEngine(voice.engine!);
        await _tts.setLanguage(voice.language);
      }
      await _tts.awaitSynthCompletion(true);
      await _tts.setSpeechRate(speechRate);
      await _tts.setPitch(1);
    } catch (error) {
      throw VoiceException(VoiceFailure.noEngine, '$error');
    }

    // A leftover from an earlier attempt would otherwise pass the size check
    // below even if this synthesis wrote nothing at all.
    try {
      if (await file.exists()) await file.delete();
    } catch (_) {
      // If it cannot be deleted it will simply be overwritten.
    }

    try {
      await _tts
          .synthesizeToFile(text, file.path, true)
          .timeout(timeout);
    } on TimeoutException {
      throw const VoiceException(VoiceFailure.timedOut);
    } catch (error) {
      throw VoiceException(VoiceFailure.noEngine, '$error');
    }

    // The Android engine reports success before the file descriptor is always
    // flushed, and reports nothing at all for some failures.
    if (!await file.exists() || await file.length() == 0) {
      throw const VoiceException(VoiceFailure.empty);
    }
  }

  /// An engine and language that can speak [preferred], or `null` if nothing
  /// installed can.
  ///
  /// The phone's default engine is asked first, and every other installed one
  /// after it. That second half is not theoretical: the Galaxy this app was
  /// written for defaults to Samsung TTS, which has no Ukrainian at all, while
  /// Google TTS sits right next to it and does. Which engine this app speaks
  /// with is ours to choose; the phone's own default is never touched.
  Future<VoiceChoice?> _resolve(String preferred) async {
    if (preferred.isEmpty) return null;
    if (_resolved.containsKey(preferred)) return _resolved[preferred];
    final found = await _search(preferred);
    _resolved[preferred] = found;
    return found;
  }

  Future<VoiceChoice?> _search(String preferred) async {
    final onDefault = await _languageOn(preferred);
    if (onDefault != null) return VoiceChoice(null, onDefault);

    final fallback = await _defaultEngine();
    for (final engine in await _engines()) {
      if (engine == fallback) continue;
      if (!await _select(engine)) continue;
      final language = await _languageOn(preferred);
      if (language != null) return VoiceChoice(engine, language);
    }

    // Nothing anywhere: leave the plugin on the engine it started with, so the
    // phrase is at least read by the voice the owner already hears elsewhere.
    if (fallback != null) await _select(fallback);
    return null;
  }

  /// The tag the current engine speaks for [preferred], or `null`.
  Future<String?> _languageOn(String preferred) async {
    if (await _isAvailable(preferred)) return preferred;

    // `uk-UA` may be installed as `ukr`, `uk_UA` or plain `uk` depending on
    // the engine, so fall back to anything sharing the language subtag.
    final wanted = preferred.split(RegExp('[-_]')).first.toLowerCase();
    for (final tag in await _languages()) {
      if (tag.split(RegExp('[-_]')).first.toLowerCase() == wanted) return tag;
    }
    return null;
  }

  Future<bool> _isAvailable(String tag) async {
    try {
      return await _tts.isLanguageAvailable(tag) == true;
    } catch (_) {
      return false;
    }
  }

  Future<List<String>> _languages() async {
    try {
      final raw = await _tts.getLanguages;
      if (raw is List) return [for (final item in raw) '$item'];
    } catch (_) {
      // An engine that cannot list its languages still speaks its default.
    }
    return const <String>[];
  }

  Future<List<String>> _engines() async {
    try {
      final raw = await _tts.getEngines;
      if (raw is List) return [for (final item in raw) '$item'];
    } catch (_) {
      // Android 11+ hides engines from an app that does not declare the
      // TTS_SERVICE query in its manifest. This app declares it.
    }
    return const <String>[];
  }

  Future<String?> _defaultEngine() async {
    try {
      final name = await _tts.getDefaultEngine;
      return name is String && name.isNotEmpty ? name : null;
    } catch (_) {
      return null;
    }
  }

  /// Points the plugin at one engine. False when it refused to start.
  Future<bool> _select(String engine) async {
    try {
      await _tts.setEngine(engine).timeout(engineTimeout);
      return true;
    } catch (_) {
      return false;
    }
  }

  /// True when the phone can speak [preferred] with some installed engine.
  ///
  /// Used to warn before the owner generates a Ukrainian phrase in an English
  /// voice, not to block them from doing it.
  Future<bool> supports(String preferred) async =>
      (await _resolve(preferred)) != null;

  static final RegExp _cyrillic = RegExp('[Ѐ-ӿ]');

  /// Which voice a phrase should be read in.
  ///
  /// Cyrillic means Ukrainian here, whatever language the phone's menus are
  /// in: the keywords come from Ukrainian alert channels, and a Ukrainian word
  /// read by an English voice is barely a word.
  static String languageFor(String phrase, {required String fallback}) =>
      _cyrillic.hasMatch(phrase) ? 'uk-UA' : fallback;
}

/// One way of speaking: which engine, and which of its languages.
///
/// Shown in the sheet after a sound is generated. On a phone with two engines
/// installed it is the only way to tell why a word came out sounding English.
class VoiceChoice {
  const VoiceChoice(this.engine, this.language);

  /// Null means the engine the phone is already set to.
  final String? engine;

  final String language;

  @override
  String toString() => '${engine ?? "default"}/$language';
}
