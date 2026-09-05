/// A keyword hit, as stored in `matches.jsonl` and shown in the log screen.
library;

/// Delivery status of a match in the target channel.
enum MatchStatus {
  queued,
  sent,
  failed;

  static MatchStatus parse(String? raw) => switch (raw) {
    'sent' => MatchStatus.sent,
    'failed' => MatchStatus.failed,
    _ => MatchStatus.queued,
  };
}

class MatchEntry {
  const MatchEntry({
    required this.time,
    required this.chatId,
    required this.chatTitle,
    required this.messageId,
    required this.text,
    required this.keywords,
    required this.link,
    this.status = MatchStatus.queued,
    this.error,
  });

  final DateTime time;
  final int chatId;
  final String chatTitle;
  final int messageId;
  final String text;
  final List<String> keywords;
  final String link;
  final MatchStatus status;
  final String? error;

  MatchEntry copyWith({MatchStatus? status, String? error}) => MatchEntry(
    time: time,
    chatId: chatId,
    chatTitle: chatTitle,
    messageId: messageId,
    text: text,
    keywords: keywords,
    link: link,
    status: status ?? this.status,
    error: error ?? this.error,
  );

  Map<String, dynamic> toJson() => {
    'time': time.toIso8601String(),
    'chatId': chatId,
    'chatTitle': chatTitle,
    'messageId': messageId,
    'text': text,
    'keywords': keywords,
    'link': link,
    'status': status.name,
    if (error != null) 'error': error,
  };

  static MatchEntry fromJson(Map<String, dynamic> json) => MatchEntry(
    time:
        DateTime.tryParse(json['time'] as String? ?? '') ??
        DateTime.fromMillisecondsSinceEpoch(0),
    chatId: (json['chatId'] as num?)?.toInt() ?? 0,
    chatTitle: json['chatTitle'] as String? ?? '',
    messageId: (json['messageId'] as num?)?.toInt() ?? 0,
    text: json['text'] as String? ?? '',
    keywords: [
      for (final k in (json['keywords'] as List? ?? const [])) k.toString(),
    ],
    link: json['link'] as String? ?? '',
    status: MatchStatus.parse(json['status'] as String?),
    error: json['error'] as String?,
  );

  @override
  String toString() =>
      'MatchEntry($chatTitle/$messageId, ${keywords.join(",")}, ${status.name})';
}
