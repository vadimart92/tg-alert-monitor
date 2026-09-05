/// Localisation for the isolate that has no widget tree.
///
/// The service composes its ongoing notification, its alert notifications and
/// its error messages long after the UI isolate has been killed, so
/// `L.of(context)` is not available to it.
library;

import 'dart:ui';

import '../core/util/engine_strings.dart';
import 'app_localizations.dart';

/// Loads [L] for the device's language, without a [BuildContext].
///
/// Ukrainian is the fallback rather than English: this app was written for
/// Ukrainian users, and a device in some third language is far more likely to
/// belong to one of them than not.
Future<L> loadServiceStrings() {
  final device = PlatformDispatcher.instance.locale;
  final locale = L.supportedLocales.firstWhere(
    (supported) => supported.languageCode == device.languageCode,
    orElse: () => const Locale('uk'),
  );
  return L.delegate.load(locale);
}

/// Adapts [L] to the Flutter-free interface [MonitorEngine] speaks.
///
/// The engine deliberately imports nothing from Flutter, and `L` is a Flutter
/// class, so the two are bridged here rather than in the engine.
class LocalisedEngineStrings implements EngineStrings {
  const LocalisedEngineStrings(this._l);

  final L _l;

  @override
  String get codeSentToTelegram => _l.codeSentToTelegram;
  @override
  String get codeSentBySms => _l.codeSentBySms;
  @override
  String get codeByCall => _l.codeByCall;
  @override
  String get expectACall => _l.expectACall;
  @override
  String get codeSentToFragment => _l.codeSentToFragment;

  @override
  String get localAlertsUnavailable => _l.localAlertsUnavailable;

  @override
  String get tdlibNoAnswerForward => _l.tdlibNoAnswerForward;
  @override
  String get tdlibNoAnswerSend => _l.tdlibNoAnswerSend;
  @override
  String get tdlibNoAnswerTargetLookup => _l.tdlibNoAnswerTargetLookup;
  @override
  String get tdlibNotResponding => _l.tdlibNotResponding;

  @override
  String get targetNotSet => _l.targetNotSet;
  @override
  String get targetMustBeUsernameOrId => _l.targetMustBeUsernameOrId;
  @override
  String get targetNotFound => _l.targetNotFound;
  @override
  String get targetNotFoundCheckId => _l.targetNotFoundCheckId;

  @override
  String get noRightToPost => _l.noRightToPost;
  @override
  String get sourceForbidsForwarding => _l.sourceForbidsForwarding;

  @override
  String get signInFirst => _l.signInFirst;
  @override
  String couldNotListChannels(String error) => _l.couldNotListChannels(error);

  @override
  String testMessageBody(String stamp) => _l.testMessageBody(stamp);
  @override
  String get testMessageSent => _l.testMessageSent;

  @override
  String get setupNothingResolved => _l.setupNothingResolved;

  @override
  String get botUnavailable => _l.botUnavailable;
  @override
  String get matchChannelName => _l.matchChannelName;
  @override
  String get diagAlertTitle => _l.diagAlertTitle;
  @override
  String get diagAlertBody => _l.diagAlertBody;
  @override
  String diagAlertFired(String channel) => _l.diagAlertFired(channel);
  @override
  String get diagNoChats => _l.diagNoChats;
  @override
  String get diagNoMessages => _l.diagNoMessages;
  @override
  String diagForwarded(String chat) => _l.diagForwarded(chat);
}
