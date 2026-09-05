/// The local half of alert delivery: a notification on this phone.
///
/// Used when [AlertDelivery.local] or [AlertDelivery.both] is selected. Lives
/// in the service isolate next to the engine, because a match arrives while
/// the UI isolate is usually dead.
library;

import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import '../core/bot/message_formatter.dart';
import '../core/model/match_entry.dart';

/// Shows one heads-up notification per match and plays the siren.
///
/// The sound is bound to the notification channel, not to the individual
/// notification — that is how Android 8+ works, so it is Android that plays
/// `res/raw/siren_ostap_calm.ogg`, and it keeps playing even when our isolate
/// is being throttled.
///
/// The channel is registered with alarm audio attributes: an air-raid alert
/// that stays silent because the phone is on vibrate would be worthless.
class AlertNotifier {
  AlertNotifier({FlutterLocalNotificationsPlugin? plugin, this.onLog})
    : _plugin = plugin ?? FlutterLocalNotificationsPlugin();

  /// Bumped whenever the channel's sound or importance changes: Android
  /// freezes both at creation time and ignores later edits, so a new sound
  /// only reaches existing installs under a new channel id.
  static const String channelId = 'tg_alert_matches_v1';

  static const String channelName = 'Збіги за ключовими словами';
  static const String soundResource = 'siren_ostap_calm';

  /// Body limit — Android truncates far earlier than Telegram does.
  static const int bodyLimit = 800;

  final FlutterLocalNotificationsPlugin _plugin;
  final void Function(String message)? onLog;

  bool _initialised = false;

  /// One id per match, so a second alert does not replace the first.
  int _nextId = 1;

  static const AndroidNotificationChannel _channel = AndroidNotificationChannel(
    channelId,
    channelName,
    description: 'Сирена та сповіщення, коли повідомлення містить ключове '
        'слово',
    importance: Importance.max,
    sound: RawResourceAndroidNotificationSound(soundResource),
    audioAttributesUsage: AudioAttributesUsage.alarm,
  );

  /// Creates the channel. Safe to call repeatedly; only the first call works.
  Future<void> init() async {
    if (_initialised) return;
    await _plugin.initialize(
      settings: const InitializationSettings(
        android: AndroidInitializationSettings('@mipmap/ic_launcher'),
      ),
    );
    await _plugin
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >()
        ?.createNotificationChannel(_channel);
    _initialised = true;
  }

  /// Posts one alert. Never throws: a failed notification must not stop the
  /// match from being logged or forwarded.
  Future<void> notify(MatchEntry entry) async {
    try {
      await init();
      await _plugin.show(
        id: _nextId++,
        title: entry.chatTitle.isEmpty ? 'Збіг' : entry.chatTitle,
        body: _body(entry),
        notificationDetails: NotificationDetails(
          android: AndroidNotificationDetails(
            channelId,
            channelName,
            importance: Importance.max,
            priority: Priority.high,
            category: AndroidNotificationCategory.alarm,
            audioAttributesUsage: AudioAttributesUsage.alarm,
            sound: const RawResourceAndroidNotificationSound(soundResource),
            ticker: entry.keywords.join(' '),
            styleInformation: BigTextStyleInformation(
              _escape(_body(entry)),
              contentTitle: _escape(entry.chatTitle),
            ),
          ),
        ),
        payload: entry.link,
      );
    } catch (error) {
      onLog?.call('local notification failed: $error');
    }
  }

  /// Keyword line first — it is what the owner reads on the lock screen.
  String _body(MatchEntry entry) {
    final keywords = entry.keywords.join(', ');
    final text = entry.text.length > bodyLimit
        ? '${entry.text.substring(0, _safeCut(entry.text, bodyLimit))}'
              '${MessageFormatter.ellipsis}'
        : entry.text;
    return keywords.isEmpty ? text : '🔑 $keywords\n$text';
  }

  /// Never cuts between the halves of a surrogate pair: an emoji is dropped
  /// whole rather than turned into a lone surrogate.
  static int _safeCut(String value, int limit) {
    if (limit >= value.length) return value.length;
    final unit = value.codeUnitAt(limit - 1);
    return (unit >= 0xD800 && unit <= 0xDBFF) ? limit - 1 : limit;
  }

  /// `BigTextStyleInformation` renders its input as HTML.
  static String _escape(String value) => MessageFormatter.escapeHtml(value);
}
