/// The local half of alert delivery: a notification on this phone.
///
/// Used when [AlertDelivery.local] or [AlertDelivery.both] is selected. Lives
/// in the service isolate next to the engine, because a match arrives while
/// the UI isolate is usually dead.
library;

import 'dart:async';
import 'dart:ui' show Color;

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import '../core/bot/message_formatter.dart';
import '../core/model/app_config.dart';
import '../core/model/match_entry.dart';
import '../core/storage/keyword_sound_store.dart';
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
///
/// The shade holds one alert at a time, for five minutes. Both are deliberate:
/// see [AlertPolicy].
class AlertNotifier {
  AlertNotifier({
    required L strings,
    KeywordSoundStore? sounds,
    FlutterLocalNotificationsPlugin? plugin,
    this.onLog,
  }) : _s = strings,
       _soundStore = sounds,
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

  /// One id for every alert, so a new one replaces the one before it.
  ///
  /// A raid produces a dozen matches and the shade used to keep all of them.
  /// What the owner needs on waking is what is happening *now*, not an
  /// archive — that is what the journal is for.
  static const int alertId = 1;

  final FlutterLocalNotificationsPlugin _plugin;
  final L _s;

  /// Where a keyword's own generated sound is looked up. Null in tests and on
  /// installs that have never generated one.
  final KeywordSoundStore? _soundStore;

  final void Function(String message)? onLog;

  /// Built on first use: constructing a player costs a platform call, and most
  /// runs of this app never raise a single alert.
  AudioPlayer? _player;

  bool _initialised = false;

  /// Takes the current alert out of the shade once it is stale.
  ///
  /// Android's own `timeoutAfter` does the same thing and survives this process
  /// dying, which a timer cannot. This is here because it is ours: the vendor
  /// layer that refuses to sound a notification in Mute mode is not a layer to
  /// trust with the cleanup either.
  Timer? _expiry;

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
    // An alert left over from a process that was killed before its timer
    // fired: nobody will act on it now, and it would sit above the fresh one.
    try {
      await _plugin.cancel(id: alertId);
    } catch (_) {
      // Nothing there to cancel is the normal case.
    }
    _initialised = true;
  }

  /// Plays the alert on the alarm stream. Returns whether it started.
  ///
  /// The alarm usage is the whole point: a ringer set to silent or vibrate
  /// mutes the ring and notification streams, never the alarm one.
  ///
  /// A keyword that has had a sound generated for it speaks instead of the
  /// siren — the owner picked those words, so hearing which one fired is worth
  /// more than hearing that something did.
  Future<bool> _playAlert(MatchEntry entry) async {
    final source = await _source(entry);
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
      await player.play(source);
      return true;
    } catch (error) {
      onLog?.call('siren playback failed: $error');
      return false;
    }
  }

  /// The keyword's own voice, or the siren.
  Future<Source> _source(MatchEntry entry) async {
    final sounds = _soundStore;
    if (sounds != null) {
      try {
        final file = await sounds.soundForMatch(entry.keywords);
        if (file != null) return DeviceFileSource(file.path);
      } catch (error) {
        // Never fatal: the siren is always there.
        onLog?.call('keyword sound lookup failed: $error');
      }
    }
    return AssetSource(soundAsset);
  }

  /// Posts one alert. Never throws: a failed notification must not stop the
  /// match from being logged or forwarded.
  Future<void> notify(MatchEntry entry) async {
    try {
      await init();
      final played = await _playAlert(entry);
      await _plugin.show(
        id: alertId,
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
            timeoutAfter: AlertPolicy.lifetime.inMilliseconds,
            ticker: entry.keywords.join(' '),
            styleInformation: BigTextStyleInformation(
              _escape(_body(entry)),
              contentTitle: '🔴 ${_escape(entry.chatTitle)}',
            ),
          ),
        ),
        payload: entry.link,
      );
      _scheduleExpiry();
    } catch (error) {
      onLog?.call('local notification failed: $error');
    }
  }

  /// Restarts the five-minute clock. The newest alert decides when the shade
  /// goes quiet, not the first one.
  void _scheduleExpiry() {
    _expiry?.cancel();
    _expiry = Timer(AlertPolicy.lifetime, () async {
      try {
        await _plugin.cancel(id: alertId);
      } catch (error) {
        onLog?.call('could not clear the alert: $error');
      }
    });
  }

  /// Stops the expiry timer. The service isolate is being torn down, so a
  /// pending alert is left for Android's own `timeoutAfter` to collect.
  void dispose() {
    _expiry?.cancel();
    _expiry = null;
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
