/// The user-facing strings [MonitorEngine] produces.
///
/// The engine imports nothing from Flutter — that is what lets it run under a
/// plain `flutter test` with fakes — so it cannot reach the generated `L`
/// localisations directly. It takes this interface instead; the service
/// isolate passes an adapter over `L`, and the default below keeps the engine
/// usable (in Ukrainian) without one.
library;

abstract interface class EngineStrings {
  /// Hints about where Telegram sent the login code.
  String get codeSentToTelegram;
  String get codeSentBySms;
  String get codeByCall;
  String get expectACall;
  String get codeSentToFragment;

  String get localAlertsUnavailable;

  String get tdlibNoAnswerForward;
  String get tdlibNoAnswerSend;
  String get tdlibNoAnswerTargetLookup;
  String get tdlibNotResponding;

  String get targetNotSet;
  String get targetMustBeUsernameOrId;
  String get targetNotFound;
  String get targetNotFoundCheckId;

  String get noRightToPost;
  String get sourceForbidsForwarding;

  String get signInFirst;
  String couldNotListChannels(String error);

  String testMessageBody(String stamp);
  String get testMessageSent;

  String get setupNothingResolved;
}

/// Ukrainian, hard-coded. The engine's default, and what the tests assert on.
///
/// Kept in step with `lib/l10n/app_uk.arb` by hand: duplicating twenty strings
/// is cheaper than making the engine depend on Flutter for them.
class UkrainianEngineStrings implements EngineStrings {
  const UkrainianEngineStrings();

  @override
  String get codeSentToTelegram =>
      'Код надіслано в Telegram на іншому пристрої';
  @override
  String get codeSentBySms => 'Код надіслано в SMS';
  @override
  String get codeByCall => 'Код продиктують у дзвінку';
  @override
  String get expectACall => 'Очікуйте дзвінок';
  @override
  String get codeSentToFragment => 'Код надіслано у Fragment';

  @override
  String get localAlertsUnavailable =>
      'Локальні сповіщення недоступні в цьому процесі';

  @override
  String get tdlibNoAnswerForward => 'TDLib не відповів на пересилання';
  @override
  String get tdlibNoAnswerSend => 'TDLib не відповів на надсилання';
  @override
  String get tdlibNoAnswerTargetLookup =>
      'TDLib не відповів на пошук цільового чату';
  @override
  String get tdlibNotResponding => 'TDLib не відповідає';

  @override
  String get targetNotSet => 'Цільовий чат не задано';
  @override
  String get targetMustBeUsernameOrId =>
      'Цільовий чат має бути @username або числовим id';
  @override
  String get targetNotFound => 'Цільовий чат не знайдено';
  @override
  String get targetNotFoundCheckId =>
      'Цільовий чат не знайдено. Перевірте id або @username.';

  @override
  String get noRightToPost => 'Немає права публікувати в цільовому каналі.';
  @override
  String get sourceForbidsForwarding => 'Канал-джерело забороняє пересилання.';

  @override
  String get signInFirst => 'Спочатку увійдіть у Telegram.';
  @override
  String couldNotListChannels(String error) =>
      'Не вдалося отримати список каналів: $error';

  @override
  String testMessageBody(String stamp) => '✅ TG Alert Monitor: тест, $stamp';
  @override
  String get testMessageSent => 'Тест надіслано';

  @override
  String get setupNothingResolved =>
      'Жоден канал з коду не вдалося відкрити. '
      'Перевірте мережу і спробуйте ще раз.';
}
