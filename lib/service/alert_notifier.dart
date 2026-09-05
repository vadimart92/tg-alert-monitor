/// The local half of alert delivery: a notification on this phone.
///
/// Used when [AlertDelivery.local] or [AlertDelivery.both] is selected. Lives
/// in the service isolate next to the engine, because a match arrives while
/// the UI isolate is usually dead.
library;

import 'dart:ui' show Color;

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import '../core/bot/message_formatter.dart';
import '../core/model/match_entry.dart';
import '../l10n/app_localizations.dart';

/// Shows one heads-up notification per match and plays the siren.
///
/// The siren is played by the app rather than by the notification channel.
/// Channel sound is the tidier mechanism and it does work — but only while the
/// phone is not silenced. Measured on a Galaxy S10 (One UI, Android 12) with
/// the channel set exactly as intended (importance max, USAGE_ALARM, alarm
/// volume 11/15, Do Not Disturb off, the alarm stream not among the streams
/// the ringer mode mutes): in Mute mode the system still refuses to play a
/// notification's sound. That refusal is the vendor's, above our channel, and
/// nothing about the channel can talk it out of it.
///
/// Playing the audio ourselves goes around it entirely: it is an ordinary
/// stream on USAGE_ALARM, which no ringer mode mutes. An air-raid alert that
/// stays quiet because the phone was silenced would be worthless.
///
/// So the notification carries the sight and this class carries the sound —
/// with one exception: if playback fails, the alert falls back to the
/// sounding channel, because a siren the vendor might suppress still beats no
/// siren at all.
class AlertNotifier {
  AlertNotifier({
    required L strings,
    FlutterLocalNotificationsPlugin? plugin,
    this.onLog,
  }) : _s = strings,
       _plugin = plugin ?? FlutterLocalNotificationsPlugin();

  /// The normal channel: silent, because this class plays the siren itself.
  static const String channelId = 'tg_alert_matches_quiet_v1';

  /// Used only when playing the siren ourselves failed, so that the alert
  /// still makes whatever noise the system is willing to make.
  static const String fallbackChannelId = 'tg_alert_matches_v2';

  /// Superseded ids, deleted on startup so they stop cluttering the system
  /// notification settings with channels that do nothing.
  ///
  /// A channel's sound, importance and audio attributes are frozen when
  /// Android first creates it and every later edit is ignored, so a change to
  /// any of them needs a new id and a funeral for the old one.
  static const List<String> retiredChannelIds = ['tg_alert_matches_v1'];

  /// Kept for the fallback channel, and so the sound is still a resource the
  /// system can reach on its own.
  static const String soundResource = 'siren_ostap_calm';

  /// What the app plays itself, straight from the Flutter assets.
  static const String soundAsset = 'siren_ostap_calm.ogg';

  /// An air-raid alert should look like one. Tints the icon and the app name
  /// in the shade, and the notification light where there is one.
  static const Color alertColor = Color(0xFFD32F2F);

  /// Body limit — Android truncates far earlier than Telegram does.
  static const int bodyLimit = 800;

  final FlutterLocalNotificationsPlugin _plugin;
  final L _s;
  final void Function(String message)? onLog;

  /// Built on first use: constructing a player costs a platform call, and most
  /// runs of this app never raise a single alert.
  AudioPlayer? _player;

  bool _initialised = false;

  /// One id per match, so a second alert does not replace the first.
  int _nextId = 1;

  AndroidNotificationChannel get _quietChannel => AndroidNotificationChannel(
    channelId,
    _s.matchChannelName,
    description: _s.matchChannelDescription,
    importance: Importance.max,
    // The siren comes from the app, so the channel must not add a second one.
    playSound: false,
    enableLights: true,
    ledColor: alertColor,
  );

  AndroidNotificationChannel get _fallbackChannel => AndroidNotificationChannel(
    fallbackChannelId,
    _s.matchChannelFallbackName,
    description: _s.matchChannelDescription,
    importance: Importance.max,
    sound: const RawResourceAndroidNotificationSound(soundResource),
    audioAttributesUsage: AudioAttributesUsage.alarm,
    enableLights: true,
    ledColor: alertColor,
  );

  /// Creates the channel. Safe to call repeatedly; only the first call works.
  Future<void> init() async {
    if (_initialised) return;
    await _plugin.initialize(
      settings: const InitializationSettings(
        android: AndroidInitializationSettings('@mipmap/ic_launcher'),
      ),
    );
    final android = _plugin
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >();
    await android?.createNotificationChannel(_quietChannel);
    await android?.createNotificationChannel(_fallbackChannel);
    for (final retired in retiredChannelIds) {
      try {
        await android?.deleteNotificationChannel(channelId: retired);
      } catch (error) {
        onLog?.call('could not delete channel $retired: $error');
      }
    }
    _initialised = true;
  }

  /// Plays the siren on the alarm stream. Returns whether it started.
  ///
  /// The alarm usage is the whole point: a ringer set to silent or vibrate
  /// mutes the ring and notification streams, never the alarm one.
  Future<bool> _playSiren() async {
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
      await player.play(AssetSource(soundAsset));
      return true;
    } catch (error) {
      onLog?.call('siren playback failed: $error');
      return false;
    }
  }

  /// Posts one alert. Never throws: a failed notification must not stop the
  /// match from being logged or forwarded.
  Future<void> notify(MatchEntry entry) async {
    try {
      await init();
      final played = await _playSiren();
      await _plugin.show(
        id: _nextId++,
        title: '🔴 ${entry.chatTitle.isEmpty ? _s.match : entry.chatTitle}',
        body: _body(entry),
        notificationDetails: NotificationDetails(
          android: AndroidNotificationDetails(
            played ? channelId : fallbackChannelId,
            played ? _s.matchChannelName : _s.matchChannelFallbackName,
            importance: Importance.max,
            priority: Priority.high,
            category: AndroidNotificationCategory.alarm,
            audioAttributesUsage: AudioAttributesUsage.alarm,
            playSound: !played,
            sound: played
                ? null
                : const RawResourceAndroidNotificationSound(soundResource),
            color: alertColor,
            colorized: true,
            enableLights: true,
            ledColor: alertColor,
            ledOnMs: 500,
            ledOffMs: 500,
            ticker: entry.keywords.join(' '),
            styleInformation: BigTextStyleInformation(
              _escape(_body(entry)),
              contentTitle: '🔴 ${_escape(entry.chatTitle)}',
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
