/// Small readers for the TDLib JSON shapes this app touches.
///
/// Everything here tolerates missing or unexpected fields: TDLib evolves and a
/// malformed update must never take the monitoring service down.
library;

/// Plain text of a message, or `null` when the message carries nothing to match
/// against.
///
/// `messageText` uses `text`, media messages use their `caption`. Every other
/// content type (stickers, service messages, polls, ...) yields `null`.
String? extractText(Object? content) {
  if (content is! Map) return null;
  return switch (content['@type']) {
    'messageText' => _formattedText(content['text']),
    'messagePhoto' ||
    'messageVideo' ||
    'messageDocument' ||
    'messageAnimation' => _formattedText(content['caption']),
    _ => null,
  };
}

String? _formattedText(Object? formattedText) {
  if (formattedText is! Map) return null;
  final text = formattedText['text'];
  if (text is! String || text.isEmpty) return null;
  return text;
}

/// Display name of a `chatFolderInfo`.
///
/// TDLib 1.8.65 nests it as `name.text.text` (a `chatFolderName` holding a
/// `formattedText`). Older layouts exposed a plain `title`.
String folderName(Object? folderInfo) {
  if (folderInfo is! Map) return '';
  final name = folderInfo['name'];
  if (name is Map) {
    final nested = _formattedText(name['text']);
    if (nested != null) return nested;
    final direct = name['text'];
    if (direct is String && direct.isNotEmpty) return direct;
  }
  if (name is String && name.isNotEmpty) return name;
  final title = folderInfo['title'];
  if (title is String) return title;
  return '';
}

/// TDLib message ids are the server id shifted left by 20 bits. Public links
/// need the server id.
int serverMessageId(int tdlibMessageId) => tdlibMessageId >> 20;

/// Best-effort `t.me` link, used when `getMessageLink` fails.
///
/// [messageId] is the *server* message id — pass [serverMessageId] of a TDLib
/// message id. Supergroup/channel ids carry a `-100` prefix that public links
/// omit. Returns an empty string for chats that have no public link form.
String fallbackLink(int chatId, int messageId) {
  final raw = chatId.toString();
  if (!raw.startsWith('-100')) return '';
  final internal = raw.substring(4);
  if (internal.isEmpty) return '';
  return 'https://t.me/c/$internal/$messageId';
}

/// `true` when the chat json describes a broadcast channel.
bool isChannel(Object? chat) {
  if (chat is! Map) return false;
  final type = chat['type'];
  if (type is! Map) return false;
  if (type['@type'] != 'chatTypeSupergroup') return false;
  return type['is_channel'] == true;
}

/// `title` of a chat json, or an empty string.
String chatTitle(Object? chat) {
  if (chat is! Map) return '';
  final title = chat['title'];
  return title is String ? title : '';
}
