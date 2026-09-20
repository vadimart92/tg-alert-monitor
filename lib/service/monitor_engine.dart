/// Orchestration of authentication, folder resolution and message forwarding.
///
/// Deliberately free of Flutter imports: every dependency is injected, so the
/// whole engine runs under plain `flutter test` with fakes.
library;

import 'dart:async';
import 'dart:collection';

import '../core/bot/bot_api.dart';
import '../core/bot/forward_queue.dart';
import '../core/bot/message_formatter.dart';
import '../core/ipc/protocol.dart';
import '../core/matcher/keyword_matcher.dart';
import '../core/model/app_config.dart';
import '../core/model/match_entry.dart';
import '../core/model/setup_payload.dart';
import '../core/storage/match_log.dart';
import '../core/td/td_client.dart';
import '../core/td/td_json.dart';
import '../core/util/app_logger.dart';
import '../core/util/engine_strings.dart';

/// `setTdlibParameters` payload (spec 7.4).
class TdlibParams {
  const TdlibParams({
    required this.apiId,
    required this.apiHash,
    required this.databaseDirectory,
    required this.filesDirectory,
    this.systemLanguageCode = 'uk',
    this.deviceModel = 'TG Alert Monitor',
    this.systemVersion = 'Android',
    this.applicationVersion = '1.0.0',
  });

  final int apiId;
  final String apiHash;
  final String databaseDirectory;
  final String filesDirectory;
  final String systemLanguageCode;
  final String deviceModel;
  final String systemVersion;
  final String applicationVersion;

  Map<String, dynamic> toRequest() => {
    '@type': 'setTdlibParameters',
    'use_test_dc': false,
    'database_directory': databaseDirectory,
    'files_directory': filesDirectory,
    'database_encryption_key': '',
    // No media downloads, so no file database is needed.
    'use_file_database': false,
    'use_chat_info_database': true,
    // Lets TDLib backfill channel posts missed while offline.
    'use_message_database': true,
    'use_secret_chats': false,
    'api_id': apiId,
    'api_hash': apiHash,
    'system_language_code': systemLanguageCode,
    'device_model': deviceModel,
    'system_version': systemVersion,
    'application_version': applicationVersion,
  };
}

/// Auth phase names carried in [Ev.state].
abstract final class AuthPhase {
  static const String init = 'init';
  static const String waitPhone = 'waitPhone';
  static const String waitCode = 'waitCode';
  static const String waitPassword = 'waitPassword';
  static const String ready = 'ready';
  static const String closing = 'closing';
  static const String closed = 'closed';
  static const String unsupported = 'unsupported';
}

/// Connection phase names carried in [Ev.state].
abstract final class ConnectionPhase {
  static const String ready = 'ready';
  static const String connecting = 'connecting';
  static const String updating = 'updating';
  static const String waitingForNetwork = 'waitingForNetwork';
}

/// Shows a match on this phone. Injected so the engine stays Flutter-free;
/// the real implementation is [AlertNotifier] in the service isolate.
///
/// [speakText] carries the owner's choice rather than the notifier reading it
/// from storage: the engine already holds the authoritative config, and a
/// second copy that has to be kept in step is a bug waiting for a quiet night.
typedef LocalAlert =
    Future<void> Function(MatchEntry entry, {required bool speakText});

/// Bounded "already handled" set, keyed by chat and message id.
class _RecentMessages {
  _RecentMessages(this.capacity);

  final int capacity;
  final Set<String> _seen = <String>{};
  final Queue<String> _order = Queue<String>();

  /// Returns `false` when the pair was already recorded.
  bool add(int chatId, int messageId) {
    final key = '$chatId/$messageId';
    if (!_seen.add(key)) return false;
    _order.add(key);
    if (_order.length > capacity) _seen.remove(_order.removeFirst());
    return true;
  }

  void clear() {
    _seen.clear();
    _order.clear();
  }
}

class MonitorEngine {
  MonitorEngine({
    required this._client,
    required this._params,
    required this._matchLog,
    required this._logger,
    required this._emit,
    required this._saveConfig,
    required this._saveChats,
    required this._saveMonitoringActive,
    MonitorConfig config = const MonitorConfig(),
    DateTime Function()? now,
    this.folderRefreshInterval = const Duration(minutes: 30),
    this.connectionStallTimeout = const Duration(minutes: 2),
    Duration forwardInterval = const Duration(milliseconds: 1500),
    this._alert,
    this._botApi,
    EngineStrings strings = const UkrainianEngineStrings(),
  }) : _config = config,
       _s = strings,
       _now = now ?? DateTime.now {
    _matcher = KeywordMatcher(config.keywords);
    _forwardQueue = ForwardQueue(
      deliver: _deliverTask,
      minInterval: forwardInterval,
      onLog: _logger.info,
      onStatus: _onForwardStatus,
    );
  }

  final TdClient _client;
  final TdlibParams _params;
  final MatchSink _matchLog;
  final AppLogger _logger;
  final void Function(Event event) _emit;
  final Future<void> Function(MonitorConfig config) _saveConfig;

  /// Persists only the resolved chat list.
  ///
  /// Separate from [_saveConfig] on purpose. A folder refresh happens on a
  /// timer inside the service, from the engine's own copy of the config — and
  /// that copy can be older than what the owner just typed in the UI. Writing
  /// the whole config from here would quietly undo a keyword added a moment
  /// ago, which is a very hard thing to notice and an even harder one to
  /// explain.
  final Future<void> Function(List<ChatRef> chats) _saveChats;
  final Future<void> Function(bool active) _saveMonitoringActive;
  final LocalAlert? _alert;

  /// Builds a Bot API client for a token. Null in tests that do not need one.
  final BotApiFactory? _botApi;
  final EngineStrings _s;
  final DateTime Function() _now;

  final Duration folderRefreshInterval;
  final Duration connectionStallTimeout;

  late final ForwardQueue _forwardQueue;
  late KeywordMatcher _matcher;

  MonitorConfig _config;
  StreamSubscription<Map<String, dynamic>>? _subscription;

  // --- observable state ---------------------------------------------------
  String _auth = AuthPhase.init;
  String _authDetail = '';
  String _userName = '';
  String _connection = ConnectionPhase.connecting;
  bool _monitoring = false;
  DateTime? _startedAt;
  DateTime? _lastMatchAt;
  int _matchCount = 0;
  String _tdVersion = '';
  int _myUserId = 0;

  /// Target channel resolved to a TDLib chat id, cached per configured value.
  int? _targetChatId;
  String _targetChatIdSource = '';

  final List<FolderRef> _folders = <FolderRef>[];
  final Set<int> _folderChatIds = <int>{};
  final Map<int, String> _chatTitles = <int, String>{};
  final _RecentMessages _recent = _RecentMessages(2000);

  /// When each keyword last made this phone sound, by normalised keyword.
  ///
  /// Deliberately not persisted: after a restart the owner has a phone in
  /// their hand and no idea what it has been quiet about, so the first match
  /// of a session should always be heard.
  final Map<String, DateTime> _lastAlertByKeyword = <String, DateTime>{};

  DateTime? _connectionDegradedSince;
  DateTime? _lastFolderRefresh;
  bool _loggingOut = false;
  bool _closedIntentionally = false;

  // --- accessors used by the task handler and tests ------------------------
  MonitorConfig get config => _config;
  bool get isMonitoring => _monitoring;
  String get authPhase => _auth;
  String get connectionPhase => _connection;
  String get tdVersion => _tdVersion;
  int get chatCount => _folderChatIds.length;
  int get matchCount => _matchCount;
  List<FolderRef> get folders => List<FolderRef>.unmodifiable(_folders);

  /// Fires when TDLib reports the client is closed for reasons other than an
  /// explicit logout, so the caller can rebuild it.
  void Function()? onClientDead;

  /// Subscribes to updates and nudges TDLib into emitting its first
  /// authorization state.
  Future<void> start() async {
    _subscription = _client.updates.listen(
      _onUpdate,
      onError: (Object error) => _logger.error('update stream error: $error'),
    );
    unawaited(_readVersion());
  }

  Future<void> _readVersion() async {
    try {
      final result = await _client.send({
        '@type': 'getOption',
        'name': 'version',
      }, timeout: const Duration(seconds: 15));
      final value = result['value'];
      if (value is String && value.isNotEmpty) {
        _tdVersion = value;
        _logger.info('tdlib $value');
        _emitState();
      }
    } catch (error) {
      _logger.warn('could not read tdlib version: $error');
    }
  }

  Future<void> dispose() async {
    _forwardQueue.stop();
    await _subscription?.cancel();
    _subscription = null;
  }

  // --- update routing -----------------------------------------------------

  void _onUpdate(Map<String, dynamic> update) {
    switch (update['@type']) {
      case 'updateAuthorizationState':
        unawaited(
          _guard(
            'auth',
            () => _handleAuthorizationState(update['authorization_state']),
          ),
        );
      case 'updateConnectionState':
        _handleConnectionState(update['state']);
      case 'updateChatFolders':
        _handleChatFolders(update['chat_folders']);
      case 'updateNewMessage':
        unawaited(
          _guard('message', () => _handleNewMessage(update['message'])),
        );
      case 'updateChatPosition':
        _handleChatPosition(update);
      case 'updateNewChat':
        final chat = update['chat'];
        if (chat is Map) {
          final id = (chat['id'] as num?)?.toInt();
          if (id != null) _chatTitles[id] = chatTitle(chat);
        }
      case 'updateChatTitle':
        final id = (update['chat_id'] as num?)?.toInt();
        final title = update['title'];
        if (id != null && title is String) _chatTitles[id] = title;
    }
  }

  Future<void> _guard(String scope, Future<void> Function() action) async {
    try {
      await action();
    } on TdError catch (error) {
      _logger.error('$scope: TDLib error ${error.code} ${error.message}');
      _emit(
        Event(Ev.error, {
          'scope': scope == 'auth' ? ErrorScope.auth : ErrorScope.td,
          'code': error.code,
          'message': error.message,
        }),
      );
    } catch (error) {
      _logger.error('$scope: $error');
    }
  }

  // --- authorization ------------------------------------------------------

  Future<void> _handleAuthorizationState(Object? rawState) async {
    if (rawState is! Map) return;
    final state = Map<String, dynamic>.from(rawState);
    final type = state['@type'] as String? ?? '';
    _logger.info('auth state $type');

    switch (type) {
      case 'authorizationStateWaitTdlibParameters':
        _auth = AuthPhase.init;
        _authDetail = '';
        _emitState();
        await _client.send(_params.toRequest());

      case 'authorizationStateWaitPhoneNumber':
        _auth = AuthPhase.waitPhone;
        _authDetail = '';
        _emitState();

      case 'authorizationStateWaitCode':
        _auth = AuthPhase.waitCode;
        _authDetail = _codeTypeLabel(state['code_info']);
        _emitState();

      case 'authorizationStateWaitPassword':
        _auth = AuthPhase.waitPassword;
        _authDetail = state['password_hint'] as String? ?? '';
        _emitState();

      case 'authorizationStateReady':
        _auth = AuthPhase.ready;
        _authDetail = '';
        _loggingOut = false;
        _emitState();
        await _onReady();

      case 'authorizationStateLoggingOut':
        _loggingOut = true;
        _auth = AuthPhase.closing;
        _emitState();

      case 'authorizationStateClosing':
        _auth = AuthPhase.closing;
        _emitState();

      case 'authorizationStateClosed':
        _auth = AuthPhase.closed;
        _monitoring = false;
        _emitState();
        if (!_loggingOut && !_closedIntentionally) {
          _logger.warn('TDLib client closed unexpectedly; restart required');
          onClientDead?.call();
        }

      default:
        _auth = AuthPhase.unsupported;
        _authDetail = type;
        _logger.warn('unsupported authorization state $type');
        _emitState();
    }
  }

  /// Human hint about where Telegram sent the login code.
  String _codeTypeLabel(Object? codeInfo) {
    if (codeInfo is! Map) return '';
    final type = codeInfo['type'];
    if (type is! Map) return '';
    return switch (type['@type']) {
      'authenticationCodeTypeTelegramMessage' => _s.codeSentToTelegram,
      'authenticationCodeTypeSms' ||
      'authenticationCodeTypeSmsWord' ||
      'authenticationCodeTypeSmsPhrase' => _s.codeSentBySms,
      'authenticationCodeTypeCall' => _s.codeByCall,
      'authenticationCodeTypeFlashCall' ||
      'authenticationCodeTypeMissedCall' => _s.expectACall,
      'authenticationCodeTypeFragment' => _s.codeSentToFragment,
      _ => '',
    };
  }

  Future<void> _onReady() async {
    try {
      final me = await _client.send({'@type': 'getMe'});
      final first = me['first_name'] as String? ?? '';
      final last = me['last_name'] as String? ?? '';
      _userName = [first, last].where((p) => p.isNotEmpty).join(' ');
      _myUserId = (me['id'] as num?)?.toInt() ?? 0;
      _emitState();
    } catch (error) {
      _logger.warn('getMe failed: $error');
    }

    // TDLib only pushes updates for chats it has loaded.
    await _loadAllChats({'@type': 'chatListMain'});

    if (_config.folderId != null && _config.chats.isNotEmpty) {
      _adoptChats(_config.chats);
    }

    if (_monitoring) await _refreshFolder(emitEvent: false);
  }

  // --- connection ---------------------------------------------------------

  void _handleConnectionState(Object? rawState) {
    if (rawState is! Map) return;
    _connection = switch (rawState['@type']) {
      'connectionStateReady' => ConnectionPhase.ready,
      'connectionStateUpdating' => ConnectionPhase.updating,
      'connectionStateWaitingForNetwork' => ConnectionPhase.waitingForNetwork,
      _ => ConnectionPhase.connecting,
    };
    _connectionDegradedSince = _connection == ConnectionPhase.ready
        ? null
        : (_connectionDegradedSince ?? _now());
    _logger.info('connection $_connection');
    _emitState();
  }

  // --- folders ------------------------------------------------------------

  void _handleChatFolders(Object? rawFolders) {
    final list = rawFolders is Map ? rawFolders['chat_folders'] : rawFolders;
    if (list is! List) return;
    _folders
      ..clear()
      ..addAll([
        for (final item in list)
          if (item is Map)
            FolderRef(
              id: (item['id'] as num?)?.toInt() ?? 0,
              name: folderName(item),
            ),
      ]);
    _logger.info('folders updated (${_folders.length})');
    _emitFolders();
  }

  void _emitFolders() {
    _emit(
      Event(Ev.folders, {
        'items': [for (final folder in _folders) folder.toJson()],
      }),
    );
  }

  void _handleChatPosition(Map<String, dynamic> update) {
    final folderId = _config.folderId;
    if (folderId == null || !_monitoring) return;
    final position = update['position'];
    if (position is! Map) return;
    final list = position['list'];
    if (list is! Map) return;
    if (list['@type'] != 'chatListFolder') return;
    if ((list['chat_folder_id'] as num?)?.toInt() != folderId) return;
    _logger.info('folder membership changed, re-resolving');
    unawaited(_guard('folder', () => _refreshFolder()));
  }

  /// Repeats `loadChats` until TDLib answers 404, meaning "nothing left".
  Future<void> _loadAllChats(Map<String, dynamic> chatList) async {
    for (var page = 0; page < 200; page++) {
      try {
        await _client.send({
          '@type': 'loadChats',
          'chat_list': chatList,
          'limit': 100,
        });
      } on TdError catch (error) {
        if (error.code == 404) return;
        rethrow;
      } on TdTimeout {
        return;
      }
    }
  }

  /// Resolves the configured folder into a concrete chat list.
  Future<List<ChatRef>> resolveFolder(int folderId) async {
    final chatList = {'@type': 'chatListFolder', 'chat_folder_id': folderId};
    await _loadAllChats(chatList);

    final response = await _client.send({
      '@type': 'getChats',
      'chat_list': chatList,
      'limit': 1000,
    });

    final ids = response['chat_ids'];
    final chats = <ChatRef>[];
    if (ids is! List) return chats;

    for (final rawId in ids) {
      final id = (rawId as num?)?.toInt();
      if (id == null) continue;
      try {
        final chat = await _client.send({'@type': 'getChat', 'chat_id': id});
        chats.add(
          ChatRef(id: id, title: chatTitle(chat), isChannel: isChannel(chat)),
        );
      } on TdError catch (error) {
        _logger.warn('getChat($id) failed: ${error.message}');
        chats.add(ChatRef(id: id, title: _chatTitles[id] ?? '$id'));
      }
    }
    return chats;
  }

  void _adoptChats(List<ChatRef> chats) {
    _folderChatIds
      ..clear()
      ..addAll(chats.map((c) => c.id));
    for (final chat in chats) {
      _chatTitles[chat.id] = chat.title;
    }
  }

  Future<void> _refreshFolder({bool emitEvent = true}) async {
    final folderId = _config.folderId;
    if (folderId == null) return;
    final chats = await resolveFolder(folderId);
    _adoptChats(chats);
    _lastFolderRefresh = _now();
    _config = _config.copyWith(chats: chats);
    await _saveChats(chats);
    _logger.info('folder $folderId resolved to ${chats.length} chats');
    if (emitEvent) {
      _emit(
        Event(Ev.folderChats, {
          'folderId': folderId,
          'items': [for (final chat in chats) chat.toJson()],
        }),
      );
    }
    _emitState();
  }

  // --- message pipeline ---------------------------------------------------

  Future<void> _handleNewMessage(Object? rawMessage) async {
    if (!_monitoring) return;
    if (rawMessage is! Map) return;
    final message = Map<String, dynamic>.from(rawMessage);

    final chatId = (message['chat_id'] as num?)?.toInt();
    if (chatId == null || !_folderChatIds.contains(chatId)) return;

    // Only what we put into the target channel is ignored, and only to stop a
    // delivery loop. An outgoing message anywhere else is a real match: TDLib
    // marks a post as outgoing when the owner made it, so a channel the owner
    // runs themselves — the obvious way to test the app — would otherwise
    // never trigger anything at all.
    if (message['is_outgoing'] == true && _isTargetChat(chatId)) return;

    final text = extractText(message['content']);
    if (text == null || text.isEmpty) return;

    final date = (message['date'] as num?)?.toInt();
    if (date == null) return;
    final sentAt = DateTime.fromMillisecondsSinceEpoch(date * 1000);
    if (_now().difference(sentAt) > _config.maxAge) return;

    final messageId = (message['id'] as num?)?.toInt();
    if (messageId == null) return;
    if (!_recent.add(chatId, messageId)) return;

    final keywords = _matcher.match(text);
    if (keywords.isEmpty) return;

    final link = await _messageLink(chatId, messageId);
    final entry = MatchEntry(
      time: _now(),
      chatId: chatId,
      chatTitle: _chatTitles[chatId] ?? '$chatId',
      messageId: messageId,
      text: text,
      keywords: keywords,
      link: link,
    );

    _matchCount++;
    _lastMatchAt = entry.time;
    _logger.info(
      'match in chat $chatId msg $messageId (${keywords.length} kw)',
    );

    await _matchLog.append(entry);
    _emit(Event(Ev.match, entry.toJson()));
    _emitState();

    final delivery = _config.delivery;
    if (delivery.notifies) {
      final muted = _mutedKeywords(keywords);
      if (muted != null) {
        _logger.info('siren held back: $muted');
        // With no channel involved there is nothing else in flight, so the
        // journal says plainly that this one was heard and not sounded.
        if (!delivery.forwards) {
          _recordStatus(chatId, messageId, MatchStatus.muted, null);
        }
      } else {
        final error = await _notifyLocally(entry);
        // A siren that never sounded must not start a cooldown: the owner
        // heard nothing, so the next match has to try again.
        if (error == null) _startCooldown(keywords);
        // With no channel involved the notification *is* the delivery, so it
        // is what decides the entry's status. Otherwise the forward queue
        // does.
        if (!delivery.forwards) {
          _recordStatus(
            chatId,
            messageId,
            error == null ? MatchStatus.sent : MatchStatus.failed,
            error,
          );
        }
      }
    }

    if (!delivery.forwards) return;

    _forwardQueue.enqueue(
      ForwardTask(
        chatId: chatId,
        messageId: messageId,
        targetChatId: _config.targetChatId,
        link: link,
        html: MessageFormatter.format(
          chatTitle: entry.chatTitle,
          keywords: keywords,
          text: text,
          link: link,
          time: entry.time,
        ),
        botHtml: MessageFormatter.formatForBot(
          chatTitle: entry.chatTitle,
          keywords: keywords,
          text: text,
          link: link,
          time: entry.time,
        ),
      ),
    );
  }

  /// Why this match must stay silent, or `null` when it may sound.
  ///
  /// A match sounds when at least one of its keywords is out of its cooldown.
  /// The others ride along: the alert names every keyword it matched, so the
  /// owner has been told about them too.
  String? _mutedKeywords(List<String> keywords) {
    final cooldown = _config.alertCooldown;
    if (cooldown <= Duration.zero) return null;
    final now = _now();
    final waiting = <String>[];
    for (final keyword in keywords) {
      final last = _lastAlertByKeyword[KeywordMatcher.normalize(keyword)];
      if (last == null || now.difference(last) >= cooldown) return null;
      final left = cooldown - now.difference(last);
      waiting.add('$keyword ${left.inSeconds + 1}s');
    }
    return waiting.join(', ');
  }

  /// Silences every keyword of an alert that has just sounded.
  void _startCooldown(List<String> keywords) {
    final now = _now();
    for (final keyword in keywords) {
      _lastAlertByKeyword[KeywordMatcher.normalize(keyword)] = now;
    }
  }

  /// Shows the match on this phone. Returns the failure message, or `null`.
  ///
  /// Never retried: a siren that arrives minutes late is noise, not an alert.
  Future<String?> _notifyLocally(MatchEntry entry) async {
    final alert = _alert;
    if (alert == null) {
      _logger.warn('local alert requested but no notifier is wired up');
      return _s.localAlertsUnavailable;
    }
    try {
      await alert(entry, speakText: _config.speakMessage);
      return null;
    } catch (error) {
      _logger.error('local alert failed: $error');
      return '$error';
    }
  }

  /// True when [chatId] is where this app publishes.
  ///
  /// The resolved id is only known once something has been delivered, so the
  /// configured value is checked too — otherwise the very first alert could
  /// echo before the cache was warm.
  bool _isTargetChat(int chatId) {
    if (_targetChatId == chatId) return true;
    final configured = _config.targetChatId.trim();
    return configured.isNotEmpty && int.tryParse(configured) == chatId;
  }

  Future<String> _messageLink(int chatId, int messageId) async {
    try {
      // Only the two fields every version of the schema agrees on. The
      // optional ones differ between TDLib releases and one of them is typed
      // as a string somewhere in 1.8.65 — sending it as a number made every
      // single call fail with "Expected String, but receive Number", which
      // silently dropped every alert onto the private-link fallback below.
      // Omitted fields are defaulted by TDLib, which is what we wanted anyway.
      final response = await _client.send({
        '@type': 'getMessageLink',
        'chat_id': chatId,
        'message_id': messageId,
      }, timeout: const Duration(seconds: 10));
      final link = response['link'];
      if (link is String && link.isNotEmpty) return link;
    } catch (error) {
      _logger.warn('getMessageLink failed for $chatId/$messageId: $error');
    }

    // A public channel has a username, and `t.me/<username>/<id>` is a link
    // Telegram will render a preview for. The `t.me/c/...` form below never
    // gets one, so falling straight to it would quietly cost every alert its
    // preview whenever getMessageLink is unavailable.
    final username = await _usernameOf(chatId);
    if (username.isNotEmpty) {
      return 'https://t.me/$username/${serverMessageId(messageId)}';
    }
    return fallbackLink(chatId, serverMessageId(messageId));
  }

  /// Delivers one match to the target channel.
  ///
  /// The original is forwarded through the owner's own session, so the post
  /// keeps its "forwarded from" header and its media instead of being retyped.
  /// A bot cannot do this: it is not a member of the monitored channels.
  ///
  /// Nothing is posted alongside it. A second message with the matched
  /// keywords doubled the noise in the target channel for information the
  /// forwarded post already carries; the journal shows the tags instead.
  ///
  /// Channels published with content protection cannot be forwarded at all, so
  /// those fall back to the self-contained rendering.
  Future<void> _deliverTask(ForwardTask task) async {
    if (_config.usesBot) {
      await _deliverThroughBot(task);
      return;
    }

    final targetId = await _resolveTargetChat(task.targetChatId);

    try {
      await _client.send({
        '@type': 'forwardMessages',
        'chat_id': targetId,
        'from_chat_id': task.chatId,
        'message_ids': [task.messageId],
        'send_copy': false,
        'remove_caption': false,
      }, timeout: const Duration(seconds: 30));
    } on TdError catch (error) {
      _logger.warn(
        'forward of ${task.chatId}/${task.messageId} rejected '
        '(${error.message}); sending a copy instead',
      );
      await _sendText(targetId, task.html, html: true);
      return;
    } on TdTimeout {
      throw DeliveryFailure(_s.tdlibNoAnswerForward);
    }
  }

  /// Posts the alert as the bot: a rendered message with the tags and a link
  /// back to the original.
  ///
  /// A bot cannot forward from a channel it is not in, so this is a rendering
  /// rather than a forward — and that is the point. A message the owner sends
  /// themselves never notifies their own other devices, so a forward is
  /// invisible on the phone in your pocket. A bot is a different sender, so
  /// its post arrives as a normal notification.
  Future<void> _deliverThroughBot(ForwardTask task) async {
    final factory = _botApi;
    if (factory == null) {
      throw DeliveryFailure(_s.botUnavailable, isPermanent: true);
    }
    final target = task.targetChatId.trim();
    if (target.isEmpty) {
      throw DeliveryFailure(_s.targetNotSet, isPermanent: true);
    }

    try {
      await factory(_config.botToken.trim()).sendMessage(
        chatId: target,
        html: task.botHtml,
        showPreview: MessageFormatter.buildsPreview(task.link),
      );
    } on BotApiException catch (error) {
      throw DeliveryFailure(
        error.userMessage,
        isPermanent: error.isPermanent,
        retryAfter: error.retryAfter,
      );
    }
  }

  /// Posts a plain or HTML-ish text message as the owner.
  Future<void> _sendText(int chatId, String text, {required bool html}) async {
    // The fallback rendering is HTML for the Bot API; as a user we send plain
    // text, so strip the few tags we generate rather than showing them raw.
    final body = html ? MessageFormatter.stripHtml(text) : text;
    try {
      await _client.send({
        '@type': 'sendMessage',
        'chat_id': chatId,
        'input_message_content': {
          '@type': 'inputMessageText',
          'text': {'@type': 'formattedText', 'text': body},
          'link_preview_options': {
            '@type': 'linkPreviewOptions',
            'is_disabled': true,
          },
        },
      }, timeout: const Duration(seconds: 30));
    } on TdError catch (error) {
      throw _deliveryFailureFrom(error);
    } on TdTimeout {
      throw DeliveryFailure(_s.tdlibNoAnswerSend);
    }
  }

  /// Resolves the configured target into a TDLib chat id, once per value.
  Future<int> _resolveTargetChat(String configured) async {
    final trimmed = configured.trim();
    if (trimmed.isEmpty) {
      throw DeliveryFailure(_s.targetNotSet, isPermanent: true);
    }
    final cached = _targetChatId;
    if (cached != null && _targetChatIdSource == trimmed) return cached;

    try {
      final int resolved;
      if (trimmed.startsWith('@')) {
        final chat = await _client.send({
          '@type': 'searchPublicChat',
          'username': trimmed.substring(1),
        });
        resolved = (chat['id'] as num?)?.toInt() ?? 0;
      } else {
        final numeric = int.tryParse(trimmed);
        if (numeric == null) {
          throw DeliveryFailure(_s.targetMustBeUsernameOrId, isPermanent: true);
        }
        // Makes sure TDLib knows the chat before we post into it.
        final chat = await _client.send({
          '@type': 'getChat',
          'chat_id': numeric,
        });
        resolved = (chat['id'] as num?)?.toInt() ?? numeric;
      }

      if (resolved == 0) {
        throw DeliveryFailure(_s.targetNotFound, isPermanent: true);
      }
      _targetChatId = resolved;
      _targetChatIdSource = trimmed;
      return resolved;
    } on TdError catch (error) {
      throw _deliveryFailureFrom(error);
    } on TdTimeout {
      throw DeliveryFailure(_s.tdlibNoAnswerTargetLookup);
    }
  }

  /// Maps a TDLib error onto the queue's retry policy.
  DeliveryFailure _deliveryFailureFrom(TdError error) {
    final flood = RegExp(r'FLOOD_WAIT_(\d+)').firstMatch(error.message);
    if (flood != null) {
      return DeliveryFailure(
        error.message,
        retryAfter: Duration(seconds: int.parse(flood.group(1)!)),
      );
    }
    // 400 covers "chat not found", "message not found", "not enough rights";
    // 403 is a plain refusal. Retrying cannot fix any of them.
    final permanent = error.code == 400 || error.code == 403;
    return DeliveryFailure(_humanTdError(error), isPermanent: permanent);
  }

  String _humanTdError(TdError error) {
    final message = error.message;
    if (message.contains('CHAT_WRITE_FORBIDDEN') ||
        message.contains('CHAT_ADMIN_REQUIRED')) {
      return _s.noRightToPost;
    }
    if (message.contains('CHAT_FORWARDS_RESTRICTED')) {
      return _s.sourceForbidsForwarding;
    }
    if (message.contains('Chat not found')) {
      return _s.targetNotFoundCheckId;
    }
    return message;
  }

  /// Writes a delivery outcome to the log and tells the UI about it.
  void _recordStatus(
    int chatId,
    int messageId,
    MatchStatus status,
    String? error,
  ) {
    unawaited(
      _matchLog
          .updateStatus(chatId, messageId, status, error: error)
          .catchError(
            (Object e) => _logger.warn('match log update failed: $e'),
          ),
    );
    _emit(
      Event(Ev.matchStatus, {
        'chatId': chatId,
        'messageId': messageId,
        'status': status.name,
        'error': ?error,
      }),
    );
  }

  void _onForwardStatus(ForwardTask task, MatchStatus status, String? error) {
    _recordStatus(task.chatId, task.messageId, status, error);
    if (status == MatchStatus.failed && error != null) {
      _emit(
        Event(Ev.error, {'scope': ErrorScope.bot, 'code': 0, 'message': error}),
      );
    }
  }

  // --- monitoring lifecycle -----------------------------------------------

  /// Applies edited settings to a running engine.
  ///
  /// Keyword edits must take effect immediately: the owner adding `шахед`
  /// while an alert is in progress cannot be asked to stop and start again.
  /// This also keeps the engine's own copy of the config authoritative, so a
  /// later folder refresh does not write stale keywords back to storage.
  Future<void> updateConfig(MonitorConfig config) async {
    final previousFolderId = _config.folderId;

    // The freshly resolved chat list lives in the engine, not in the UI, so
    // keep it unless the owner actually switched folders.
    final keepChats =
        config.folderId == previousFolderId && config.chats.isEmpty;
    _config = keepChats ? config.copyWith(chats: _config.chats) : config;

    _matcher = KeywordMatcher(_config.keywords);
    // A word that was deleted and typed again should be heard, not held to a
    // cooldown from a life it does not remember.
    final live = {
      for (final keyword in _config.keywords)
        KeywordMatcher.normalize(keyword),
    };
    _lastAlertByKeyword.removeWhere((keyword, _) => !live.contains(keyword));
    await _saveConfig(_config);
    _logger.info(
      'config updated: ${_config.keywords.length} keywords, '
      'folder ${_config.folderId}',
    );

    if (_config.folderId != previousFolderId) {
      _recent.clear();
      _folderChatIds.clear();
      if (_monitoring && _auth == AuthPhase.ready) {
        await _guard('folder', () => _refreshFolder());
      }
    } else if (_config.chats.isNotEmpty) {
      _adoptChats(_config.chats);
    }
    _emitState();
  }

  Future<void> startMonitoring(MonitorConfig config) async {
    _config = config;
    _matcher = KeywordMatcher(config.keywords);
    await _saveConfig(config);
    await _saveMonitoringActive(true);

    _monitoring = true;
    _startedAt = _now();
    _recent.clear();
    // A fresh session starts audible: whoever just pressed «Старт» is holding
    // the phone and wants to hear that it works.
    _lastAlertByKeyword.clear();
    if (config.chats.isNotEmpty) _adoptChats(config.chats);
    _emitState();
    _logger.info(
      'monitoring started: folder ${config.folderId}, '
      '${config.keywords.length} keywords',
    );

    if (_auth == AuthPhase.ready) {
      await _guard('folder', () => _refreshFolder());
    }
  }

  Future<void> stopMonitoring() async {
    _monitoring = false;
    _startedAt = null;
    _forwardQueue.stop();
    await _saveMonitoringActive(false);
    _logger.info('monitoring stopped');
    _emitState();
  }

  /// Called once a minute by the foreground task (spec 7.10).
  Future<void> tick() async {
    final degradedSince = _connectionDegradedSince;
    if (degradedSince != null &&
        _now().difference(degradedSince) > connectionStallTimeout) {
      _logger.warn('connection stalled, nudging with setNetworkType');
      _connectionDegradedSince = _now();
      _client.sendAsync({
        '@type': 'setNetworkType',
        'type': {'@type': 'networkTypeOther'},
      });
    }

    if (_monitoring && _auth == AuthPhase.ready) {
      final last = _lastFolderRefresh;
      if (last == null || _now().difference(last) >= folderRefreshInterval) {
        await _guard('folder', () => _refreshFolder(emitEvent: false));
      }
    }
  }

  // --- commands -----------------------------------------------------------

  Future<void> handleCommand(Command command) async {
    switch (command.cmd) {
      case Cmd.uiAttached:
        _emitState();
        _emitFolders();

      case Cmd.uiDetached:
        break;

      case Cmd.authPhone:
        final phone = command.arg<String>('phone') ?? '';
        await _authRequest({
          '@type': 'setAuthenticationPhoneNumber',
          'phone_number': phone,
        });

      case Cmd.authCode:
        await _authRequest({
          '@type': 'checkAuthenticationCode',
          'code': command.arg<String>('code') ?? '',
        });

      case Cmd.authResend:
        await _authRequest({
          '@type': 'resendAuthenticationCode',
          'reason': {'@type': 'resendCodeReasonUserRequest'},
        });

      case Cmd.authPassword:
        await _authRequest({
          '@type': 'checkAuthenticationPassword',
          'password': command.arg<String>('password') ?? '',
        });

      case Cmd.authLogout:
        await stopMonitoring();
        _loggingOut = true;
        await _authRequest({'@type': 'logOut'});

      case Cmd.foldersList:
        _emitFolders();

      case Cmd.foldersChats:
        final folderId = command.arg<num>('folderId')?.toInt();
        if (folderId == null) return;
        await _guard('folder', () async {
          final chats = await resolveFolder(folderId);
          for (final chat in chats) {
            _chatTitles[chat.id] = chat.title;
          }
          // Looking at the folder we are watching also refreshes what is
          // watched. Adding a channel and then wondering for half an hour why
          // nothing fires is not an acceptable answer.
          if (folderId == _config.folderId) {
            _adoptChats(chats);
            _config = _config.copyWith(chats: chats);
            _lastFolderRefresh = _now();
            await _saveChats(chats);
          }
          _emit(
            Event(Ev.folderChats, {
              'folderId': folderId,
              'items': [for (final chat in chats) chat.toJson()],
            }),
          );
        });

      case Cmd.monitorStart:
        final raw = command.args['config'];
        if (raw is! Map) return;
        await startMonitoring(
          MonitorConfig.fromJson(Map<String, dynamic>.from(raw)),
        );

      case Cmd.monitorStop:
        await stopMonitoring();

      case Cmd.monitorConfig:
        final raw = command.args['config'];
        if (raw is! Map) return;
        await updateConfig(
          MonitorConfig.fromJson(Map<String, dynamic>.from(raw)),
        );

      case Cmd.botTargets:
        await _discoverTargets();

      case Cmd.botCheck:
        await _checkTarget(
          command.arg<String>('targetChatId') ?? _config.targetChatId,
        );

      case Cmd.botTest:
        await _testBot(
          command.arg<String>('targetChatId') ?? _config.targetChatId,
        );

      case Cmd.logGet:
        _emit(Event(Ev.logLines, {'lines': _logger.toJson()}));

      case Cmd.setupExport:
        await _exportSetup();

      case Cmd.setupApply:
        final raw = command.args['payload'];
        if (raw is! Map) return;
        await applySetup(SetupPayload.fromJson(Map<String, dynamic>.from(raw)));

      case Cmd.diagAlert:
        await _diagAlert();

      case Cmd.diagForward:
        await _diagForward();

      case Cmd.diagState:
        _emitDiagState();
    }
  }

  Future<void> _authRequest(Map<String, dynamic> request) async {
    try {
      await _client.send(request);
    } on TdError catch (error) {
      _logger.warn('${request['@type']} rejected: ${error.code}');
      _emit(
        Event(Ev.error, {
          'scope': ErrorScope.auth,
          'code': error.code,
          'message': error.message,
        }),
      );
    } on TdTimeout {
      _emit(
        Event(Ev.error, {
          'scope': ErrorScope.auth,
          'code': 0,
          'message': _s.tdlibNotResponding,
        }),
      );
    }
  }

  /// Finds channels that can serve as the forwarding target.
  ///
  /// Delivery happens through the owner's own session, so the question is
  /// where *they* may publish — every channel they own or administer with the
  /// right to post. No bot is involved.
  Future<void> _discoverTargets() async {
    if (_auth != AuthPhase.ready || _myUserId == 0) {
      _emit(
        Event(Ev.error, {
          'scope': ErrorScope.bot,
          'code': 0,
          'message': _s.signInFirst,
        }),
      );
      return;
    }

    final targets = <ChatRef>[];
    try {
      await _loadAllChats({'@type': 'chatListMain'});
      final response = await _client.send({
        '@type': 'getChats',
        'chat_list': {'@type': 'chatListMain'},
        'limit': 1000,
      });
      final ids = response['chat_ids'];
      if (ids is! List) return;

      for (final rawId in ids) {
        final chatId = (rawId as num?)?.toInt();
        if (chatId == null) continue;

        final Map<String, dynamic> chat;
        try {
          chat = await _client.send({'@type': 'getChat', 'chat_id': chatId});
        } on TdError {
          continue;
        }
        if (!isChannel(chat)) continue;

        try {
          final member = await _client.send({
            '@type': 'getChatMember',
            'chat_id': chatId,
            'member_id': {'@type': 'messageSenderUser', 'user_id': _myUserId},
          }, timeout: const Duration(seconds: 10));
          if (!_canPost(member)) continue;
          targets.add(
            ChatRef(id: chatId, title: chatTitle(chat), isChannel: true),
          );
        } on TdError {
          continue;
        } on TdTimeout {
          continue;
        }
      }
    } catch (error) {
      _logger.warn('target discovery failed: $error');
      _emit(
        Event(Ev.error, {
          'scope': ErrorScope.bot,
          'code': 0,
          'message': _s.couldNotListChannels('$error'),
        }),
      );
      return;
    }

    _logger.info('target discovery found ${targets.length} channels');
    _emit(
      Event(Ev.botTargets, {
        'items': [for (final target in targets) target.toJson()],
      }),
    );
  }

  /// True when this member may publish in the channel.
  static bool _canPost(Map<String, dynamic> member) {
    final status = member['status'];
    if (status is! Map) return false;
    return switch (status['@type']) {
      'chatMemberStatusCreator' => true,
      'chatMemberStatusAdministrator' =>
        status['rights'] is Map &&
            (status['rights'] as Map)['can_post_messages'] == true,
      // A plain member of a channel cannot post; anything else is left/banned.
      _ => false,
    };
  }

  /// Posts a test message down the same path a real alert takes, so this
  /// button verifies what actually matters: that we can publish in the target.
  Future<void> _testBot(String targetChatId) async {
    if (_auth != AuthPhase.ready) {
      _emit(
        Event(Ev.error, {
          'scope': ErrorScope.bot,
          'code': 0,
          'message': _s.signInFirst,
        }),
      );
      return;
    }

    final now = _now();
    final stamp =
        '${now.year}-${_two(now.month)}-${_two(now.day)} '
        '${_two(now.hour)}:${_two(now.minute)}';
    try {
      final targetId = await _resolveTargetChat(targetChatId);
      await _sendText(targetId, _s.testMessageBody(stamp), html: false);
      _logger.info('test message sent');
      _emit(
        Event(Ev.botInfo, {'botName': '', 'chatTitle': _s.testMessageSent}),
      );
    } on DeliveryFailure catch (error) {
      _logger.warn('test message failed: ${error.message}');
      _emit(
        Event(Ev.error, {
          'scope': ErrorScope.bot,
          'code': 0,
          'message': error.message,
        }),
      );
    }
  }

  /// Confirms the target channel is reachable and names it.
  Future<void> _checkTarget(String targetChatId) async {
    if (_auth != AuthPhase.ready) {
      _emit(
        Event(Ev.error, {
          'scope': ErrorScope.bot,
          'code': 0,
          'message': _s.signInFirst,
        }),
      );
      return;
    }
    try {
      final targetId = await _resolveTargetChat(targetChatId);
      final chat = await _client.send({
        '@type': 'getChat',
        'chat_id': targetId,
      });
      _emit(Event(Ev.botInfo, {'botName': '', 'chatTitle': chatTitle(chat)}));
      _logger.info('target chat check ok');
    } on DeliveryFailure catch (error) {
      _emit(
        Event(Ev.error, {
          'scope': ErrorScope.bot,
          'code': 0,
          'message': error.message,
        }),
      );
    } on TdError catch (error) {
      _emit(
        Event(Ev.error, {
          'scope': ErrorScope.bot,
          'code': error.code,
          'message': _humanTdError(error),
        }),
      );
    }
  }

  // --- diagnostics --------------------------------------------------------

  /// What the engine believes it is watching right now.
  ///
  /// The answer to "I added a channel and nothing happens" is almost always
  /// in here: the chat list is resolved once every half hour, so a channel
  /// added a minute ago may simply not be in it yet.
  void _emitDiagState() {
    _emit(
      Event(Ev.diagState, {
        'monitoring': _monitoring,
        'auth': _auth,
        'connection': _connection,
        'folderId': _config.folderId ?? -1,
        'watching': [
          for (final id in _folderChatIds)
            {'id': id, 'title': _chatTitles[id] ?? '$id'},
        ],
        'lastFolderRefresh': _lastFolderRefresh?.toIso8601String(),
        'usesBot': _config.usesBot,
        'delivery': _config.delivery.name,
        // What the engine will actually match against, which is not always
        // what the home screen still has in memory.
        'keywords': _config.keywords,
      }),
    );
  }

  /// Fires the siren, with an entry that never reaches the match log.
  Future<void> _diagAlert() async {
    final entry = MatchEntry(
      time: _now(),
      chatId: 0,
      chatTitle: _s.diagAlertTitle,
      messageId: 0,
      text: _s.diagAlertBody,
      keywords: const ['тест'],
      link: '',
    );
    final error = await _notifyLocally(entry);
    _emitDiagResult(
      error ?? _s.diagAlertFired(_s.matchChannelName),
      ok: error == null,
    );
  }

  /// Delivers the newest message of a watched chat down the real path.
  ///
  /// Deliberately the real path — the same forward or bot post a match would
  /// take — so that a green result here means delivery genuinely works, not
  /// that some separate test code path does.
  Future<void> _diagForward() async {
    if (_auth != AuthPhase.ready) {
      _emitDiagResult(_s.signInFirst, ok: false);
      return;
    }
    if (_folderChatIds.isEmpty) {
      _emitDiagResult(_s.diagNoChats, ok: false);
      return;
    }

    final found = await _newestWatchedMessage();
    if (found == null) {
      _emitDiagResult(_s.diagNoMessages, ok: false);
      return;
    }

    final (chatId, messageId, text) = found;
    final link = await _messageLink(chatId, messageId);
    try {
      final title = _chatTitles[chatId] ?? '$chatId';
      await _deliverTask(
        ForwardTask(
          chatId: chatId,
          messageId: messageId,
          targetChatId: _config.targetChatId,
          link: link,
          html: MessageFormatter.format(
            chatTitle: title,
            keywords: const ['тест'],
            text: text,
            link: link,
            time: _now(),
          ),
          botHtml: MessageFormatter.formatForBot(
            chatTitle: title,
            keywords: const ['тест'],
            text: text,
            link: link,
            time: _now(),
          ),
        ),
      );
      _emitDiagResult(
        _s.diagForwarded(_chatTitles[chatId] ?? '$chatId'),
        ok: true,
      );
    } on DeliveryFailure catch (error) {
      _emitDiagResult(error.message, ok: false);
    } catch (error) {
      _emitDiagResult('$error', ok: false);
    }
  }

  /// The most recent message with text, across the watched chats.
  Future<(int, int, String)?> _newestWatchedMessage() async {
    for (final chatId in _folderChatIds) {
      try {
        final history = await _client.send({
          '@type': 'getChatHistory',
          'chat_id': chatId,
          'from_message_id': 0,
          'offset': 0,
          'limit': 20,
          'only_local': false,
        }, timeout: const Duration(seconds: 20));

        final messages = history['messages'];
        if (messages is! List) continue;
        for (final raw in messages) {
          if (raw is! Map) continue;
          final message = Map<String, dynamic>.from(raw);
          final text = extractText(message['content']);
          final messageId = (message['id'] as num?)?.toInt();
          if (text != null && text.isNotEmpty && messageId != null) {
            return (chatId, messageId, text);
          }
        }
      } catch (error) {
        _logger.warn('diag: history of $chatId failed: $error');
      }
    }
    return null;
  }

  void _emitDiagResult(String message, {required bool ok}) {
    _logger.info('diag: $message');
    _emit(Event(Ev.diagResult, {'ok': ok, 'message': message}));
  }

  // --- setup transfer -----------------------------------------------------

  /// Builds the QR payload out of the configuration in force.
  ///
  /// Only public channels can travel: the receiving account has never seen
  /// these chats, so a numeric id means nothing to its TDLib, and a private
  /// channel has no username to resolve. Those are reported by title so the
  /// owner learns they have to be shared some other way, rather than quietly
  /// going missing on the other phone.
  Future<void> _exportSetup() async {
    if (_auth != AuthPhase.ready) {
      _emitSetupError(_s.signInFirst);
      return;
    }

    final chats = _config.chats.isNotEmpty
        ? _config.chats
        : (_config.folderId == null
              ? const <ChatRef>[]
              : await resolveFolder(_config.folderId!));

    final channels = <SetupChannel>[];
    final skipped = <String>[];

    for (final chat in chats) {
      final username = await _usernameOf(chat.id);
      if (username.isEmpty) {
        skipped.add(chat.title.isEmpty ? '${chat.id}' : chat.title);
        continue;
      }
      channels.add(SetupChannel(username: username, title: chat.title));
    }

    final payload = SetupPayload(
      folderName: _config.folderName,
      channels: channels,
      keywords: _config.keywords,
      maxAgeMinutes: _config.maxAgeMinutes,
    );

    _logger.info(
      'setup exported: ${channels.length} channels, ${skipped.length} private',
    );
    _emit(
      Event(Ev.setupPayload, {'payload': payload.toJson(), 'skipped': skipped}),
    );
  }

  /// Public username of a chat, or an empty string for a private one.
  Future<String> _usernameOf(int chatId) async {
    try {
      final chat = await _client.send({'@type': 'getChat', 'chat_id': chatId});
      final supergroupId = supergroupIdOf(chat);
      if (supergroupId == null) return '';
      final supergroup = await _client.send({
        '@type': 'getSupergroup',
        'supergroup_id': supergroupId,
      }, timeout: const Duration(seconds: 10));
      return supergroupUsername(supergroup);
    } catch (error) {
      _logger.warn('could not read the username of $chatId: $error');
      return '';
    }
  }

  /// Applies a scanned payload to this account.
  ///
  /// Joins whatever the owner is not subscribed to yet, puts everything in a
  /// folder of the same name (creating it, or extending one that already
  /// exists), and switches delivery to local notifications — the second phone
  /// is meant to raise a siren, not to relay into a channel it has no rights
  /// in.
  ///
  /// A channel that cannot be resolved or joined does not abort the run: the
  /// other twenty are worth having, and the failures are reported at the end.
  Future<void> applySetup(SetupPayload payload) async {
    if (_auth != AuthPhase.ready) {
      _emitSetupError(_s.signInFirst);
      return;
    }

    final resolved = <ChatRef>[];
    final failed = <String>[];
    var joined = 0;

    for (var index = 0; index < payload.channels.length; index++) {
      final channel = payload.channels[index];
      _emit(
        Event(Ev.setupProgress, {
          'done': index,
          'total': payload.channels.length,
          'title': channel.title.isEmpty ? channel.username : channel.title,
        }),
      );

      try {
        final chat = await _client.send({
          '@type': 'searchPublicChat',
          'username': channel.username,
        }, timeout: const Duration(seconds: 20));

        final chatId = (chat['id'] as num?)?.toInt();
        if (chatId == null || chatId == 0) {
          failed.add('@${channel.username}');
          continue;
        }

        if (await _joinIfNeeded(chatId, chat)) joined++;
        resolved.add(
          ChatRef(
            id: chatId,
            title: chatTitle(chat),
            isChannel: isChannel(chat),
          ),
        );
      } catch (error) {
        _logger.warn('setup: @${channel.username} failed: $error');
        failed.add('@${channel.username}');
      }
    }

    if (resolved.isEmpty && payload.channels.isNotEmpty) {
      _emitSetupError(_s.setupNothingResolved);
      return;
    }

    final folderId = await _ensureFolder(payload.folderName, resolved);

    await updateConfig(
      _config.copyWith(
        folderId: folderId,
        folderName: payload.folderName,
        keywords: payload.keywords,
        maxAgeMinutes: payload.maxAgeMinutes,
        chats: resolved,
        // The second phone alerts its owner; it has no channel to post into.
        delivery: AlertDelivery.local,
      ),
    );

    _logger.info(
      'setup applied: ${resolved.length} channels ($joined joined), '
      'folder $folderId, ${failed.length} failed',
    );
    _emit(
      Event(Ev.setupDone, {
        'channels': resolved.length,
        'joined': joined,
        'failed': failed,
        'folderId': folderId ?? -1,
      }),
    );
  }

  /// Joins [chatId] unless the account is already in it. Returns whether it
  /// actually joined.
  ///
  /// A chat the account is already in carries a position in some chat list;
  /// one found purely by username search does not. TDLib also answers a
  /// redundant `joinChat` without complaint, so the check is an optimisation
  /// and a truthful count, not a correctness requirement.
  Future<bool> _joinIfNeeded(int chatId, Map<String, dynamic> chat) async {
    final positions = chat['positions'];
    if (positions is List && positions.isNotEmpty) return false;

    try {
      await _client.send({
        '@type': 'joinChat',
        'chat_id': chatId,
      }, timeout: const Duration(seconds: 20));
      return true;
    } on TdError catch (error) {
      if (error.message.contains('USER_ALREADY_PARTICIPANT')) return false;
      rethrow;
    }
  }

  /// Finds the folder by name, or builds it. Returns its id, or `null`.
  ///
  /// An existing folder is extended rather than replaced: the owner may keep
  /// other chats in it, and losing those to a setup transfer would be rude.
  Future<int?> _ensureFolder(String name, List<ChatRef> chats) async {
    final wanted = [for (final chat in chats) chat.id];
    final trimmed = name.trim();
    if (trimmed.isEmpty || wanted.isEmpty) return null;

    try {
      final existing = _folders.where(
        (folder) => folder.name.toLowerCase() == trimmed.toLowerCase(),
      );

      if (existing.isEmpty) {
        final info = await _client.send({
          '@type': 'createChatFolder',
          'folder': _folderRequest(trimmed, wanted),
        }, timeout: const Duration(seconds: 20));
        return (info['id'] as num?)?.toInt();
      }

      final folderId = existing.first.id;
      final current = await _client.send({
        '@type': 'getChatFolder',
        'chat_folder_id': folderId,
      }, timeout: const Duration(seconds: 20));

      final included = <int>[
        for (final id in (current['included_chat_ids'] as List? ?? const []))
          (id as num).toInt(),
      ];
      final merged = <int>[
        ...included,
        for (final id in wanted)
          if (!included.contains(id)) id,
      ];
      if (merged.length == included.length) return folderId;

      await _client.send({
        '@type': 'editChatFolder',
        'chat_folder_id': folderId,
        'folder': {...current, 'included_chat_ids': merged},
      }, timeout: const Duration(seconds: 20));
      return folderId;
    } catch (error) {
      _logger.error('setup: could not build the folder: $error');
      return null;
    }
  }

  /// A `chatFolder` holding exactly [chats] and nothing else.
  static Map<String, dynamic> _folderRequest(String name, List<int> chats) => {
    '@type': 'chatFolder',
    'name': {
      '@type': 'chatFolderName',
      'text': {'@type': 'formattedText', 'text': name, 'entities': []},
      'animate_custom_emoji': false,
    },
    'icon': {'@type': 'chatFolderIcon', 'name': 'Channels'},
    'color_id': -1,
    'is_shareable': false,
    'pinned_chat_ids': <int>[],
    'included_chat_ids': chats,
    'excluded_chat_ids': <int>[],
    'exclude_muted': false,
    'exclude_read': false,
    'exclude_archived': false,
    'include_contacts': false,
    'include_non_contacts': false,
    'include_bots': false,
    'include_groups': false,
    'include_channels': false,
  };

  void _emitSetupError(String message) {
    _logger.warn('setup: $message');
    _emit(
      Event(Ev.error, {
        'scope': ErrorScope.setup,
        'code': 0,
        'message': message,
      }),
    );
    _emit(
      Event(Ev.setupDone, {
        'channels': 0,
        'joined': 0,
        'failed': <String>[],
        'folderId': -1,
        'error': message,
      }),
    );
  }

  static String _two(int value) => value.toString().padLeft(2, '0');

  /// Marks the next `authorizationStateClosed` as expected.
  void markClosing() => _closedIntentionally = true;

  // --- state event --------------------------------------------------------

  Map<String, dynamic> stateJson() => {
    'auth': _auth,
    'authDetail': _authDetail,
    'userName': _userName,
    'connection': _connection,
    'monitoring': _monitoring,
    'startedAt': _startedAt?.toIso8601String(),
    'chatCount': _folderChatIds.length,
    'matchCount': _matchCount,
    'lastMatchAt': _lastMatchAt?.toIso8601String(),
    'tdVersion': _tdVersion,
  };

  void _emitState() => _emit(Event(Ev.state, stateJson()));
}
