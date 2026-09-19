import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tg_alert_monitor/core/storage/keyword_sound_store.dart';

void main() {
  late Directory root;
  late KeywordSoundStore store;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('kw_sounds_test');
    store = KeywordSoundStore(Directory('${root.path}/keyword_sounds'));
  });

  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  /// Stands in for a synthesised .wav: the store only cares that it is there
  /// and not empty.
  Future<File> generate(String keyword, {String? phrase}) async {
    final file = await store.prepare(keyword);
    await file.writeAsBytes(const [1, 2, 3]);
    await store.writePhrase(keyword, phrase ?? 'Увага! $keyword');
    return file;
  }

  test('a keyword without a sound reads back as nothing', () async {
    expect(await store.read('Київ'), isNull);
    expect(await store.soundForMatch(['Київ']), isNull);
    expect(await store.withSound(['Київ']), isEmpty);
  });

  test('a generated sound comes back with the phrase it says', () async {
    await generate('Київ', phrase: 'Увага! Київ. Київ');

    final sound = await store.read('Київ');
    expect(sound, isNotNull);
    expect(sound!.phrase, 'Увага! Київ. Київ');
    expect(await sound.file.exists(), isTrue);
  });

  test('case and spacing do not hide a keyword\'s sound', () async {
    await generate('Київ');

    // The keyword list keeps what the owner typed, and they retype it.
    expect(await store.read('  київ '), isNotNull);
    expect(await store.soundForMatch(['КИЇВ']), isNotNull);
  });

  test('two keywords never share a file', () async {
    await generate('Київ');
    await generate('шахед');

    expect(
      store.audioFileFor('Київ').path,
      isNot(store.audioFileFor('шахед').path),
    );
    expect(await store.withSound(['Київ', 'шахед']), {'Київ', 'шахед'});
  });

  test('the first matched keyword with a sound is the one that speaks', () async {
    await generate('шахед');

    // Keywords arrive in the order the owner listed them.
    final chosen = await store.soundForMatch(['балістика', 'шахед']);
    expect(chosen?.path, store.audioFileFor('шахед').path);
  });

  test('an empty file is not playable and falls back to the siren', () async {
    final file = await store.prepare('Київ');
    await file.writeAsBytes(const []);

    expect(await store.read('Київ'), isNull);
    expect(await store.soundForMatch(['Київ']), isNull);
  });

  test('removing a keyword\'s sound takes its phrase with it', () async {
    await generate('Київ');
    await store.remove('Київ');

    expect(await store.read('Київ'), isNull);
    expect(await store.audioFileFor('Київ').exists(), isFalse);
    expect(store.directory.listSync(), isEmpty);
  });

  test('pruning drops sounds of keywords that are gone', () async {
    await generate('Київ');
    await generate('шахед');

    await store.prune(['шахед']);

    expect(await store.read('Київ'), isNull);
    expect(await store.read('шахед'), isNotNull);
  });

  test('pruning an empty directory is not an error', () async {
    await store.prune(['шахед']);
    expect(await store.read('шахед'), isNull);
  });
}
