import 'package:flutter_test/flutter_test.dart';
import 'package:tg_alert_monitor/core/bot/bot_api.dart';
import 'package:tg_alert_monitor/core/ipc/protocol.dart';
import 'package:tg_alert_monitor/core/model/app_config.dart';
import 'package:tg_alert_monitor/core/model/match_entry.dart';
import 'package:tg_alert_monitor/core/td/td_client.dart';
import 'package:tg_alert_monitor/core/util/app_logger.dart';
import 'package:tg_alert_monitor/service/monitor_engine.dart';

import 'fakes/fakes.dart';

/// Test rig: engine plus every fake it was built from.
class Harness {
  Harness._(
    this.transport,
    this.client,
    this.engine,
    this.bot,
    this.matchLog,
    this.clock,
    this.events,
    this.savedConfigs,
    this.monitoringFlags,
  );

  final FakeTdTransport transport;
  final TdClient client;
  final MonitorEngine engine;
  final FakeBotApi bot;
  final FakeMatchSink matchLog;
  final FakeClock clock;
  final List<Event> events;
  final List<MonitorConfig> savedConfigs;
  final List<bool> monitoringFlags;

  static Future<Harness> create({
    MonitorConfig config = const MonitorConfig(),
    List<int> folderChatIds = const [-100111],
  }) async {
    final transport = FakeTdTransport();
    final client = TdClient(
      transport,
      defaultTimeout: const Duration(seconds: 5),
    );
    final bot = FakeBotApi();
    final matchLog = FakeMatchSink();
    final clock = FakeClock(DateTime.utc(2026, 9, 5, 7, 0));
    final events = <Event>[];
    final savedConfigs = <MonitorConfig>[];
    final monitoringFlags = <bool>[];

    _installDefaultResponders(transport, folderChatIds);

    final engine = MonitorEngine(
      client: client,
      params: const TdlibParams(
        apiId: 12345,
        apiHash: '0123456789abcdef0123456789abcdef',
        databaseDirectory: '/tmp/db',
        filesDirectory: '/tmp/files',
      ),
      botApiFactory: (_) => bot,
      matchLog: matchLog,
      logger: AppLogger(),
      emit: events.add,
      saveConfig: (updated) async => savedConfigs.add(updated),
      saveMonitoringActive: (active) async => monitoringFlags.add(active),
      config: config,
      now: clock.call,
      forwardInterval: Duration.zero,
    );

    await engine.start();
    await pumpEventQueue();

    return Harness._(
      transport,
      client,
      engine,
      bot,
      matchLog,
      clock,
      events,
      savedConfigs,
      monitoringFlags,
    );
  }

  static void _installDefaultResponders(
    FakeTdTransport transport,
    List<int> folderChatIds,
  ) {
    transport.responders['getOption'] = (_) => {
      '@type': 'optionValueString',
      'value': '1.8.65',
    };
    transport.responders['setTdlibParameters'] = (_) => {'@type': 'ok'};
    transport.responders['setAuthenticationPhoneNumber'] = (_) => {
      '@type': 'ok',
    };
    transport.responders['checkAuthenticationCode'] = (_) => {'@type': 'ok'};
    transport.responders['checkAuthenticationPassword'] = (_) => {
      '@type': 'ok',
    };
    transport.responders['resendAuthenticationCode'] = (_) => {
      '@type': 'authenticationCodeInfo',
    };
    transport.responders['logOut'] = (_) => {'@type': 'ok'};
    transport.responders['getMe'] = (_) => {
      '@type': 'user',
      'first_name': 'Вадим',
      'last_name': 'А',
    };
    // Every loadChats page reports "nothing more to load".
    transport.responders['loadChats'] = (_) => {
      '@type': 'error',
      'code': 404,
      'message': 'Not Found',
    };
    transport.responders['getChats'] = (_) => {
      '@type': 'chats',
      'chat_ids': folderChatIds,
    };
    transport.responders['getChat'] = (request) => {
      '@type': 'chat',
      'id': request['chat_id'],
      'title': 'Канал ${request['chat_id']}',
      'type': {'@type': 'chatTypeSupergroup', 'is_channel': true},
    };
    transport.responders['getMessageLink'] = (request) => {
      '@type': 'messageLink',
      'link': 'https://t.me/c/111/${request['message_id']}',
      'is_public': false,
    };
  }

  Future<void> settle() => pumpEventQueue();

  List<Event> eventsOf(String name) => [
    for (final event in events)
      if (event.ev == name) event,
  ];

  Event? get lastState =>
      eventsOf(Ev.state).isEmpty ? null : eventsOf(Ev.state).last;

  /// Drives the auth state machine all the way to `ready`.
  Future<void> authenticate() async {
    transport.pushAuthState({'@type': 'authorizationStateWaitTdlibParameters'});
    await settle();
    transport.pushAuthState({'@type': 'authorizationStateWaitPhoneNumber'});
    await settle();
    transport.pushAuthState({'@type': 'authorizationStateReady'});
    await settle();
  }

  Map<String, dynamic> textMessage({
    int chatId = -100111,
    int messageId = 1000,
    String text = 'шахед над містом',
    bool isOutgoing = false,
    DateTime? date,
  }) => {
    '@type': 'updateNewMessage',
    'message': {
      '@type': 'message',
      'id': messageId,
      'chat_id': chatId,
      'is_outgoing': isOutgoing,
      'date': ((date ?? clock()).millisecondsSinceEpoch / 1000).round(),
      'content': {
        '@type': 'messageText',
        'text': {'@type': 'formattedText', 'text': text},
      },
    },
  };

  Future<void> dispose() async {
    await engine.dispose();
    await client.close();
  }
}

const MonitorConfig _runnableConfig = MonitorConfig(
  folderId: 7,
  folderName: 'Тривога',
  keywords: ['шахед', 'тест-ключ'],
  botToken: '123456:AAxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx',
  targetChatId: '-100999',
  maxAgeMinutes: 10,
  chats: [ChatRef(id: -100111, title: 'Тест', isChannel: true)],
);

void main() {
  // --- (a) authentication --------------------------------------------------
  group('(a) authorization flow', () {
    test('reads the TDLib version on start', () async {
      final harness = await Harness.create();
      expect(harness.engine.tdVersion, '1.8.65');
      expect(harness.lastState?.field<String>('tdVersion'), '1.8.65');
      await harness.dispose();
    });

    test('answers waitTdlibParameters with setTdlibParameters', () async {
      final harness = await Harness.create();
      harness.transport.pushAuthState({
        '@type': 'authorizationStateWaitTdlibParameters',
      });
      await harness.settle();

      final request = harness.transport.sentOfType('setTdlibParameters').single;
      expect(request['api_id'], 12345);
      expect(request['api_hash'], '0123456789abcdef0123456789abcdef');
      expect(request['use_file_database'], false);
      expect(request['use_message_database'], true);
      expect(request['use_secret_chats'], false);
      expect(request['database_directory'], '/tmp/db');
      expect(harness.engine.authPhase, AuthPhase.init);
      await harness.dispose();
    });

    test('each auth state maps to the documented phase and detail', () async {
      final harness = await Harness.create();

      harness.transport.pushAuthState({
        '@type': 'authorizationStateWaitPhoneNumber',
      });
      await harness.settle();
      expect(harness.engine.authPhase, AuthPhase.waitPhone);

      harness.transport.pushAuthState({
        '@type': 'authorizationStateWaitCode',
        'code_info': {
          'type': {'@type': 'authenticationCodeTypeTelegramMessage'},
        },
      });
      await harness.settle();
      expect(harness.engine.authPhase, AuthPhase.waitCode);
      expect(
        harness.lastState?.field<String>('authDetail'),
        contains('Telegram'),
      );

      harness.transport.pushAuthState({
        '@type': 'authorizationStateWaitPassword',
        'password_hint': 'дівоче прізвище',
      });
      await harness.settle();
      expect(harness.engine.authPhase, AuthPhase.waitPassword);
      expect(harness.lastState?.field<String>('authDetail'), 'дівоче прізвище');

      await harness.dispose();
    });

    test('auth commands produce the matching TDLib requests', () async {
      final harness = await Harness.create();

      await harness.engine.handleCommand(
        Command(Cmd.authPhone, {'phone': '+380501112233'}),
      );
      expect(
        harness.transport
            .sentOfType('setAuthenticationPhoneNumber')
            .single['phone_number'],
        '+380501112233',
      );

      await harness.engine.handleCommand(
        Command(Cmd.authCode, {'code': '54321'}),
      );
      expect(
        harness.transport.sentOfType('checkAuthenticationCode').single['code'],
        '54321',
      );

      await harness.engine.handleCommand(Command(Cmd.authResend));
      expect(
        harness.transport
            .sentOfType('resendAuthenticationCode')
            .single['reason']['@type'],
        'resendCodeReasonUserRequest',
      );

      await harness.engine.handleCommand(
        Command(Cmd.authPassword, {'password': 'hunter2'}),
      );
      expect(
        harness.transport
            .sentOfType('checkAuthenticationPassword')
            .single['password'],
        'hunter2',
      );

      await harness.dispose();
    });

    test('ready triggers getMe and loads the main chat list', () async {
      final harness = await Harness.create();
      await harness.authenticate();

      expect(harness.engine.authPhase, AuthPhase.ready);
      expect(harness.transport.hasSent('getMe'), isTrue);
      expect(harness.lastState?.field<String>('userName'), 'Вадим А');
      final loadChats = harness.transport.sentOfType('loadChats');
      expect(loadChats, isNotEmpty);
      expect(loadChats.first['chat_list']['@type'], 'chatListMain');
      await harness.dispose();
    });

    test('a rejected code is reported as an auth error event', () async {
      final harness = await Harness.create();
      harness.transport.responders['checkAuthenticationCode'] = (_) => {
        '@type': 'error',
        'code': 400,
        'message': 'PHONE_CODE_INVALID',
      };

      await harness.engine.handleCommand(
        Command(Cmd.authCode, {'code': '00000'}),
      );
      await harness.settle();

      final error = harness.eventsOf(Ev.error).last;
      expect(error.field<String>('scope'), ErrorScope.auth);
      expect(error.field<String>('message'), 'PHONE_CODE_INVALID');
      await harness.dispose();
    });

    test('an unsupported login scenario is surfaced, not ignored', () async {
      final harness = await Harness.create();
      harness.transport.pushAuthState({
        '@type': 'authorizationStateWaitRegistration',
      });
      await harness.settle();

      expect(harness.engine.authPhase, AuthPhase.unsupported);
      expect(
        harness.lastState?.field<String>('authDetail'),
        'authorizationStateWaitRegistration',
      );
      await harness.dispose();
    });

    test('an unexpected close asks the owner to rebuild the client', () async {
      final harness = await Harness.create();
      var deadCalls = 0;
      harness.engine.onClientDead = () => deadCalls++;

      harness.transport.pushAuthState({'@type': 'authorizationStateClosed'});
      await harness.settle();

      expect(harness.engine.authPhase, AuthPhase.closed);
      expect(deadCalls, 1);
      await harness.dispose();
    });

    test(
      'a close after an explicit logout does not trigger a rebuild',
      () async {
        final harness = await Harness.create();
        var deadCalls = 0;
        harness.engine.onClientDead = () => deadCalls++;

        await harness.engine.handleCommand(Command(Cmd.authLogout));
        harness.transport.pushAuthState({'@type': 'authorizationStateClosed'});
        await harness.settle();

        expect(harness.transport.hasSent('logOut'), isTrue);
        expect(deadCalls, 0);
        await harness.dispose();
      },
    );
  });

  // --- (b) folder resolution -----------------------------------------------
  group('(b) folder resolution', () {
    test('updateChatFolders is turned into a folders event', () async {
      final harness = await Harness.create();
      harness.transport.push({
        '@type': 'updateChatFolders',
        'chat_folders': [
          {
            'id': 7,
            'name': {
              '@type': 'chatFolderName',
              'text': {'@type': 'formattedText', 'text': 'Тривога'},
            },
          },
          {
            'id': 8,
            'name': {
              '@type': 'chatFolderName',
              'text': {'@type': 'formattedText', 'text': 'Робота'},
            },
          },
        ],
      });
      await harness.settle();

      final folders = harness.eventsOf(Ev.folders).last;
      expect(folders.data['items'], [
        {'id': 7, 'name': 'Тривога'},
        {'id': 8, 'name': 'Робота'},
      ]);
      await harness.dispose();
    });

    test(
      'resolveFolder loads pages until 404, then getChats and getChat',
      () async {
        final harness = await Harness.create(
          folderChatIds: const [-100111, -100222],
        );

        var loadCalls = 0;
        harness.transport.responders['loadChats'] = (_) {
          loadCalls++;
          // Two successful pages, then "nothing left".
          if (loadCalls <= 2) return {'@type': 'ok'};
          return {'@type': 'error', 'code': 404, 'message': 'Not Found'};
        };

        final chats = await harness.engine.resolveFolder(7);

        expect(loadCalls, 3);
        final loadRequests = harness.transport.sentOfType('loadChats');
        expect(loadRequests.first['chat_list'], {
          '@type': 'chatListFolder',
          'chat_folder_id': 7,
        });
        expect(loadRequests.first['limit'], 100);

        final getChats = harness.transport.sentOfType('getChats').single;
        expect(getChats['chat_list']['chat_folder_id'], 7);
        expect(getChats['limit'], 1000);

        expect(harness.transport.sentOfType('getChat'), hasLength(2));
        expect(chats.map((c) => c.id), [-100111, -100222]);
        expect(chats.first.title, 'Канал -100111');
        expect(chats.every((c) => c.isChannel), isTrue);

        await harness.dispose();
      },
    );

    test('folders.chats command emits folderChats', () async {
      final harness = await Harness.create();
      await harness.engine.handleCommand(
        Command(Cmd.foldersChats, {'folderId': 7}),
      );
      await harness.settle();

      final event = harness.eventsOf(Ev.folderChats).last;
      expect(event.field<num>('folderId')?.toInt(), 7);
      expect(event.data['items'], [
        {'id': -100111, 'title': 'Канал -100111', 'isChannel': true},
      ]);
      await harness.dispose();
    });

    test('a failing getChat still yields a chat entry', () async {
      final harness = await Harness.create();
      harness.transport.responders['getChat'] = (_) => {
        '@type': 'error',
        'code': 400,
        'message': 'CHANNEL_PRIVATE',
      };

      final chats = await harness.engine.resolveFolder(7);
      expect(chats, hasLength(1));
      expect(chats.single.id, -100111);
      await harness.dispose();
    });
  });

  // --- (c) message pipeline ------------------------------------------------
  group('(c) message pipeline', () {
    Future<Harness> monitoring() async {
      final harness = await Harness.create(config: _runnableConfig);
      await harness.authenticate();
      await harness.engine.startMonitoring(_runnableConfig);
      await harness.settle();
      return harness;
    }

    test('a keyword hit in a folder chat is forwarded once', () async {
      final harness = await monitoring();

      harness.transport.push(harness.textMessage(text: 'Шахед над містом'));
      await harness.settle();

      expect(harness.bot.sentMessages, hasLength(1));
      final sent = harness.bot.sentMessages.single;
      expect(sent.chatId, '-100999');
      expect(sent.html, contains('Шахед над містом'));
      expect(sent.html, contains('шахед'));
      expect(sent.html, contains('https://t.me/c/111/1000'));
      expect(sent.html, contains('<b>'));

      expect(harness.matchLog.appended, hasLength(1));
      expect(harness.matchLog.appended.single.keywords, ['шахед']);
      expect(harness.eventsOf(Ev.match), hasLength(1));
      expect(harness.engine.matchCount, 1);

      await harness.settle();
      expect(harness.matchLog.statusUpdates.single.status, MatchStatus.sent);
      await harness.dispose();
    });

    test('a caption on a photo matches too', () async {
      final harness = await monitoring();

      harness.transport.push({
        '@type': 'updateNewMessage',
        'message': {
          'id': 2000,
          'chat_id': -100111,
          'is_outgoing': false,
          'date': (harness.clock().millisecondsSinceEpoch / 1000).round(),
          'content': {
            '@type': 'messagePhoto',
            'caption': {'@type': 'formattedText', 'text': 'Шахед над містом'},
          },
        },
      });
      await harness.settle();

      expect(harness.bot.sentMessages, hasLength(1));
      await harness.dispose();
    });

    test('messages that must be ignored produce no sends', () async {
      for (final scenario in <(String, Map<String, dynamic> Function(Harness))>[
        (
          'chat outside the folder',
          (h) => h.textMessage(chatId: -100999999, messageId: 1),
        ),
        (
          'outgoing message',
          (h) => h.textMessage(messageId: 2, isOutgoing: true),
        ),
        (
          'older than maxAge',
          (h) => h.textMessage(
            messageId: 3,
            date: h.clock().subtract(const Duration(minutes: 30)),
          ),
        ),
        (
          'no keyword',
          (h) => h.textMessage(messageId: 4, text: 'просто текст'),
        ),
      ]) {
        final harness = await monitoring();
        harness.transport.push(scenario.$2(harness));
        await harness.settle();

        expect(harness.bot.sentMessages, isEmpty, reason: scenario.$1);
        expect(harness.matchLog.appended, isEmpty, reason: scenario.$1);
        await harness.dispose();
      }
    });

    test('a message with no text at all is ignored', () async {
      final harness = await monitoring();
      harness.transport.push({
        '@type': 'updateNewMessage',
        'message': {
          'id': 5,
          'chat_id': -100111,
          'is_outgoing': false,
          'date': (harness.clock().millisecondsSinceEpoch / 1000).round(),
          'content': {'@type': 'messageSticker'},
        },
      });
      await harness.settle();

      expect(harness.bot.sentMessages, isEmpty);
      await harness.dispose();
    });

    test('the same message delivered twice forwards only once', () async {
      final harness = await monitoring();

      harness.transport.push(harness.textMessage(messageId: 7777));
      await harness.settle();
      harness.transport.push(harness.textMessage(messageId: 7777));
      await harness.settle();

      expect(harness.bot.sentMessages, hasLength(1));
      expect(harness.matchLog.appended, hasLength(1));
      await harness.dispose();
    });

    test('an edit of an already forwarded message is not re-sent', () async {
      final harness = await monitoring();

      harness.transport.push(harness.textMessage(messageId: 8888));
      await harness.settle();
      harness.transport.push({
        '@type': 'updateMessageContent',
        'chat_id': -100111,
        'message_id': 8888,
        'new_content': {
          '@type': 'messageText',
          'text': {'@type': 'formattedText', 'text': 'шахед знову'},
        },
      });
      await harness.settle();

      expect(harness.bot.sentMessages, hasLength(1));
      await harness.dispose();
    });

    test('a failed getMessageLink falls back to a t.me/c link', () async {
      final harness = await monitoring();
      harness.transport.responders['getMessageLink'] = (_) => {
        '@type': 'error',
        'code': 400,
        'message': 'MESSAGE_ID_INVALID',
      };

      // 55 << 20 is how TDLib encodes server message id 55.
      harness.transport.push(harness.textMessage(messageId: 55 << 20));
      await harness.settle();

      expect(harness.matchLog.appended.single.link, 'https://t.me/c/111/55');
      await harness.dispose();
    });

    test('a permanent Bot API failure is recorded as failed', () async {
      final harness = await monitoring();
      harness.bot.sendError = BotApiException(
        description: 'Forbidden',
        httpStatus: 403,
      );

      harness.transport.push(harness.textMessage(messageId: 9999));
      await harness.settle();
      await harness.settle();

      expect(harness.matchLog.statusUpdates.single.status, MatchStatus.failed);
      final statusEvent = harness.eventsOf(Ev.matchStatus).last;
      expect(statusEvent.field<String>('status'), 'failed');
      expect(
        harness.eventsOf(Ev.error).last.field<String>('scope'),
        ErrorScope.bot,
      );
      await harness.dispose();
    });
  });

  // --- (d) stop ------------------------------------------------------------
  group('(d) monitoring lifecycle', () {
    test('after monitor.stop new messages are ignored', () async {
      final harness = await Harness.create(config: _runnableConfig);
      await harness.authenticate();
      await harness.engine.startMonitoring(_runnableConfig);
      await harness.settle();

      harness.transport.push(harness.textMessage(messageId: 1));
      await harness.settle();
      expect(harness.bot.sentMessages, hasLength(1));

      await harness.engine.handleCommand(Command(Cmd.monitorStop));
      await harness.settle();

      harness.transport.push(harness.textMessage(messageId: 2));
      await harness.settle();

      expect(harness.bot.sentMessages, hasLength(1));
      expect(harness.engine.isMonitoring, isFalse);
      expect(harness.monitoringFlags.last, isFalse);
      await harness.dispose();
    });

    test(
      'starting monitoring persists the config and the active flag',
      () async {
        final harness = await Harness.create();
        await harness.authenticate();

        await harness.engine.handleCommand(
          Command(Cmd.monitorStart, {'config': _runnableConfig.toJson()}),
        );
        await harness.settle();

        expect(harness.engine.isMonitoring, isTrue);
        expect(harness.monitoringFlags, contains(true));
        expect(harness.savedConfigs.last.folderId, 7);
        expect(harness.savedConfigs.last.keywords, ['шахед', 'тест-ключ']);
        await harness.dispose();
      },
    );

    test('messages arriving before start are not forwarded', () async {
      final harness = await Harness.create(config: _runnableConfig);
      await harness.authenticate();

      harness.transport.push(harness.textMessage());
      await harness.settle();

      expect(harness.bot.sentMessages, isEmpty);
      await harness.dispose();
    });
  });

  // --- (e) folder membership changes and the watchdog ----------------------
  group('(e) resilience', () {
    test('updateChatPosition for our folder re-resolves it', () async {
      final harness = await Harness.create(config: _runnableConfig);
      await harness.authenticate();
      await harness.engine.startMonitoring(_runnableConfig);
      await harness.settle();

      harness.transport.clearSent();
      harness.transport.push({
        '@type': 'updateChatPosition',
        'chat_id': -100222,
        'position': {
          '@type': 'chatPosition',
          'list': {'@type': 'chatListFolder', 'chat_folder_id': 7},
        },
      });
      await harness.settle();

      expect(harness.transport.hasSent('getChats'), isTrue);
      await harness.dispose();
    });

    test('updateChatPosition for another folder is ignored', () async {
      final harness = await Harness.create(config: _runnableConfig);
      await harness.authenticate();
      await harness.engine.startMonitoring(_runnableConfig);
      await harness.settle();

      harness.transport.clearSent();
      harness.transport.push({
        '@type': 'updateChatPosition',
        'chat_id': -100222,
        'position': {
          'list': {'@type': 'chatListFolder', 'chat_folder_id': 99},
        },
      });
      harness.transport.push({
        '@type': 'updateChatPosition',
        'chat_id': -100222,
        'position': {
          'list': {'@type': 'chatListMain'},
        },
      });
      await harness.settle();

      expect(harness.transport.hasSent('getChats'), isFalse);
      await harness.dispose();
    });

    test('connection state changes are mirrored', () async {
      final harness = await Harness.create();

      for (final pair in const [
        ('connectionStateWaitingForNetwork', ConnectionPhase.waitingForNetwork),
        ('connectionStateConnecting', ConnectionPhase.connecting),
        ('connectionStateUpdating', ConnectionPhase.updating),
        ('connectionStateReady', ConnectionPhase.ready),
      ]) {
        harness.transport.push({
          '@type': 'updateConnectionState',
          'state': {'@type': pair.$1},
        });
        await harness.settle();
        expect(harness.engine.connectionPhase, pair.$2);
      }
      await harness.dispose();
    });

    test('a long stall nudges TDLib with setNetworkType', () async {
      final harness = await Harness.create();

      harness.transport.push({
        '@type': 'updateConnectionState',
        'state': {'@type': 'connectionStateWaitingForNetwork'},
      });
      await harness.settle();

      // Well inside the stall timeout: no nudge yet.
      harness.clock.advance(const Duration(seconds: 30));
      await harness.engine.tick();
      expect(harness.transport.hasSent('setNetworkType'), isFalse);

      harness.clock.advance(const Duration(minutes: 5));
      await harness.engine.tick();
      expect(harness.transport.hasSent('setNetworkType'), isTrue);
      expect(
        harness.transport.sentOfType('setNetworkType').single['type']['@type'],
        'networkTypeOther',
      );
      await harness.dispose();
    });

    test('a healthy connection is never nudged', () async {
      final harness = await Harness.create();
      harness.transport.push({
        '@type': 'updateConnectionState',
        'state': {'@type': 'connectionStateReady'},
      });
      await harness.settle();

      harness.clock.advance(const Duration(hours: 2));
      await harness.engine.tick();

      expect(harness.transport.hasSent('setNetworkType'), isFalse);
      await harness.dispose();
    });

    test('the folder is re-resolved on schedule while monitoring', () async {
      final harness = await Harness.create(config: _runnableConfig);
      await harness.authenticate();
      await harness.engine.startMonitoring(_runnableConfig);
      await harness.settle();

      harness.transport.clearSent();
      harness.clock.advance(const Duration(minutes: 5));
      await harness.engine.tick();
      expect(harness.transport.hasSent('getChats'), isFalse);

      harness.clock.advance(const Duration(minutes: 31));
      await harness.engine.tick();
      await harness.settle();
      expect(harness.transport.hasSent('getChats'), isTrue);
      await harness.dispose();
    });
  });

  // --- bot checks ----------------------------------------------------------
  group('bot commands', () {
    test('bot.check reports the bot and channel names', () async {
      final harness = await Harness.create();
      await harness.engine.handleCommand(
        Command(Cmd.botCheck, {'botToken': '1:aa', 'targetChatId': '-100999'}),
      );
      await harness.settle();

      final info = harness.eventsOf(Ev.botInfo).last;
      expect(info.field<String>('botName'), 'Test Bot');
      expect(info.field<String>('chatTitle'), 'Target');
      await harness.dispose();
    });

    test('bot.check surfaces a bad token as a bot-scoped error', () async {
      final harness = await Harness.create();
      harness.bot.getMeError = BotApiException(
        description: 'Unauthorized',
        httpStatus: 401,
      );

      await harness.engine.handleCommand(
        Command(Cmd.botCheck, {'botToken': 'bad', 'targetChatId': '-1'}),
      );
      await harness.settle();

      final error = harness.eventsOf(Ev.error).last;
      expect(error.field<String>('scope'), ErrorScope.bot);
      expect(error.field<String>('message'), contains('Невірний токен'));
      await harness.dispose();
    });

    test('bot.test posts a test message', () async {
      final harness = await Harness.create();
      await harness.engine.handleCommand(
        Command(Cmd.botTest, {'botToken': '1:aa', 'targetChatId': '-100999'}),
      );
      await harness.settle();

      expect(
        harness.bot.sentMessages.single.html,
        contains('TG Alert Monitor'),
      );
      expect(harness.bot.sentMessages.single.chatId, '-100999');
      await harness.dispose();
    });
  });

  group('log command', () {
    test('log.get returns the buffered system log', () async {
      final harness = await Harness.create();
      await harness.engine.handleCommand(Command(Cmd.logGet));
      await harness.settle();

      final lines = harness.eventsOf(Ev.logLines).last.data['lines'];
      expect(lines, isA<List<dynamic>>());
      expect(lines as List<dynamic>, isNotEmpty);
      await harness.dispose();
    });
  });
}
