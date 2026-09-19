/// One keyword's own alert sound: generate it, listen to it, delete it.
///
/// Opened from the keyword chip on the home screen. Everything here happens in
/// the UI isolate — the service only ever plays the file this screen leaves
/// behind.
library;

import 'dart:async';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';

import '../../core/audio/keyword_voice.dart';
import '../../core/storage/keyword_sound_store.dart';
import '../../l10n/app_localizations.dart';

/// Shows the sheet. Returns true when the keyword's sound changed, so the
/// caller can repaint its chips.
Future<bool> showKeywordSoundSheet({
  required BuildContext context,
  required KeywordSoundStore store,
  required String keyword,
}) async {
  final changed = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    builder: (_) => Padding(
      // Leaves room for the keyboard while the phrase is being edited.
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: KeywordSoundSheet(store: store, keyword: keyword),
    ),
  );
  return changed ?? false;
}

class KeywordSoundSheet extends StatefulWidget {
  const KeywordSoundSheet({
    super.key,
    required this.store,
    required this.keyword,
    this.voice,
  });

  final KeywordSoundStore store;
  final String keyword;

  /// Injectable for tests; the real one talks to the phone's TTS engine.
  final KeywordVoice? voice;

  @override
  State<KeywordSoundSheet> createState() => _KeywordSoundSheetState();
}

class _KeywordSoundSheetState extends State<KeywordSoundSheet> {
  L get l => L.of(context);

  late final KeywordVoice _voice = widget.voice ?? KeywordVoice();
  final _phrase = TextEditingController();
  AudioPlayer? _player;

  KeywordSound? _sound;
  bool _loading = true;
  bool _busy = false;
  bool _changed = false;
  String? _error;

  /// Null until the check has run: "no Ukrainian voice" is a warning worth
  /// showing, and "not checked yet" must not look like it.
  bool? _voiceInstalled;

  /// Engine and language of the sound just generated. The answer to "why does
  /// it read the word in English", which is otherwise invisible.
  String? _voiceUsed;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    _phrase.dispose();
    _player?.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final sound = await widget.store.read(widget.keyword);
    if (!mounted) return;
    setState(() {
      _sound = sound;
      _loading = false;
    });
    // Default phrase only once the existing one is known, so reopening the
    // sheet shows what the sound actually says.
    _phrase.text = sound?.phrase ?? l.keywordSoundPhraseDefault(widget.keyword);
    final installed = await _voice.supports(_ukrainian);
    if (!mounted) return;
    setState(() => _voiceInstalled = installed);
  }

  static const String _ukrainian = 'uk-UA';

  /// Ukrainian for a Cyrillic phrase, the app's language otherwise. The
  /// keywords of an air-raid channel are Ukrainian whatever language the phone
  /// itself is set to.
  String get _language => KeywordVoice.languageFor(
    _phrase.text,
    fallback: switch (Localizations.localeOf(context).languageCode) {
      'uk' => _ukrainian,
      'en' => 'en-US',
      final other => other,
    },
  );

  Future<void> _generate() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    final phrase = _phrase.text.trim();
    try {
      final file = await widget.store.prepare(widget.keyword);
      await _voice.synthesize(
        phrase: phrase,
        file: file,
        preferred: _language,
      );
      await widget.store.writePhrase(widget.keyword, phrase);
      final sound = await widget.store.read(widget.keyword);
      if (!mounted) return;
      setState(() {
        _sound = sound;
        _voiceUsed = _voice.voice?.toString();
        _changed = true;
        _busy = false;
      });
      await _play();
    } on VoiceException catch (error) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = _message(error);
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = '$error';
      });
    }
  }

  /// Exactly as the alert will sound: same file, same alarm stream.
  Future<void> _play() async {
    final sound = _sound;
    if (sound == null) return;
    try {
      final player = _player ??= AudioPlayer();
      await player.setAudioContext(
        AudioContext(
          android: const AudioContextAndroid(
            usageType: AndroidUsageType.alarm,
            contentType: AndroidContentType.sonification,
            audioFocus: AndroidAudioFocus.gainTransientMayDuck,
          ),
        ),
      );
      await player.play(DeviceFileSource(sound.file.path));
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = '$error');
    }
  }

  Future<void> _delete() async {
    await widget.store.remove(widget.keyword);
    if (!mounted) return;
    setState(() {
      _sound = null;
      _changed = true;
      _error = null;
    });
  }

  String _message(VoiceException error) => switch (error.failure) {
    VoiceFailure.noEngine => l.keywordSoundErrorEngine,
    VoiceFailure.timedOut => l.keywordSoundErrorTimeout,
    VoiceFailure.empty => l.keywordSoundErrorEmpty,
  };

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final sound = _sound;

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.record_voice_over, color: scheme.primary),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    l.keywordSoundTitle(widget.keyword),
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                IconButton(
                  tooltip: l.close,
                  icon: const Icon(Icons.close),
                  onPressed: () => Navigator.pop(context, _changed),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(l.keywordSoundHelp, style: const TextStyle(fontSize: 12)),
            const SizedBox(height: 12),
            if (_loading)
              const Center(child: CircularProgressIndicator())
            else ...[
              TextField(
                controller: _phrase,
                enabled: !_busy,
                maxLines: 2,
                minLines: 1,
                decoration: InputDecoration(
                  labelText: l.keywordSoundPhrase,
                  border: const OutlineInputBorder(),
                  isDense: true,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                sound == null
                    ? l.keywordSoundNone
                    : l.keywordSoundReady(sound.phrase),
                style: TextStyle(
                  fontSize: 12,
                  color: sound == null ? Theme.of(context).hintColor : null,
                ),
              ),
              if (_voiceUsed != null)
                Text(
                  l.keywordSoundVoice(_voiceUsed!),
                  style: TextStyle(
                    fontSize: 11,
                    color: Theme.of(context).hintColor,
                  ),
                ),
              if (_voiceInstalled == false) ...[
                const SizedBox(height: 8),
                Text(
                  l.keywordSoundNoVoice,
                  style: TextStyle(fontSize: 12, color: scheme.error),
                ),
              ],
              if (_error != null) ...[
                const SizedBox(height: 8),
                Text(
                  _error!,
                  style: TextStyle(fontSize: 12, color: scheme.error),
                ),
              ],
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: _busy ? null : _generate,
                      icon: _busy
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.graphic_eq, size: 18),
                      label: Text(
                        _busy
                            ? l.keywordSoundWorking
                            : (sound == null
                                  ? l.keywordSoundGenerate
                                  : l.keywordSoundRegenerate),
                      ),
                    ),
                  ),
                  if (sound != null) ...[
                    const SizedBox(width: 8),
                    IconButton.outlined(
                      tooltip: l.keywordSoundPlay,
                      onPressed: _busy ? null : _play,
                      icon: const Icon(Icons.play_arrow),
                    ),
                    const SizedBox(width: 4),
                    IconButton.outlined(
                      tooltip: l.keywordSoundDelete,
                      onPressed: _busy ? null : _delete,
                      icon: Icon(Icons.delete_outline, color: scheme.error),
                    ),
                  ],
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}
