/// Says a pause out loud the way a person would.
///
/// The pause between two alerts for one keyword is stored in seconds and can
/// be anything from nothing to an hour, so neither unit alone reads well:
/// «1800 с» is arithmetic, «0.5 хв» is worse.
library;

import '../l10n/app_localizations.dart';

String durationLabel(L l, Duration value) {
  final seconds = value.inSeconds;
  if (seconds < 60 || seconds % 60 != 0) return l.durationSeconds(seconds);
  return l.durationMinutes(seconds ~/ 60);
}
