/// Guards the two ways the translations can silently rot.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tg_alert_monitor/core/util/engine_strings.dart';
import 'package:tg_alert_monitor/l10n/app_localizations.dart';

/// Message keys of one `.arb`, without the `@`-prefixed metadata entries.
Set<String> _keysOf(String path) {
  final decoded = jsonDecode(File(path).readAsStringSync()) as Map;
  return {
    for (final key in decoded.keys.cast<String>())
      if (!key.startsWith('@')) key,
  };
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('the English translation covers exactly the Ukrainian template', () {
    final uk = _keysOf('lib/l10n/app_uk.arb');
    final en = _keysOf('lib/l10n/app_en.arb');

    // gen_l10n only warns about a missing translation, and the generated
    // English class then silently falls back to the Ukrainian text.
    expect(uk.difference(en), isEmpty, reason: 'missing from app_en.arb');
    expect(en.difference(uk), isEmpty, reason: 'not in app_uk.arb');
  });

  test('UkrainianEngineStrings matches app_uk.arb word for word', () async {
    // The engine cannot import `L` (it is Flutter-free by design), so its
    // Ukrainian strings are written out a second time. This is what keeps the
    // copy honest.
    final l = await L.delegate.load(const Locale('uk'));
    const engine = UkrainianEngineStrings();

    expect(engine.codeSentToTelegram, l.codeSentToTelegram);
    expect(engine.codeSentBySms, l.codeSentBySms);
    expect(engine.codeByCall, l.codeByCall);
    expect(engine.expectACall, l.expectACall);
    expect(engine.codeSentToFragment, l.codeSentToFragment);

    expect(engine.localAlertsUnavailable, l.localAlertsUnavailable);

    expect(engine.tdlibNoAnswerForward, l.tdlibNoAnswerForward);
    expect(engine.tdlibNoAnswerSend, l.tdlibNoAnswerSend);
    expect(engine.tdlibNoAnswerTargetLookup, l.tdlibNoAnswerTargetLookup);
    expect(engine.tdlibNotResponding, l.tdlibNotResponding);

    expect(engine.targetNotSet, l.targetNotSet);
    expect(engine.targetMustBeUsernameOrId, l.targetMustBeUsernameOrId);
    expect(engine.targetNotFound, l.targetNotFound);
    expect(engine.targetNotFoundCheckId, l.targetNotFoundCheckId);

    expect(engine.noRightToPost, l.noRightToPost);
    expect(engine.sourceForbidsForwarding, l.sourceForbidsForwarding);

    expect(engine.signInFirst, l.signInFirst);
    expect(engine.couldNotListChannels('X'), l.couldNotListChannels('X'));

    expect(engine.testMessageBody('12:00'), l.testMessageBody('12:00'));
    expect(engine.testMessageSent, l.testMessageSent);
  });

  test('both locales are reachable and actually differ', () async {
    final uk = await L.delegate.load(const Locale('uk'));
    final en = await L.delegate.load(const Locale('en'));

    expect(L.supportedLocales.map((locale) => locale.languageCode), [
      'en',
      'uk',
    ]);
    expect(uk.start, 'Старт');
    expect(en.start, 'Start');
    // The product name is deliberately the same in both.
    expect(en.appTitle, uk.appTitle);
  });
}
