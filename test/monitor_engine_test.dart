import 'package:flutter_test/flutter_test.dart';
import 'package:tg_alert_monitor/core/bot/bot_api.dart';
import 'package:tg_alert_monitor/core/ipc/protocol.dart';
import 'package:tg_alert_monitor/core/model/app_config.dart';
import 'package:tg_alert_monitor/core/model/match_entry.dart';
import 'package:tg_alert_monitor/core/model/setup_payload.dart';
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
    this.matchLog,
    this.clock,
    this.events,
    this.savedConfigs,
    this.savedChats,
    this.monitoringFlags,
    this.alerts,
  );

  final FakeTdTransport transport;
  final TdClient client;
  final MonitorEngine engine;
  final FakeMatchSink matchLog;
  final FakeClock clock;
  final List<Event> events;
  final List<MonitorConfig> savedConfigs;

  /// Chat lists written on their own, without the rest of the config.
  final List<List<ChatRef>> savedChats;
  final List<bool> monitoringFlags;

  /// Matches handed to the local notifier.
  final List<MatchEntry> alerts;

  static Future<Harness> create({
    MonitorConfig config = const MonitorConfig(),
    List<int> folderChatIds = const [-100111],
    bool alertsFail = false,
    FakeBotApi? botApi,
  }) async {
    final transport = FakeTdTransport();
    final client = TdClient(
      transport,
      defaultTimeout: const Duration(seconds: 5),
    );
    final matchLog = FakeMatchSink();
    final clock = FakeClock(DateTime.utc(2026, 9, 5, 7, 0));
    final events = <Event>[];
    final savedConfigs = <MonitorConfig>[];
    final savedChats = <List<ChatRef>>[];
    final monitoringFlags = <bool>[];
    final alerts = <MatchEntry>[];

    _installDefaultResponders(transport, folderChatIds);

    final engine = MonitorEngine(
      client: client,
      params: const TdlibParams(
        apiId: 12345,
        apiHash: '0123456789abcdef0123456789abcdef',
        databaseDirectory: '/tmp/db',
        filesDirectory: '/tmp/files',
      ),
      matchLog: matchLog,
      logger: AppLogger(),
      emit: events.add,
      saveConfig: (updated) async => savedConfigs.add(updated),
      saveChats: (chats) async => savedChats.add(chats),
      saveMonitoringActive: (active) async => monitoringFlags.add(active),
      config: config,
      now: clock.call,
      forwardInterval: Duration.zero,
      alert: (entry) async {
        alerts.add(entry);
        if (alertsFail) throw StateError('сирена мовчить');
      },
      botApi: botApi == null
          ? null
          : (token) {
              botApi.tokens.add(token);
              return botApi;
            },
    );

    await engine.start();
    await pumpEventQueue();

    return Harness._(
      transport,
      client,
      engine,
      matchLog,
      clock,
      events,
      savedConfigs,
      savedChats,
      monitoringFlags,
      alerts,
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
      'id': 777,
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
      'type': {
        '@type': 'chatTypeSupergroup',
        'is_channel': true,
        // TDLib derives the chat id from the supergroup id; the fake only has
        // to be self-consistent, so -100111 belongs to supergroup 111.
        'supergroup_id': (request['chat_id'] as num).toInt().abs() % 1000,
      },
    };
    // By default the bot is a posting admin of every channel.
    transport.responders['getChatMember'] = (_) => {
      '@type': 'chatMember',
      'status': {
        '@type': 'chatMemberStatusAdministrator',
        'rights': {'can_post_messages': true},
      },
    };
    transport.responders['forwardMessages'] = (_) => {
      '@type': 'messages',
      'total_count': 1,
      'messages': [
        {'@type': 'message', 'id': 4194304},
      ],
    };
    transport.responders['sendMessage'] = (_) => {
      '@type': 'message',
      'id': 4194304,
    };
    transport.responders['getMessageLink'] = (request) => {
      '@type': 'messageLink',
      'link': 'https://t.me/c/111/${request['message_id']}',
      'is_public': false,
    };
    // Setup transfer: every chat is a public supergroup, and joining works.
    transport.responders['getSupergroup'] = (request) => {
      '@type': 'supergroup',
      'id': request['supergroup_id'],
      'usernames': {
        '@type': 'usernames',
        'active_usernames': ['channel_${request['supergroup_id']}'],
        'editable_username': 'channel_${request['supergroup_id']}',
      },
    };
    transport.responders['searchPublicChat'] = (request) => {
      '@type': 'chat',
      'id': -100777,
      'title': 'Знайдено ${request['username']}',
      'type': {'@type': 'chatTypeSupergroup', 'is_channel': true},
      // No positions: the account is not a member yet.
      'positions': <Object>[],
    };
    transport.responders['joinChat'] = (_) => {'@type': 'ok'};
    transport.responders['createChatFolder'] = (_) => {
      '@type': 'chatFolderInfo',
      'id': 42,
    };
    transport.responders['getChatFolder'] = (_) => {
      '@type': 'chatFolder',
      'included_chat_ids': <int>[-100555],
    };
    transport.responders['editChatFolder'] = (_) => {
      '@type': 'chatFolderInfo',
      'id': 7,
    };
  }

  Future<void> settle() => pumpEventQueue();

  /// Channels the setup run asked TDLib to join.
  List<Map<String, dynamic>> get joins => transport.sentOfType('joinChat');

  /// Originals forwarded through the owner's session.
  List<Map<String, dynamic>> get forwards =>
      transport.sentOfType('forwardMessages');

  /// Messages composed by us: a copy sent when forwarding was refused.
  List<Map<String, dynamic>> get texts => transport.sentOfType('sendMessage');

  String textOf(Map<String, dynamic> request) =>
      ((request['input_message_content'] as Map)['text'] as Map)['text']
          as String;

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

  // --- (g) delivery through a bot -------------------------------------------
  group('bot delivery', () {
    test(
      'with a token the alert is posted by the bot, not forwarded',
      () async {
        final bot = FakeBotApi();
        final config = _runnableConfig.copyWith(botToken: '123:AAA');
        final harness = await Harness.create(config: config, botApi: bot);
        await harness.authenticate();
        await harness.engine.startMonitoring(config);
        await harness.settle();

        harness.transport.push(harness.textMessage(text: 'Шахед над містом'));
        await harness.settle();

        // Nothing goes through the user session at all.
        expect(harness.forwards, isEmpty);
        expect(harness.texts, isEmpty);

        expect(bot.tokens, ['123:AAA']);
        expect(bot.sent, hasLength(1));
        expect(bot.sent.single.chatId, '-100999');
        // The rendering carries the tags and a link back to the original.
        expect(bot.sent.single.html, contains('#шахед'));
        expect(bot.sent.single.html, contains('https://t.me/c/111/1000'));
        // A t.me/c link is private: Telegram builds no preview for it, so the
        // body has to come along or the alert would say nothing.
        expect(bot.sent.single.showPreview, isFalse);
        expect(bot.sent.single.html, contains('Шахед над містом'));
        expect(harness.matchLog.statusUpdates.single.status, MatchStatus.sent);
        await harness.dispose();
      },
    );

    test(
      'a public source is posted as a link for Telegram to preview',
      () async {
        final bot = FakeBotApi();
        final config = _runnableConfig.copyWith(botToken: '123:AAA');
        final harness = await Harness.create(config: config, botApi: bot);
        await harness.authenticate();
        await harness.engine.startMonitoring(config);
        await harness.settle();
        harness.transport.responders['getMessageLink'] = (_) => {
          '@type': 'messageLink',
          'link': 'https://t.me/kyiv_alarm/55',
          'is_public': true,
        };

        harness.transport.push(
          harness.textMessage(text: 'Шахед над містом, дуже довгий допис'),
        );
        await harness.settle();

        final message = bot.sent.single;
        expect(message.showPreview, isTrue);
        expect(message.html, contains('#шахед'));
        expect(message.html, contains('https://t.me/kyiv_alarm/55'));
        // The preview shows the post; repeating it as text is what looked bad.
        expect(message.html, isNot(contains('дуже довгий допис')));
        await harness.dispose();
      },
    );

    test('an empty token keeps the forward path', () async {
      final bot = FakeBotApi();
      final harness = await Harness.create(
        config: _runnableConfig,
        botApi: bot,
      );
      await harness.authenticate();
      await harness.engine.startMonitoring(_runnableConfig);
      await harness.settle();

      harness.transport.push(harness.textMessage(text: 'Шахед над містом'));
      await harness.settle();

      expect(bot.sent, isEmpty);
      expect(harness.forwards, hasLength(1));
      await harness.dispose();
    });

    test('a bot refusal is reported, and 4xx is not retried', () async {
      final bot = FakeBotApi()
        ..failWith = BotApiException(description: 'Forbidden', httpStatus: 403);
      final config = _runnableConfig.copyWith(botToken: '123:AAA');
      final harness = await Harness.create(config: config, botApi: bot);
      await harness.authenticate();
      await harness.engine.startMonitoring(config);
      await harness.settle();

      harness.transport.push(harness.textMessage(text: 'Шахед над містом'));
      await harness.settle();

      expect(bot.sent, isEmpty);
      expect(bot.attempts, 1);
      final update = harness.matchLog.statusUpdates.single;
      expect(update.status, MatchStatus.failed);
      expect(update.error, contains('адміністратором'));
      await harness.dispose();
    });
  });

  // --- (h) diagnostics -------------------------------------------------------
  group('diagnostics', () {
    test('a folder refresh never writes keywords back', () async {
      // The engine refreshes the folder on a timer, from its own copy of the
      // config. If that write carried the keywords, a word the owner added a
      // moment ago in the UI would be silently undone — and the home screen
      // would keep showing it, because it holds its own copy in memory.
      final harness = await Harness.create(config: _runnableConfig);
      await harness.authenticate();
      await harness.engine.startMonitoring(_runnableConfig);
      await harness.settle();
      harness.savedConfigs.clear();
      harness.savedChats.clear();

      await harness.engine.tick();
      await harness.settle();
      harness.clock.advance(const Duration(minutes: 31));
      await harness.engine.tick();
      await harness.settle();

      expect(harness.savedChats, isNotEmpty);
      expect(harness.savedConfigs, isEmpty);
      await harness.dispose();
    });

    test('diag.state carries the keywords in force', () async {
      final harness = await Harness.create(config: _runnableConfig);
      await harness.authenticate();

      await harness.engine.handleCommand(Command(Cmd.diagState));
      await harness.settle();

      expect(harness.eventsOf(Ev.diagState).last.data['keywords'], [
        'шахед',
        'тест-ключ',
      ]);
      await harness.dispose();
    });

    test('diag.state reports what is actually watched', () async {
      final harness = await Harness.create(config: _runnableConfig);
      await harness.authenticate();
      await harness.engine.startMonitoring(_runnableConfig);
      await harness.settle();

      await harness.engine.handleCommand(Command(Cmd.diagState));
      await harness.settle();

      final state = harness.eventsOf(Ev.diagState).last;
      expect(state.data['monitoring'], isTrue);
      expect(state.data['watching'], hasLength(1));
      await harness.dispose();
    });

    test('diag.alert fires the siren without touching the match log', () async {
      final harness = await Harness.create(config: _runnableConfig);
      await harness.authenticate();

      await harness.engine.handleCommand(Command(Cmd.diagAlert));
      await harness.settle();

      expect(harness.alerts, hasLength(1));
      expect(harness.matchLog.appended, isEmpty);
      expect(harness.eventsOf(Ev.diagResult).single.data['ok'], isTrue);
      await harness.dispose();
    });

    test('diag.forward sends the newest watched message for real', () async {
      final harness = await Harness.create(config: _runnableConfig);
      await harness.authenticate();
      await harness.engine.startMonitoring(_runnableConfig);
      await harness.settle();
      harness.transport.responders['getChatHistory'] = (_) => {
        '@type': 'messages',
        'total_count': 1,
        'messages': [
          {
            '@type': 'message',
            'id': 2000,
            'chat_id': -100111,
            'content': {
              '@type': 'messageText',
              'text': {'@type': 'formattedText', 'text': 'Останній допис'},
            },
          },
        ],
      };

      await harness.engine.handleCommand(Command(Cmd.diagForward));
      await harness.settle();

      expect(harness.forwards, hasLength(1));
      expect(harness.forwards.single['message_ids'], [2000]);
      expect(harness.eventsOf(Ev.diagResult).single.data['ok'], isTrue);
      await harness.dispose();
    });

    test('diag.forward says so when there is nothing to send', () async {
      final harness = await Harness.create(config: _runnableConfig);
      await harness.authenticate();
      await harness.engine.startMonitoring(_runnableConfig);
      await harness.settle();
      harness.transport.responders['getChatHistory'] = (_) => {
        '@type': 'messages',
        'total_count': 0,
        'messages': <Object>[],
      };

      await harness.engine.handleCommand(Command(Cmd.diagForward));
      await harness.settle();

      final result = harness.eventsOf(Ev.diagResult).single;
      expect(result.data['ok'], isFalse);
      expect(harness.forwards, isEmpty);
      await harness.dispose();
    });
  });

  // --- (f) setup transfer --------------------------------------------------
  group('setup transfer', () {
    const config = MonitorConfig(
      folderId: 7,
      folderName: 'Тривога',
      keywords: ['шахед', '-відбій'],
      targetChatId: '-100999',
      maxAgeMinutes: 20,
      chats: [
        ChatRef(id: -100111, title: 'Публічний', isChannel: true),
        ChatRef(id: -100222, title: 'Приватний', isChannel: true),
      ],
    );

    SetupPayload payloadOf(Harness harness) {
      final event = harness.eventsOf(Ev.setupPayload).single;
      return SetupPayload.fromJson(
        Map<String, dynamic>.from(event.data['payload'] as Map),
      );
    }

    test('export turns the folder into usernames and keywords', () async {
      final harness = await Harness.create(config: config);
      await harness.authenticate();

      await harness.engine.handleCommand(Command(Cmd.setupExport));
      await harness.settle();

      final payload = payloadOf(harness);
      expect(payload.folderName, 'Тривога');
      expect(payload.keywords, ['шахед', '-відбій']);
      expect(payload.maxAgeMinutes, 20);
      // The chat id is useless on another account; the username is not.
      expect(payload.channels.map((c) => c.username), hasLength(2));
      expect(payload.channels.first.title, 'Публічний');
      await harness.dispose();
    });

    test('a private channel is reported, not silently dropped', () async {
      final harness = await Harness.create(config: config);
      await harness.authenticate();
      // A supergroup with no username at all: a private channel.
      harness.transport.responders['getSupergroup'] = (request) =>
          (request['supergroup_id'] as num).toInt() == 222
          ? {'@type': 'supergroup', 'usernames': null}
          : {
              '@type': 'supergroup',
              'usernames': {
                '@type': 'usernames',
                'editable_username': 'public_one',
              },
            };
      harness.transport.responders['getChat'] = (request) => {
        '@type': 'chat',
        'id': request['chat_id'],
        'title': 'Канал ${request['chat_id']}',
        'type': {
          '@type': 'chatTypeSupergroup',
          'is_channel': true,
          'supergroup_id': (request['chat_id'] as num).toInt() == -100222
              ? 222
              : 111,
        },
      };

      await harness.engine.handleCommand(Command(Cmd.setupExport));
      await harness.settle();

      final event = harness.eventsOf(Ev.setupPayload).single;
      expect(payloadOf(harness).channels, hasLength(1));
      expect(event.data['skipped'], ['Приватний']);
      await harness.dispose();
    });

    test('export before login is refused', () async {
      final harness = await Harness.create(config: config);

      await harness.engine.handleCommand(Command(Cmd.setupExport));
      await harness.settle();

      expect(harness.eventsOf(Ev.setupPayload), isEmpty);
      expect(harness.eventsOf(Ev.error).last.data['scope'], ErrorScope.setup);
      await harness.dispose();
    });

    test('apply joins, builds a folder and switches to local', () async {
      final harness = await Harness.create();
      await harness.authenticate();

      await harness.engine.applySetup(
        const SetupPayload(
          folderName: 'Нова',
          channels: [SetupChannel(username: 'kyiv_alarm', title: 'Київ')],
          keywords: ['шахед'],
          maxAgeMinutes: 15,
        ),
      );
      await harness.settle();

      expect(harness.joins, hasLength(1));
      expect(harness.joins.single['chat_id'], -100777);

      final created = harness.transport.sentOfType('createChatFolder').single;
      final folder = created['folder'] as Map;
      expect(folder['included_chat_ids'], [-100777]);

      final applied = harness.engine.config;
      expect(applied.folderId, 42);
      expect(applied.folderName, 'Нова');
      expect(applied.keywords, ['шахед']);
      expect(applied.maxAgeMinutes, 15);
      // The second phone has no channel of its own to post into.
      expect(applied.delivery, AlertDelivery.local);
      expect(applied.isRunnable, isTrue);

      final done = harness.eventsOf(Ev.setupDone).single;
      expect(done.data['channels'], 1);
      expect(done.data['joined'], 1);
      expect(done.data['failed'], isEmpty);
      await harness.dispose();
    });

    test('a channel already subscribed to is not joined again', () async {
      final harness = await Harness.create();
      await harness.authenticate();
      harness.transport.responders['searchPublicChat'] = (_) => {
        '@type': 'chat',
        'id': -100777,
        'title': 'Вже підписаний',
        'type': {'@type': 'chatTypeSupergroup', 'is_channel': true},
        // A position in a chat list is what membership looks like.
        'positions': [
          {'@type': 'chatPosition', 'order': '1'},
        ],
      };

      await harness.engine.applySetup(
        const SetupPayload(
          folderName: 'Нова',
          channels: [SetupChannel(username: 'kyiv_alarm')],
          keywords: ['шахед'],
        ),
      );
      await harness.settle();

      expect(harness.joins, isEmpty);
      expect(harness.eventsOf(Ev.setupDone).single.data['joined'], 0);
      expect(harness.eventsOf(Ev.setupDone).single.data['channels'], 1);
      await harness.dispose();
    });

    test('one bad channel does not sink the rest', () async {
      final harness = await Harness.create();
      await harness.authenticate();
      harness.transport.responders['searchPublicChat'] = (request) =>
          request['username'] == 'gone'
          ? {'@type': 'error', 'code': 400, 'message': 'USERNAME_NOT_OCCUPIED'}
          : {
              '@type': 'chat',
              'id': -100777,
              'title': 'Живий',
              'type': {'@type': 'chatTypeSupergroup', 'is_channel': true},
              'positions': <Object>[],
            };

      await harness.engine.applySetup(
        const SetupPayload(
          folderName: 'Нова',
          channels: [
            SetupChannel(username: 'gone'),
            SetupChannel(username: 'alive'),
          ],
          keywords: ['шахед'],
        ),
      );
      await harness.settle();

      final done = harness.eventsOf(Ev.setupDone).single;
      expect(done.data['channels'], 1);
      expect(done.data['failed'], ['@gone']);
      expect(harness.engine.config.folderId, 42);
      await harness.dispose();
    });

    test('an existing folder is extended, never replaced', () async {
      final harness = await Harness.create();
      await harness.authenticate();
      // The account already has a folder by that name, holding another chat.
      harness.transport.push({
        '@type': 'updateChatFolders',
        'chat_folders': [
          {
            'id': 7,
            'name': {
              'text': {'text': 'Тривога'},
            },
          },
        ],
      });
      await harness.settle();

      await harness.engine.applySetup(
        const SetupPayload(
          folderName: 'Тривога',
          channels: [SetupChannel(username: 'kyiv_alarm')],
          keywords: ['шахед'],
        ),
      );
      await harness.settle();

      expect(harness.transport.sentOfType('createChatFolder'), isEmpty);
      final edited = harness.transport.sentOfType('editChatFolder').single;
      final folder = edited['folder'] as Map;
      // The chat that was already in the folder survives.
      expect(folder['included_chat_ids'], [-100555, -100777]);
      expect(harness.engine.config.folderId, 7);
      await harness.dispose();
    });

    test('progress is reported per channel', () async {
      final harness = await Harness.create();
      await harness.authenticate();

      await harness.engine.applySetup(
        const SetupPayload(
          folderName: 'Нова',
          channels: [
            SetupChannel(username: 'one', title: 'Перший'),
            SetupChannel(username: 'two', title: 'Другий'),
          ],
          keywords: ['шахед'],
        ),
      );
      await harness.settle();

      final progress = harness.eventsOf(Ev.setupProgress);
      expect(progress, hasLength(2));
      expect(progress.first.data['done'], 0);
      expect(progress.first.data['total'], 2);
      expect(progress.first.data['title'], 'Перший');
      await harness.dispose();
    });

    test('apply before login changes nothing', () async {
      final harness = await Harness.create();

      await harness.engine.applySetup(
        const SetupPayload(
          folderName: 'Нова',
          channels: [SetupChannel(username: 'kyiv_alarm')],
          keywords: ['шахед'],
        ),
      );
      await harness.settle();

      expect(harness.joins, isEmpty);
      expect(harness.engine.config.folderId, isNull);
      expect(harness.eventsOf(Ev.setupDone).single.data['error'], isNotNull);
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

    test('the original is forwarded, and nothing else is posted', () async {
      final harness = await monitoring();

      harness.transport.push(harness.textMessage(text: 'Шахед над містом'));
      await harness.settle();

      // The original goes across as a real forward, not as retyped text.
      expect(harness.forwards, hasLength(1));
      final forward = harness.forwards.single;
      expect(forward['chat_id'], -100999);
      expect(forward['from_chat_id'], -100111);
      expect(forward['message_ids'], [1000]);
      expect(forward['send_copy'], false);

      // The keyword tags stay in the journal; the channel gets the post only.
      expect(harness.texts, isEmpty);

      expect(harness.matchLog.appended, hasLength(1));
      expect(harness.matchLog.appended.single.keywords, ['шахед']);
      expect(harness.eventsOf(Ev.match), hasLength(1));
      expect(harness.engine.matchCount, 1);

      await harness.settle();
      expect(harness.matchLog.statusUpdates.single.status, MatchStatus.sent);
      await harness.dispose();
    });

    test('a channel that forbids forwarding falls back to a copy', () async {
      final harness = await monitoring();
      harness.transport.responders['forwardMessages'] = (_) => {
        '@type': 'error',
        'code': 400,
        'message': 'CHAT_FORWARDS_RESTRICTED',
      };

      harness.transport.push(harness.textMessage(text: 'Шахед над містом'));
      await harness.settle();

      // The alert still arrives, as our own rendering.
      expect(harness.texts, hasLength(1));
      final body = harness.textOf(harness.texts.single);
      expect(body, contains('Шахед над містом'));
      expect(body, contains('#шахед'));
      expect(body, contains('https://t.me/c/111/1000'));
      // Sent as plain text, so no raw markup leaks through.
      expect(body, isNot(contains('<b>')));
      expect(harness.matchLog.statusUpdates.single.status, MatchStatus.sent);
      await harness.dispose();
    });

    test('a target we may not post into is a permanent failure', () async {
      final harness = await monitoring();
      harness.transport.responders['forwardMessages'] = (_) => {
        '@type': 'error',
        'code': 400,
        'message': 'CHAT_WRITE_FORBIDDEN',
      };
      harness.transport.responders['sendMessage'] = (_) => {
        '@type': 'error',
        'code': 400,
        'message': 'CHAT_WRITE_FORBIDDEN',
      };

      harness.transport.push(harness.textMessage(text: 'Шахед над містом'));
      await harness.settle();
      await harness.settle();

      expect(harness.matchLog.statusUpdates.single.status, MatchStatus.failed);
      expect(
        harness.matchLog.statusUpdates.single.error,
        contains('права публікувати'),
      );
      await harness.dispose();
    });

    test('no local alert fires while forwarding', () async {
      final harness = await monitoring();

      harness.transport.push(harness.textMessage(text: 'Шахед над містом'));
      await harness.settle();

      expect(harness.alerts, isEmpty);
      await harness.dispose();
    });

    test('«Локально» notifies and forwards nothing', () async {
      const config = MonitorConfig(
        folderId: 7,
        folderName: 'Тривога',
        keywords: ['шахед'],
        // No target channel at all: local delivery must not need one.
        chats: [ChatRef(id: -100111, title: 'Тест', isChannel: true)],
        delivery: AlertDelivery.local,
      );
      final harness = await Harness.create(config: config);
      await harness.authenticate();
      await harness.engine.startMonitoring(config);
      await harness.settle();

      harness.transport.push(harness.textMessage(text: 'Шахед над містом'));
      await harness.settle();

      expect(harness.alerts, hasLength(1));
      expect(harness.alerts.single.keywords, ['шахед']);
      expect(harness.forwards, isEmpty);
      expect(harness.texts, isEmpty);
      // The notification is the delivery, so it is what marks the entry sent.
      expect(harness.matchLog.statusUpdates.single.status, MatchStatus.sent);
      await harness.dispose();
    });

    test('a siren that fails marks the match failed', () async {
      const config = MonitorConfig(
        folderId: 7,
        keywords: ['шахед'],
        chats: [ChatRef(id: -100111, title: 'Тест', isChannel: true)],
        delivery: AlertDelivery.local,
      );
      final harness = await Harness.create(config: config, alertsFail: true);
      await harness.authenticate();
      await harness.engine.startMonitoring(config);
      await harness.settle();

      harness.transport.push(harness.textMessage(text: 'Шахед над містом'));
      await harness.settle();

      expect(harness.matchLog.statusUpdates.single.status, MatchStatus.failed);
      expect(
        harness.matchLog.statusUpdates.single.error,
        contains('сирена мовчить'),
      );
      await harness.dispose();
    });

    test('the pause out of the box is half a minute', () async {
      const config = MonitorConfig(
        folderId: 7,
        keywords: ['шахед'],
        chats: [ChatRef(id: -100111, title: 'Тест', isChannel: true)],
        delivery: AlertDelivery.local,
      );
      expect(config.alertCooldownSeconds, 30);

      final harness = await Harness.create(config: config);
      await harness.authenticate();
      await harness.engine.startMonitoring(config);
      await harness.settle();

      harness.transport.push(
        harness.textMessage(messageId: 1, text: 'Шахед над містом'),
      );
      await harness.settle();

      // The same channel repeating itself ten seconds later.
      harness.clock.advance(const Duration(seconds: 10));
      harness.transport.push(
        harness.textMessage(messageId: 2, text: 'Шахед над містом'),
      );
      await harness.settle();
      expect(harness.alerts, hasLength(1));

      // Past the half minute it is news again.
      harness.clock.advance(const Duration(seconds: 21));
      harness.transport.push(
        harness.textMessage(messageId: 3, text: 'Шахед над Києвом'),
      );
      await harness.settle();
      expect(harness.alerts, hasLength(2));
      await harness.dispose();
    });

    test('a pause of zero sounds every single match', () async {
      const config = MonitorConfig(
        folderId: 7,
        keywords: ['шахед'],
        chats: [ChatRef(id: -100111, title: 'Тест', isChannel: true)],
        delivery: AlertDelivery.local,
        alertCooldownSeconds: 0,
      );
      final harness = await Harness.create(config: config);
      await harness.authenticate();
      await harness.engine.startMonitoring(config);
      await harness.settle();

      for (var id = 1; id <= 3; id++) {
        harness.transport.push(
          harness.textMessage(messageId: id, text: 'Шахед над містом'),
        );
        await harness.settle();
      }

      expect(harness.alerts, hasLength(3));
      expect(
        harness.matchLog.statusUpdates.map((u) => u.status),
        everyElement(MatchStatus.sent),
      );
      await harness.dispose();
    });

    test('a pause changed in the settings takes effect at once', () async {
      const config = MonitorConfig(
        folderId: 7,
        keywords: ['шахед'],
        chats: [ChatRef(id: -100111, title: 'Тест', isChannel: true)],
        delivery: AlertDelivery.local,
        alertCooldownSeconds: 1800,
      );
      final harness = await Harness.create(config: config);
      await harness.authenticate();
      await harness.engine.startMonitoring(config);
      await harness.settle();

      harness.transport.push(
        harness.textMessage(messageId: 1, text: 'Шахед над містом'),
      );
      await harness.settle();

      // Half an hour was too much, says the owner, and saves 30 seconds.
      await harness.engine.updateConfig(
        config.copyWith(alertCooldownSeconds: 30),
      );
      harness.clock.advance(const Duration(seconds: 31));
      harness.transport.push(
        harness.textMessage(messageId: 2, text: 'Шахед над Києвом'),
      );
      await harness.settle();

      // Without restarting monitoring, and without losing the keyword's own
      // history: the new pause is measured from the alert that did sound.
      expect(harness.alerts, hasLength(2));
      await harness.dispose();
    });

    test('one keyword does not sound twice inside its cooldown', () async {
      const config = MonitorConfig(
        folderId: 7,
        keywords: ['шахед'],
        chats: [ChatRef(id: -100111, title: 'Тест', isChannel: true)],
        delivery: AlertDelivery.local,
        alertCooldownSeconds: 1800,
      );
      final harness = await Harness.create(config: config);
      await harness.authenticate();
      await harness.engine.startMonitoring(config);
      await harness.settle();

      harness.transport.push(
        harness.textMessage(messageId: 1, text: 'Шахед над містом'),
      );
      await harness.settle();

      // A raid: the same channel posts about the same drone four minutes later.
      harness.clock.advance(const Duration(minutes: 4));
      harness.transport.push(
        harness.textMessage(messageId: 2, text: 'Шахед над Києвом'),
      );
      await harness.settle();

      expect(harness.alerts, hasLength(1));
      // Both are still matches, and both are still in the journal.
      expect(harness.matchLog.appended, hasLength(2));
      expect(harness.matchLog.statusUpdates.last.status, MatchStatus.muted);

      // Half an hour on, it matters again.
      harness.clock.advance(const Duration(minutes: 27));
      harness.transport.push(
        harness.textMessage(messageId: 3, text: 'Шахед над містом'),
      );
      await harness.settle();

      expect(harness.alerts, hasLength(2));
      expect(harness.matchLog.statusUpdates.last.status, MatchStatus.sent);
      await harness.dispose();
    });

    test('a second keyword still sounds while the first is quiet', () async {
      const config = MonitorConfig(
        folderId: 7,
        keywords: ['шахед', 'балістика'],
        chats: [ChatRef(id: -100111, title: 'Тест', isChannel: true)],
        delivery: AlertDelivery.local,
        alertCooldownSeconds: 1800,
      );
      final harness = await Harness.create(config: config);
      await harness.authenticate();
      await harness.engine.startMonitoring(config);
      await harness.settle();

      harness.transport.push(
        harness.textMessage(messageId: 1, text: 'Шахед над містом'),
      );
      await harness.settle();
      harness.clock.advance(const Duration(minutes: 1));
      harness.transport.push(
        harness.textMessage(messageId: 2, text: 'Балістика на Київ'),
      );
      await harness.settle();

      // The cooldown is per keyword: a different threat is a different alert.
      expect(harness.alerts, hasLength(2));
      await harness.dispose();
    });

    test('a match that sounds silences every keyword it named', () async {
      const config = MonitorConfig(
        folderId: 7,
        keywords: ['шахед', 'балістика'],
        chats: [ChatRef(id: -100111, title: 'Тест', isChannel: true)],
        delivery: AlertDelivery.local,
        alertCooldownSeconds: 1800,
      );
      final harness = await Harness.create(config: config);
      await harness.authenticate();
      await harness.engine.startMonitoring(config);
      await harness.settle();

      harness.transport.push(
        harness.textMessage(messageId: 1, text: 'Шахед і балістика'),
      );
      await harness.settle();
      harness.clock.advance(const Duration(minutes: 1));
      harness.transport.push(
        harness.textMessage(messageId: 2, text: 'Балістика на Київ'),
      );
      await harness.settle();

      // The alert body listed both words, so the owner has heard about both.
      expect(harness.alerts, hasLength(1));
      await harness.dispose();
    });

    test('a siren that failed does not start a cooldown', () async {
      const config = MonitorConfig(
        folderId: 7,
        keywords: ['шахед'],
        chats: [ChatRef(id: -100111, title: 'Тест', isChannel: true)],
        delivery: AlertDelivery.local,
        alertCooldownSeconds: 1800,
      );
      final harness = await Harness.create(config: config, alertsFail: true);
      await harness.authenticate();
      await harness.engine.startMonitoring(config);
      await harness.settle();

      harness.transport.push(
        harness.textMessage(messageId: 1, text: 'Шахед над містом'),
      );
      await harness.settle();
      harness.clock.advance(const Duration(minutes: 1));
      harness.transport.push(
        harness.textMessage(messageId: 2, text: 'Шахед над Києвом'),
      );
      await harness.settle();

      // Nobody heard the first one, so the second must still try.
      expect(harness.alerts, hasLength(2));
      expect(harness.matchLog.statusUpdates.last.status, MatchStatus.failed);
      await harness.dispose();
    });

    test('a keyword deleted and typed again is heard again', () async {
      const config = MonitorConfig(
        folderId: 7,
        keywords: ['шахед'],
        chats: [ChatRef(id: -100111, title: 'Тест', isChannel: true)],
        delivery: AlertDelivery.local,
        alertCooldownSeconds: 1800,
      );
      final harness = await Harness.create(config: config);
      await harness.authenticate();
      await harness.engine.startMonitoring(config);
      await harness.settle();

      harness.transport.push(
        harness.textMessage(messageId: 1, text: 'Шахед над містом'),
      );
      await harness.settle();

      // The owner removes the word and puts it back — plausibly to fix a typo.
      await harness.engine.updateConfig(
        config.copyWith(keywords: const ['балістика']),
      );
      await harness.engine.updateConfig(config);
      harness.clock.advance(const Duration(minutes: 1));
      harness.transport.push(
        harness.textMessage(messageId: 2, text: 'Шахед над Києвом'),
      );
      await harness.settle();

      expect(harness.alerts, hasLength(2));
      await harness.dispose();
    });

    test('the cooldown holds back the siren, never the forward', () async {
      final config = _runnableConfig.copyWith(
        delivery: AlertDelivery.both,
        alertCooldownSeconds: 1800,
      );
      final harness = await Harness.create(config: config);
      await harness.authenticate();
      await harness.engine.startMonitoring(config);
      await harness.settle();

      harness.transport.push(
        harness.textMessage(messageId: 1, text: 'Шахед над містом'),
      );
      await harness.settle();
      harness.clock.advance(const Duration(minutes: 1));
      harness.transport.push(
        harness.textMessage(messageId: 2, text: 'Шахед над Києвом'),
      );
      await harness.settle();

      expect(harness.alerts, hasLength(1));
      // The channel is where the raid is recorded for other people; holding a
      // message back from it would lose information nobody gets back.
      expect(harness.forwards, hasLength(2));
      await harness.dispose();
    });

    test('«Обидва» does both, and the forward owns the status', () async {
      final config = _runnableConfig.copyWith(delivery: AlertDelivery.both);
      final harness = await Harness.create(config: config);
      await harness.authenticate();
      await harness.engine.startMonitoring(config);
      await harness.settle();

      harness.transport.push(harness.textMessage(text: 'Шахед над містом'));
      await harness.settle();

      expect(harness.alerts, hasLength(1));
      expect(harness.forwards, hasLength(1));
      // One update only: the notification does not race the queue for it.
      expect(harness.matchLog.statusUpdates, hasLength(1));
      expect(harness.matchLog.statusUpdates.single.status, MatchStatus.sent);
      await harness.dispose();
    });

    test('the owner\'s own post in a watched channel matches', () async {
      // TDLib marks a post as outgoing when the owner made it. A channel the
      // owner runs is the obvious way to test the app, and used to be the one
      // case where nothing whatsoever happened.
      final harness = await monitoring();

      harness.transport.push(
        harness.textMessage(text: 'Шахед над містом', isOutgoing: true),
      );
      await harness.settle();

      expect(harness.matchLog.appended, hasLength(1));
      expect(harness.forwards, hasLength(1));
      await harness.dispose();
    });

    test('our own post in the target channel is ignored', () async {
      // Loop prevention, which is all the outgoing check was ever for.
      final harness = await Harness.create(
        config: _runnableConfig,
        folderChatIds: [-100111, -100999],
      );
      await harness.authenticate();
      await harness.engine.startMonitoring(
        _runnableConfig.copyWith(
          chats: const [
            ChatRef(id: -100111, title: 'Джерело', isChannel: true),
            ChatRef(id: -100999, title: 'Ціль', isChannel: true),
          ],
        ),
      );
      await harness.settle();

      harness.transport.push(
        harness.textMessage(
          chatId: -100999,
          text: 'Шахед над містом',
          isOutgoing: true,
        ),
      );
      await harness.settle();

      expect(harness.matchLog.appended, isEmpty);
      expect(harness.forwards, isEmpty);
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

      expect(harness.forwards, hasLength(1));
      await harness.dispose();
    });

    test('messages that must be ignored produce no sends', () async {
      for (final scenario in <(String, Map<String, dynamic> Function(Harness))>[
        (
          'chat outside the folder',
          (h) => h.textMessage(chatId: -100999999, messageId: 1),
        ),
        // An outgoing message is NOT here on purpose: the owner's own post in
        // a watched channel is a real match. Only the target chat is ignored,
        // which the two tests above cover.
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

        expect(harness.forwards, isEmpty, reason: scenario.$1);
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

      expect(harness.forwards, isEmpty);
      await harness.dispose();
    });

    test('the same message delivered twice forwards only once', () async {
      final harness = await monitoring();

      harness.transport.push(harness.textMessage(messageId: 7777));
      await harness.settle();
      harness.transport.push(harness.textMessage(messageId: 7777));
      await harness.settle();

      expect(harness.forwards, hasLength(1));
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

      expect(harness.forwards, hasLength(1));
      await harness.dispose();
    });

    test('a failed getMessageLink falls back to the public username', () async {
      // Every getMessageLink call was failing on the device, which sent every
      // alert down the t.me/c form — and Telegram previews nothing behind
      // /c/, so the bot's link preview was lost for public channels too.
      final harness = await monitoring();
      harness.transport.responders['getMessageLink'] = (_) => {
        '@type': 'error',
        'code': 400,
        'message': 'MESSAGE_ID_INVALID',
      };

      // 55 << 20 is how TDLib encodes server message id 55.
      harness.transport.push(harness.textMessage(messageId: 55 << 20));
      await harness.settle();

      // channel_111 is the fake's username for the supergroup behind -100111.
      expect(
        harness.matchLog.appended.single.link,
        'https://t.me/channel_111/55',
      );
      await harness.dispose();
    });

    test('a private chat falls back to the t.me/c form', () async {
      final harness = await monitoring();
      harness.transport.responders['getMessageLink'] = (_) => {
        '@type': 'error',
        'code': 400,
        'message': 'MESSAGE_ID_INVALID',
      };
      // No username at all: nothing better than the private form exists.
      harness.transport.responders['getSupergroup'] = (_) => {
        '@type': 'supergroup',
        'usernames': null,
      };

      harness.transport.push(harness.textMessage(messageId: 55 << 20));
      await harness.settle();

      expect(harness.matchLog.appended.single.link, 'https://t.me/c/111/55');
      await harness.dispose();
    });

    test(
      'getMessageLink is asked with only the fields every schema has',
      () async {
        // The optional ones differ between TDLib releases, and one of them is a
        // string in 1.8.65 — sending it as a number failed every call.
        final harness = await monitoring();

        harness.transport.push(harness.textMessage(text: 'Шахед над містом'));
        await harness.settle();

        final request = harness.transport.sentOfType('getMessageLink').single;
        expect(request.keys.toSet(), {
          '@type',
          'chat_id',
          'message_id',
          '@extra',
        });
        await harness.dispose();
      },
    );
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
      expect(harness.forwards, hasLength(1));

      await harness.engine.handleCommand(Command(Cmd.monitorStop));
      await harness.settle();

      harness.transport.push(harness.textMessage(messageId: 2));
      await harness.settle();

      expect(harness.forwards, hasLength(1));
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

      expect(harness.forwards, isEmpty);
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
  group('target channel commands', () {
    test('bot.check names the target channel', () async {
      final harness = await Harness.create(config: _runnableConfig);
      await harness.authenticate();

      await harness.engine.handleCommand(
        Command(Cmd.botCheck, {'targetChatId': '-100999'}),
      );
      await harness.settle();

      expect(
        harness.eventsOf(Ev.botInfo).last.field<String>('chatTitle'),
        'Канал -100999',
      );
      await harness.dispose();
    });

    test('bot.check reports a target we cannot reach', () async {
      final harness = await Harness.create(config: _runnableConfig);
      await harness.authenticate();
      harness.transport.responders['getChat'] = (_) => {
        '@type': 'error',
        'code': 400,
        'message': 'Chat not found',
      };

      await harness.engine.handleCommand(
        Command(Cmd.botCheck, {'targetChatId': '-100999'}),
      );
      await harness.settle();

      expect(
        harness.eventsOf(Ev.error).last.field<String>('message'),
        contains('не знайдено'),
      );
      await harness.dispose();
    });

    test('bot.test posts down the real delivery path', () async {
      final harness = await Harness.create(config: _runnableConfig);
      await harness.authenticate();

      await harness.engine.handleCommand(
        Command(Cmd.botTest, {'targetChatId': '-100999'}),
      );
      await harness.settle();

      // Sent through the owner's session, exactly like a real alert.
      expect(harness.texts, hasLength(1));
      expect(harness.texts.single['chat_id'], -100999);
      expect(
        harness.textOf(harness.texts.single),
        contains('TG Alert Monitor'),
      );
      await harness.dispose();
    });

    test('a @username target is resolved before posting', () async {
      final harness = await Harness.create(config: _runnableConfig);
      await harness.authenticate();
      harness.transport.responders['searchPublicChat'] = (_) => {
        '@type': 'chat',
        'id': -100777,
        'title': 'Публічний канал',
      };

      await harness.engine.handleCommand(
        Command(Cmd.botTest, {'targetChatId': '@alerts'}),
      );
      await harness.settle();

      expect(
        harness.transport.sentOfType('searchPublicChat').single['username'],
        'alerts',
      );
      expect(harness.texts.single['chat_id'], -100777);
      await harness.dispose();
    });

    test('a test before login is refused with a clear reason', () async {
      final harness = await Harness.create(config: _runnableConfig);

      await harness.engine.handleCommand(
        Command(Cmd.botTest, {'targetChatId': '-100999'}),
      );
      await harness.settle();

      expect(harness.texts, isEmpty);
      expect(
        harness.eventsOf(Ev.error).last.field<String>('message'),
        contains('увійдіть у Telegram'),
      );
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
