/// Hand-written test doubles — the spec deliberately avoids mock libraries.
library;

import 'dart:async';
import 'dart:convert';

import 'package:tg_alert_monitor/core/bot/bot_api.dart';
import 'package:tg_alert_monitor/core/model/match_entry.dart';
import 'package:tg_alert_monitor/core/storage/match_log.dart';
import 'package:tg_alert_monitor/core/td/td_transport.dart';

/// Answers a request; return `null` to leave it unanswered.
typedef TdResponder = Map<String, dynamic>? Function(
  Map<String, dynamic> request,
);

/// In-memory [TdTransport] with scripted answers.
class FakeTdTransport implements TdTransport {
  final StreamController<String> _controller =
      StreamController<String>.broadcast();

  /// Every request that reached the transport, decoded.
  final List<Map<String, dynamic>> sent = <Map<String, dynamic>>[];

  /// Keyed by request `@type`.
  final Map<String, TdResponder> responders = <String, TdResponder>{};

  bool closed = false;

  @override
  Stream<String> get incoming => _controller.stream;

  @override
  void send(String json) {
    final decoded = Map<String, dynamic>.from(
      jsonDecode(json) as Map<String, dynamic>,
    );
    sent.add(decoded);

    final responder = responders[decoded['@type']];
    if (responder == null) return;
    final response = responder(decoded);
    if (response == null) return;

    final extra = decoded['@extra'];
    scheduleMicrotask(() {
      push({...response, '@extra': ?extra});
    });
  }

  /// Delivers an update or a response as if TDLib produced it.
  void push(Map<String, dynamic> message) {
    if (_controller.isClosed) return;
    _controller.add(jsonEncode(message));
  }

  void pushRaw(String line) {
    if (!_controller.isClosed) _controller.add(line);
  }

  /// Convenience for `updateAuthorizationState`.
  void pushAuthState(Map<String, dynamic> state) =>
      push({'@type': 'updateAuthorizationState', 'authorization_state': state});

  List<Map<String, dynamic>> sentOfType(String type) => [
    for (final request in sent)
      if (request['@type'] == type) request,
  ];

  bool hasSent(String type) => sentOfType(type).isNotEmpty;

  void clearSent() => sent.clear();

  @override
  Future<void> close() async {
    closed = true;
    await _controller.close();
  }
}

/// Captures match-log writes without touching the file system.
class FakeMatchSink implements MatchSink {
  final List<MatchEntry> appended = <MatchEntry>[];
  final List<({int chatId, int messageId, MatchStatus status, String? error})>
  statusUpdates =
      <({int chatId, int messageId, MatchStatus status, String? error})>[];

  @override
  Future<void> append(MatchEntry entry) async => appended.add(entry);

  @override
  Future<void> updateStatus(
    int chatId,
    int messageId,
    MatchStatus status, {
    String? error,
  }) async => statusUpdates.add((
    chatId: chatId,
    messageId: messageId,
    status: status,
    error: error,
  ));
}

/// A clock the test moves by hand.
class FakeClock {
  FakeClock(this._now);

  DateTime _now;

  DateTime call() => _now;

  void advance(Duration duration) => _now = _now.add(duration);

  void set(DateTime value) => _now = value;
}

/// One `sendMessage` the engine asked the bot to make.
class BotMessage {
  const BotMessage(this.chatId, this.html);
  final String chatId;
  final String html;
}

/// In-memory [BotApi]. Records what was posted, and fails on demand.
class FakeBotApi implements BotApi {
  final List<BotMessage> sent = <BotMessage>[];

  /// Tokens the engine built a client for.
  final List<String> tokens = <String>[];

  /// Every call, including the ones that threw.
  int attempts = 0;

  BotApiException? failWith;

  @override
  Future<BotIdentity> getMe() async =>
      const BotIdentity(id: 1, name: 'Тест', username: 'test_bot');

  @override
  Future<String> getChat(String chatId) async => 'Канал $chatId';

  @override
  Future<void> sendMessage({
    required String chatId,
    required String html,
  }) async {
    attempts++;
    final failure = failWith;
    if (failure != null) throw failure;
    sent.add(BotMessage(chatId, html));
  }
}
