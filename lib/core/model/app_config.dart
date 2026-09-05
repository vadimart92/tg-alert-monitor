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

/// Everything the monitoring engine needs in order to run.
class MonitorConfig {
  const MonitorConfig({
    this.folderId,
    this.folderName = '',
    this.keywords = const <String>[],
    this.botToken = '',
    this.targetChatId = '',
    this.maxAgeMinutes = defaultMaxAgeMinutes,
    this.chats = const <ChatRef>[],
  });

  static const int defaultMaxAgeMinutes = 10;
  static const int minMaxAgeMinutes = 1;
  static const int maxMaxAgeMinutes = 120;

  final int? folderId;
  final String folderName;
  final List<String> keywords;
  final String botToken;
  final String targetChatId;
  final int maxAgeMinutes;
  final List<ChatRef> chats;

  Duration get maxAge => Duration(minutes: maxAgeMinutes);

  /// True when the engine has enough information to start monitoring.
  bool get isRunnable =>
      folderId != null &&
      keywords.any((k) => k.trim().isNotEmpty) &&
      botToken.trim().isNotEmpty &&
      targetChatId.trim().isNotEmpty;

  MonitorConfig copyWith({
    int? folderId,
    String? folderName,
    List<String>? keywords,
    String? botToken,
    String? targetChatId,
    int? maxAgeMinutes,
    List<ChatRef>? chats,
  }) => MonitorConfig(
    folderId: folderId ?? this.folderId,
    folderName: folderName ?? this.folderName,
    keywords: keywords ?? this.keywords,
    botToken: botToken ?? this.botToken,
    targetChatId: targetChatId ?? this.targetChatId,
    maxAgeMinutes: maxAgeMinutes ?? this.maxAgeMinutes,
    chats: chats ?? this.chats,
  );

  Map<String, dynamic> toJson() => {
    'folderId': folderId,
    'folderName': folderName,
    'keywords': keywords,
    'botToken': botToken,
    'targetChatId': targetChatId,
    'maxAgeMinutes': maxAgeMinutes,
    'chats': [for (final c in chats) c.toJson()],
  };

  static MonitorConfig fromJson(Map<String, dynamic> json) => MonitorConfig(
    folderId: (json['folderId'] as num?)?.toInt(),
    folderName: json['folderName'] as String? ?? '',
    keywords: [
      for (final k in (json['keywords'] as List? ?? const [])) k.toString(),
    ],
    botToken: json['botToken'] as String? ?? '',
    targetChatId: json['targetChatId'] as String? ?? '',
    maxAgeMinutes:
        (json['maxAgeMinutes'] as num?)?.toInt() ?? defaultMaxAgeMinutes,
    chats: [
      for (final c in (json['chats'] as List? ?? const []))
        ChatRef.fromJson(Map<String, dynamic>.from(c as Map)),
    ],
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
