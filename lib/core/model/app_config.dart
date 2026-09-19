/// Configuration models shared between the UI isolate and the service isolate.
///
/// Nothing here imports Flutter: the service isolate and plain Dart tests use
/// these types directly.
library;

/// A chat that belongs to the monitored Telegram folder.
class ChatRef {
  const ChatRef({
    required this.id,
    required this.title,
    this.isChannel = false,
  });

  final int id;
  final String title;
  final bool isChannel;

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'isChannel': isChannel,
  };

  static ChatRef fromJson(Map<String, dynamic> json) => ChatRef(
    id: (json['id'] as num?)?.toInt() ?? 0,
    title: json['title'] as String? ?? '',
    isChannel: json['isChannel'] as bool? ?? false,
  );

  @override
  bool operator ==(Object other) =>
      other is ChatRef &&
      other.id == id &&
      other.title == title &&
      other.isChannel == isChannel;

  @override
  int get hashCode => Object.hash(id, title, isChannel);

  @override
  String toString() => 'ChatRef($id, $title, channel: $isChannel)';
}

/// What happens when a message matches.
///
/// The owner picks one of the three on the home screen: relaying into a
/// Telegram channel is useless when nobody watches that channel at night, and
/// a siren on this phone is useless when the alert has to reach other people.
enum AlertDelivery {
  /// Forward the original into the target channel.
  forward,

  /// Post a notification on this phone and play the siren.
  local,

  /// Both at once.
  both;

  bool get forwards => this != local;
  bool get notifies => this != forward;

  static AlertDelivery parse(Object? raw) {
    for (final value in values) {
      if (value.name == raw) return value;
    }
    return forward;
  }
}

/// How the alert on this phone behaves once it fires.
///
/// The pause between two alerts for one keyword is a setting
/// ([MonitorConfig.alertCooldownSeconds]) — how much repetition is noise
/// depends on the channels being watched, and only their owner knows. What is
/// left here is the part with no judgement in it.
abstract final class AlertPolicy {
  /// The shade keeps the newest alert only, and lets go of it after this.
  ///
  /// An alert nobody acted on within five minutes is history, and a stack of
  /// them is worse than none: the owner has to swipe through yesterday's raid
  /// to see whether anything is happening now.
  static const Duration lifetime = Duration(minutes: 5);
}

/// Everything the monitoring engine needs in order to run.
class MonitorConfig {
  const MonitorConfig({
    this.folderId,
    this.folderName = '',
    this.keywords = const <String>[],
    this.targetChatId = '',
    this.maxAgeMinutes = defaultMaxAgeMinutes,
    this.chats = const <ChatRef>[],
    this.delivery = AlertDelivery.forward,
    this.botToken = '',
    this.alertCooldownSeconds = defaultAlertCooldownSeconds,
  });

  static const int defaultMaxAgeMinutes = 10;
  static const int minMaxAgeMinutes = 1;
  static const int maxMaxAgeMinutes = 120;

  /// Long enough to swallow the two or three posts a channel makes about one
  /// event, short enough that the next event is still an event.
  static const int defaultAlertCooldownSeconds = 30;

  /// Zero is a real answer: every match sounds, as it did before this setting
  /// existed.
  static const int minAlertCooldownSeconds = 0;

  /// An hour. Past that the owner is not silencing a burst, they are turning
  /// the keyword off — which the keyword list already does, and visibly.
  static const int maxAlertCooldownSeconds = 3600;

  final int? folderId;
  final String folderName;
  final List<String> keywords;
  final String targetChatId;
  final int maxAgeMinutes;
  final List<ChatRef> chats;
  final AlertDelivery delivery;

  /// Optional. With a token the alert is posted by the bot as a link and a
  /// tag; without one the original is forwarded by the owner themselves.
  ///
  /// The difference that matters is who Telegram thinks sent it: your own
  /// messages never notify your other devices, a bot's do.
  final String botToken;

  /// How long one keyword stays quiet after it has sounded on this phone.
  ///
  /// Only the sound is held back. The match is still logged and still
  /// forwarded: a burst is noise to a sleeping owner, not to the channel where
  /// the alerts are collected.
  final int alertCooldownSeconds;

  Duration get maxAge => Duration(minutes: maxAgeMinutes);

  Duration get alertCooldown => Duration(seconds: alertCooldownSeconds);

  /// True when the engine has enough information to start monitoring.
  ///
  /// No bot token: forwarding goes through the owner's own Telegram session.
  /// A target channel is only required when something is actually forwarded.
  bool get isRunnable =>
      folderId != null &&
      keywords.any((k) => k.trim().isNotEmpty) &&
      (!delivery.forwards || targetChatId.trim().isNotEmpty);

  /// True when alerts are posted by a bot rather than forwarded by the owner.
  bool get usesBot => botToken.trim().isNotEmpty;

  MonitorConfig copyWith({
    int? folderId,
    String? folderName,
    List<String>? keywords,
    String? targetChatId,
    int? maxAgeMinutes,
    List<ChatRef>? chats,
    AlertDelivery? delivery,
    String? botToken,
    int? alertCooldownSeconds,
  }) => MonitorConfig(
    folderId: folderId ?? this.folderId,
    folderName: folderName ?? this.folderName,
    keywords: keywords ?? this.keywords,
    targetChatId: targetChatId ?? this.targetChatId,
    maxAgeMinutes: maxAgeMinutes ?? this.maxAgeMinutes,
    chats: chats ?? this.chats,
    delivery: delivery ?? this.delivery,
    botToken: botToken ?? this.botToken,
    alertCooldownSeconds: alertCooldownSeconds ?? this.alertCooldownSeconds,
  );

  Map<String, dynamic> toJson() => {
    'folderId': folderId,
    'folderName': folderName,
    'keywords': keywords,
    'targetChatId': targetChatId,
    'maxAgeMinutes': maxAgeMinutes,
    'chats': [for (final c in chats) c.toJson()],
    'delivery': delivery.name,
    'botToken': botToken,
    'alertCooldownSeconds': alertCooldownSeconds,
  };

  static MonitorConfig fromJson(Map<String, dynamic> json) => MonitorConfig(
    folderId: (json['folderId'] as num?)?.toInt(),
    folderName: json['folderName'] as String? ?? '',
    keywords: [
      for (final k in (json['keywords'] as List? ?? const [])) k.toString(),
    ],
    targetChatId: json['targetChatId'] as String? ?? '',
    maxAgeMinutes:
        (json['maxAgeMinutes'] as num?)?.toInt() ?? defaultMaxAgeMinutes,
    chats: [
      for (final c in (json['chats'] as List? ?? const []))
        ChatRef.fromJson(Map<String, dynamic>.from(c as Map)),
    ],
    delivery: AlertDelivery.parse(json['delivery']),
    botToken: json['botToken'] as String? ?? '',
    alertCooldownSeconds:
        (json['alertCooldownSeconds'] as num?)?.toInt() ??
        defaultAlertCooldownSeconds,
  );
}

/// Telegram application credentials, entered by the owner in the UI.
class TdCredentials {
  const TdCredentials({required this.apiId, required this.apiHash});

  final int apiId;
  final String apiHash;

  bool get isValid =>
      apiId > 0 && RegExp(r'^[0-9a-fA-F]{32}$').hasMatch(apiHash);
}

/// A Telegram chat folder as shown in the folder picker.
class FolderRef {
  const FolderRef({required this.id, required this.name});

  final int id;
  final String name;

  Map<String, dynamic> toJson() => {'id': id, 'name': name};

  static FolderRef fromJson(Map<String, dynamic> json) => FolderRef(
    id: (json['id'] as num?)?.toInt() ?? 0,
    name: json['name'] as String? ?? '',
  );

  @override
  bool operator ==(Object other) =>
      other is FolderRef && other.id == id && other.name == name;

  @override
  int get hashCode => Object.hash(id, name);
}
