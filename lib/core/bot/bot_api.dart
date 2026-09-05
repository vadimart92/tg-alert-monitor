/// Telegram Bot API client — the only outbound channel of the app.
library;

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

/// A Bot API call that did not return `ok: true`.
class BotApiException implements Exception {
  BotApiException({
    required this.description,
    this.httpStatus,
    this.errorCode,
    this.retryAfter,
    this.isNetworkError = false,
  });

  final String description;
  final int? httpStatus;
  final int? errorCode;

  /// `parameters.retry_after` of a 429 answer.
  final Duration? retryAfter;
  final bool isNetworkError;

  /// Flood control: wait exactly as long as Telegram asks, then retry.
  bool get isRateLimited => httpStatus == 429 || errorCode == 429;

  /// Bad token, bot not an admin, chat not found — retrying cannot help.
  bool get isPermanent {
    if (isNetworkError || isRateLimited) return false;
    final status = httpStatus;
    if (status == null) return false;
    return status >= 400 && status < 500;
  }

  /// A human-readable, Ukrainian explanation for the most common failures.
  String get userMessage {
    if (isNetworkError) return 'Немає зв’язку з api.telegram.org: $description';
    return switch (httpStatus) {
      401 => 'Невірний токен бота.',
      403 =>
        'Бот не має доступу до чату. Додайте його адміністратором '
            'із правом «Публікувати повідомлення».',
      400 when description.toLowerCase().contains('chat not found') =>
        'Чат не знайдено. Перевірте @username або числовий id (-100…).',
      400 => 'Запит відхилено: $description',
      429 =>
        'Перевищено ліміт надсилання, повтор за ${retryAfter?.inSeconds} с.',
      _ => description,
    };
  }

  @override
  String toString() => 'BotApiException($httpStatus/$errorCode: $description)';
}

/// Identity of the bot behind a token.
class BotIdentity {
  const BotIdentity({required this.id, required this.name, this.username});

  /// Telegram user id of the bot — needed to look it up as a chat member.
  final int id;
  final String name;
  final String? username;

  String get displayName =>
      (username == null || username!.isEmpty) ? name : '$name (@$username)';
}

/// The operations the app needs. Tests provide a fake.
abstract class BotApi {
  /// Identity of the bot behind the token (`getMe`).
  Future<BotIdentity> getMe();

  /// Returns the target chat's title (`getChat`).
  Future<String> getChat(String chatId);

  /// Posts [html] to [chatId] with previews disabled.
  Future<void> sendMessage({required String chatId, required String html});
}

/// Builds a [BotApi] for a given bot token.
typedef BotApiFactory = BotApi Function(String token);

class HttpBotApi implements BotApi {
  HttpBotApi(
    this._client,
    this._token, {
    this.timeout = const Duration(seconds: 15),
  });

  static const String base = 'https://api.telegram.org';

  final http.Client _client;
  final String _token;
  final Duration timeout;

  @override
  Future<BotIdentity> getMe() async {
    final result = await _call('getMe', const {});
    return BotIdentity(
      id: (result['id'] as num?)?.toInt() ?? 0,
      name: result['first_name'] as String? ?? '',
      username: result['username'] as String?,
    );
  }

  @override
  Future<String> getChat(String chatId) async {
    final result = await _call('getChat', {'chat_id': chatId});
    final title = result['title'] as String?;
    if (title != null && title.isNotEmpty) return title;
    final username = result['username'] as String?;
    return username == null ? chatId : '@$username';
  }

  @override
  Future<void> sendMessage({
    required String chatId,
    required String html,
  }) async {
    await _call('sendMessage', {
      'chat_id': chatId,
      'text': html,
      'parse_mode': 'HTML',
      'link_preview_options': {'is_disabled': true},
    });
  }

  Future<Map<String, dynamic>> _call(
    String method,
    Map<String, dynamic> body,
  ) async {
    final uri = Uri.parse('$base/bot$_token/$method');
    http.Response response;
    try {
      response = await _client
          .post(
            uri,
            headers: const {'Content-Type': 'application/json; charset=utf-8'},
            body: jsonEncode(body),
          )
          .timeout(timeout);
    } on TimeoutException {
      throw BotApiException(
        description: 'час очікування вичерпано',
        isNetworkError: true,
      );
    } catch (error) {
      throw BotApiException(
        description: error.toString(),
        isNetworkError: true,
      );
    }

    Map<String, dynamic> decoded;
    try {
      final parsed = jsonDecode(response.body);
      decoded = parsed is Map
          ? Map<String, dynamic>.from(parsed)
          : <String, dynamic>{};
    } catch (_) {
      decoded = <String, dynamic>{};
    }

    if (response.statusCode == 200 && decoded['ok'] == true) {
      final result = decoded['result'];
      return result is Map
          ? Map<String, dynamic>.from(result)
          : <String, dynamic>{};
    }

    final parameters = decoded['parameters'];
    final retryAfterSeconds = parameters is Map
        ? (parameters['retry_after'] as num?)?.toInt()
        : null;

    throw BotApiException(
      description:
          decoded['description'] as String? ?? 'HTTP ${response.statusCode}',
      httpStatus: response.statusCode,
      errorCode: (decoded['error_code'] as num?)?.toInt(),
      retryAfter: retryAfterSeconds == null
          ? null
          : Duration(seconds: retryAfterSeconds),
    );
  }
}
