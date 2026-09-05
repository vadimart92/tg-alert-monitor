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
import '../core/storage/match_log.dart';
import '../core/td/td_client.dart';
import '../core/td/td_json.dart';
import '../core/util/app_logger.dart';

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
    required this._botApiFactory,
    required this._matchLog,
    required this._logger,
    required this._emit,
    required this._saveConfig,
    required this._saveMonitoringActive,
    MonitorConfig config = const MonitorConfig(),
    DateTime Function()? now,
    this.folderRefreshInterval = const Duration(minutes: 30),
    this.connectionStallTimeout = const Duration(minutes: 2),
    Duration forwardInterval = const Duration(milliseconds: 1500),
  }) : _config = config,
       _now = now ?? DateTime.now {
    _matcher = KeywordMatcher(config.keywords);
    _forwardQueue = ForwardQueue(
      apiProvider: () => _botApiFactory(_config.botToken),
      minInterval: forwardInterval,
      onLog: _logger.info,
      onStatus: _onForwardStatus,
    );
  }

  final TdClient _client;
  final TdlibParams _params;
  final BotApiFactory _botApiFactory;
  final MatchSink _matchLog;
  final AppLogger _logger;
  final void Function(Event event) _emit;
  final Future<void> Function(MonitorConfig config) _saveConfig;
  final Future<void> Function(bool active) _saveMonitoringActive;
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

  final List<FolderRef> _folders = <FolderRef>[];
  final Set<int> _folderChatIds = <int>{};
  final Map<int, String> _chatTitles = <int, String>{};
  final _RecentMessages _recent = _RecentMessages(2000);

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
  static String _codeTypeLabel(Object? codeInfo) {
    if (codeInfo is! Map) return '';
    final type = codeInfo['type'];
    if (type is! Map) return '';
    return switch (type['@type']) {
      'authenticationCodeTypeTelegramMessage' =>
        'Код надіслано в Telegram на іншому пристрої',
      'authenticationCodeTypeSms' ||
      'authenticationCodeTypeSmsWord' ||
      'authenticationCodeTypeSmsPhrase' => 'Код надіслано в SMS',
      'authenticationCodeTypeCall' => 'Код продиктують у дзвінку',
      'authenticationCodeTypeFlashCall' ||
      'authenticationCodeTypeMissedCall' => 'Очікуйте дзвінок',
      'authenticationCodeTypeFragment' => 'Код надіслано у Fragment',
      _ => '',
    };
  }

  Future<void> _onReady() async {
    try {
      final me = await _client.send({'@type': 'getMe'});
      final first = me['first_name'] as String? ?? '';
      final last = me['last_name'] as String? ?? '';
      _userName = [first, last].where((p) => p.isNotEmpty).join(' ');
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
    await _saveConfig(_config);
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
    if (message['is_outgoing'] == true) return;

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

    _forwardQueue.enqueue(
      ForwardTask(
        chatId: chatId,
        messageId: messageId,
        targetChatId: _config.targetChatId,
        html: MessageFormatter.format(
          chatTitle: entry.chatTitle,
          keywords: keywords,
          text: text,
          link: link,
          time: entry.time,
        ),
      ),
    );
  }

  Future<String> _messageLink(int chatId, int messageId) async {
    try {
      final response = await _client.send({
        '@type': 'getMessageLink',
        'chat_id': chatId,
        'message_id': messageId,
        'media_timestamp': 0,
        'checklist_task_id': 0,
        'poll_option_id': 0,
        'for_album': false,
        'in_message_thread': false,
      }, timeout: const Duration(seconds: 10));
      final link = response['link'];
      if (link is String && link.isNotEmpty) return link;
    } catch (error) {
      _logger.warn('getMessageLink failed for $chatId/$messageId: $error');
    }
    return fallbackLink(chatId, serverMessageId(messageId));
  }

  void _onForwardStatus(ForwardTask task, MatchStatus status, String? error) {
    unawaited(
      _matchLog
          .updateStatus(task.chatId, task.messageId, status, error: error)
          .catchError(
            (Object e) => _logger.warn('match log update failed: $e'),
          ),
    );
    _emit(
      Event(Ev.matchStatus, {
        'chatId': task.chatId,
        'messageId': task.messageId,
        'status': status.name,
        'error': ?error,
      }),
    );
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
    _logger.addSecret(_config.botToken);
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
    _logger.addSecret(config.botToken);
    await _saveConfig(config);
    await _saveMonitoringActive(true);

    _monitoring = true;
    _startedAt = _now();
    _recent.clear();
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
        await _discoverTargets(
          command.arg<String>('botToken') ?? _config.botToken,
        );

      case Cmd.botCheck:
        await _checkBot(
          command.arg<String>('botToken') ?? _config.botToken,
          command.arg<String>('targetChatId') ?? _config.targetChatId,
        );

      case Cmd.botTest:
        await _testBot(
          command.arg<String>('botToken') ?? _config.botToken,
          command.arg<String>('targetChatId') ?? _config.targetChatId,
        );

      case Cmd.logGet:
        _emit(Event(Ev.logLines, {'lines': _logger.toJson()}));
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
          'message': 'TDLib не відповідає',
        }),
      );
    }
  }

  Future<void> _checkBot(String token, String targetChatId) async {
    _logger.addSecret(token);
    try {
      final api = _botApiFactory(token);
      final bot = await api.getMe();
      final chatTitle = await api.getChat(targetChatId);
      _emit(
        Event(Ev.botInfo, {'botName': bot.displayName, 'chatTitle': chatTitle}),
      );
      _logger.info('bot check ok');
    } on BotApiException catch (error) {
      _logger.warn('bot check failed: ${error.description}');
      _emit(
        Event(Ev.error, {
          'scope': ErrorScope.bot,
          'code': error.httpStatus ?? 0,
          'message': error.userMessage,
        }),
      );
    }
  }

  /// Finds channels that can serve as the forwarding target.
  ///
  /// The Bot API deliberately offers no "list my chats" call, so discovery
  /// runs through the owner's own TDLib session instead: walk the channels the
  /// account knows about and ask whether this bot is a member. That works
  /// regardless of when the bot was added, unlike scraping `getUpdates`, which
  /// only reaches back 24 hours.
  ///
  /// Requires the owner to be an administrator of the channel — otherwise
  /// Telegram will not answer `getChatMember`, and the channel is skipped.
  Future<void> _discoverTargets(String token) async {
    if (_auth != AuthPhase.ready) {
      _emit(
        Event(Ev.error, {
          'scope': ErrorScope.bot,
          'code': 0,
          'message': 'Спочатку увійдіть у Telegram.',
        }),
      );
      return;
    }

    _logger.addSecret(token);
    final BotIdentity bot;
    try {
      bot = await _botApiFactory(token).getMe();
    } on BotApiException catch (error) {
      _emit(
        Event(Ev.error, {
          'scope': ErrorScope.bot,
          'code': error.httpStatus ?? 0,
          'message': error.userMessage,
        }),
      );
      return;
    }

    if (bot.id <= 0) {
      _emit(
        Event(Ev.error, {
          'scope': ErrorScope.bot,
          'code': 0,
          'message': 'Не вдалося визначити id бота.',
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
            'member_id': {'@type': 'messageSenderUser', 'user_id': bot.id},
          }, timeout: const Duration(seconds: 10));
          if (!_botCanPost(member)) continue;
          targets.add(
            ChatRef(id: chatId, title: chatTitle(chat), isChannel: true),
          );
        } on TdError {
          // Not an admin of this channel, or the bot is not in it.
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
          'message': 'Не вдалося отримати список каналів: $error',
        }),
      );
      return;
    }

    _logger.info('target discovery found ${targets.length} channels');
    _emit(
      Event(Ev.botTargets, {
        'botName': bot.displayName,
        'items': [for (final target in targets) target.toJson()],
      }),
    );
  }

  /// True when the bot is in the chat and allowed to publish there.
  static bool _botCanPost(Map<String, dynamic> member) {
    final status = member['status'];
    if (status is! Map) return false;
    return switch (status['@type']) {
      'chatMemberStatusCreator' => true,
      'chatMemberStatusAdministrator' =>
        (status['rights'] is Map &&
            (status['rights'] as Map)['can_post_messages'] == true),
      // A plain member of a channel cannot post; anything else is left/banned.
      _ => false,
    };
  }

  Future<void> _testBot(String token, String targetChatId) async {
    _logger.addSecret(token);
    final now = _now();
    final stamp =
        '${now.year}-${_two(now.month)}-${_two(now.day)} '
        '${_two(now.hour)}:${_two(now.minute)}';
    try {
      await _botApiFactory(token).sendMessage(
        chatId: targetChatId,
        html: '✅ TG Alert Monitor: тест, $stamp',
      );
      _logger.info('test message sent');
      _emit(Event(Ev.botInfo, {'botName': '', 'chatTitle': 'Тест надіслано'}));
    } on BotApiException catch (error) {
      _logger.warn('test message failed: ${error.description}');
      _emit(
        Event(Ev.error, {
          'scope': ErrorScope.bot,
          'code': error.httpStatus ?? 0,
          'message': error.userMessage,
        }),
      );
    }
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
