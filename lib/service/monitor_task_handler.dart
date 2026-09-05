/// The foreground-service side of the app.
///
/// TDLib lives here and nowhere else: the UI isolate dies when the user swipes
/// the app away, this one keeps running.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:path_provider/path_provider.dart';

import '../core/ipc/protocol.dart';
import '../core/storage/match_log.dart';
import '../core/storage/settings_store.dart';
import '../core/td/td_client.dart';
import '../core/td/td_native.dart';
import '../core/td/td_transport.dart';
import '../core/util/app_logger.dart';
import 'alert_notifier.dart';
import 'monitor_engine.dart';

/// Service entry point. Must stay top level and annotated.
@pragma('vm:entry-point')
void startCallback() {
  FlutterForegroundTask.setTaskHandler(MonitorTaskHandler());
}

class MonitorTaskHandler extends TaskHandler {
  static const Duration _selfStopDelay = Duration(seconds: 60);

  /// Id of the "Стоп" action in the ongoing notification.
  static const String stopButtonId = 'stop_monitoring';

  AppLogger? _logger;
  MatchLog? _matchLog;
  AlertNotifier? _notifier;
  TdClient? _client;
  MonitorEngine? _engine;

  String? _nativeVersion;
  DateTime? _detachedAt;
  bool _restarting = false;
  Future<void>? _bootstrapFuture;
  String _lastNotificationText = '';
  bool? _lastNotificationHadStopButton;

  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {
    final logger = AppLogger(
      onLine: (line) => _send(Event(Ev.log, line.toJson())),
      printer: kDebugMode ? debugPrint : null,
    );
    _logger = logger;
    logger.info('service started by ${starter.name}');

    try {
      await _ensureBootstrapped();
    } catch (error, stack) {
      logger.error('service bootstrap failed: $error');
      debugPrintStack(stackTrace: stack);
      _send(
        Event(Ev.error, {
          'scope': ErrorScope.service,
          'code': 0,
          'message': '$error',
        }),
      );
    }
  }

  /// Runs [_bootstrap] at most once at a time.
  ///
  /// `onStart` and a `ui.attached` arriving moments later would otherwise race
  /// and build two TDLib clients over one database, which TDLib forbids.
  Future<void> _ensureBootstrapped() async {
    final inFlight = _bootstrapFuture;
    if (inFlight != null) return inFlight;

    final future = _bootstrap();
    _bootstrapFuture = future;
    try {
      await future;
    } finally {
      // A bootstrap that produced no engine (missing credentials, or a
      // failure) may be retried once the owner fills in the settings.
      if (_engine == null) _bootstrapFuture = null;
    }
  }

  Future<void> _bootstrap() async {
    final logger = _logger!;

    // Written by the UI isolate, so the cache here must be refreshed.
    final settings = await SettingsStore.open();
    await settings.reload();
    logger.addSecret(settings.apiHash);

    final supportDir = await getApplicationSupportDirectory();
    final tdRoot = Directory('${supportDir.path}/tdlib');
    await tdRoot.create(recursive: true);
    _matchLog = MatchLog(File('${supportDir.path}/matches.jsonl'));

    final config = settings.readConfig();

    // The alert channel is registered up front so its sound is in place before
    // the first match, and so a permission problem shows up in the log now.
    // Survives a TDLib restart: the channel only has to be created once.
    final notifier = _notifier ??= AlertNotifier(onLog: logger.warn);
    unawaited(
      notifier.init().catchError(
        (Object error) => logger.warn('alert channel setup failed: $error'),
      ),
    );

    // Prove the native library loads before anything depends on it: a missing
    // or unusable libtdjson.so must be visible in the log immediately, not
    // only once the owner has entered credentials.
    _configureTdLogging(tdRoot.path);

    final credentials = settings.credentials;
    if (!credentials.isValid) {
      logger.warn('api_id/api_hash are not set yet; waiting for settings');
      _send(Event(Ev.state, _emptyState()));
      return;
    }

    final transport = await IsolateTdTransport.start(
      onFatal: (message) {
        logger.error('receive isolate: $message');
        unawaited(_restartClient());
      },
    );
    final client = TdClient(transport);
    _client = client;

    final engine = MonitorEngine(
      client: client,
      params: TdlibParams(
        apiId: credentials.apiId,
        apiHash: credentials.apiHash,
        databaseDirectory: '${tdRoot.path}/db',
        filesDirectory: '${tdRoot.path}/files',
        systemVersion: 'Android ${Platform.operatingSystemVersion}',
        applicationVersion: '1.0.0',
      ),
      matchLog: _matchLog!,
      logger: logger,
      emit: _send,
      config: config,
      saveConfig: (updated) async {
        await settings.reload();
        await settings.writeConfig(updated);
      },
      saveMonitoringActive: settings.setMonitoringActive,
      alert: notifier.notify,
    );
    engine.onClientDead = () => unawaited(_restartClient());
    _engine = engine;

    await engine.start();

    if (settings.monitoringActive && config.isRunnable) {
      logger.info('monitoringActive was set; resuming after restart');
      await engine.startMonitoring(config);
      await _updateNotification(engine);
    }
  }

  /// TDLib writes its own log to a rotating file, never to stderr.
  void _configureTdLogging(String tdRoot) {
    try {
      final native = TdNative.instance();
      native.execute(
        '{"@type":"setLogVerbosityLevel","new_verbosity_level":2}',
      );
      native.execute(
        '{"@type":"setLogStream","log_stream":{"@type":"logStreamFile",'
        '"path":"$tdRoot/td.log","max_file_size":5242880,'
        '"redirect_stderr":false}}',
      );
      // getOption is one of the few requests TDLib answers synchronously.
      final raw = native.execute('{"@type":"getOption","name":"version"}');
      _nativeVersion = _parseOptionValue(raw);
      _logger?.info('libtdjson loaded, tdlib ${_nativeVersion ?? "?"} ($raw)');
    } catch (error) {
      _logger?.error('could not configure TDLib logging: $error');
      rethrow;
    }
  }

  Map<String, dynamic> _emptyState() => {
    'auth': AuthPhase.init,
    'authDetail': 'Не задано api_id / api_hash',
    'userName': '',
    'connection': ConnectionPhase.connecting,
    'monitoring': false,
    'startedAt': null,
    'chatCount': 0,
    'matchCount': 0,
    'lastMatchAt': null,
    'tdVersion': _nativeVersion ?? '',
  };

  /// Pulls `value` out of `{"@type":"optionValueString","value":"1.8.65"}`.
  static String? _parseOptionValue(String? raw) {
    if (raw == null) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      final value = decoded['value'];
      return value is String && value.isNotEmpty ? value : null;
    } catch (_) {
      return null;
    }
  }

  void _send(Event event) {
    try {
      FlutterForegroundTask.sendDataToMain(event.encode());
    } catch (_) {
      // No UI attached — expected while running headless.
    }
  }

  /// Rebuilds the TDLib client after a fatal transport failure.
  Future<void> _restartClient() async {
    if (_restarting) return;
    _restarting = true;
    _logger?.warn('restarting TDLib client');
    try {
      await _engine?.dispose();
      await _client?.close();
      _engine = null;
      _client = null;
      _bootstrapFuture = null;
      await Future<void>.delayed(const Duration(seconds: 3));
      await _ensureBootstrapped();
    } catch (error) {
      _logger?.error('client restart failed: $error');
    } finally {
      _restarting = false;
    }
  }

  @override
  void onRepeatEvent(DateTime timestamp) {
    unawaited(_onTick());
  }

  Future<void> _onTick() async {
    final engine = _engine;
    if (engine == null) return;

    try {
      await engine.tick();
    } catch (error) {
      _logger?.warn('tick failed: $error');
    }

    await _updateNotification(engine);

    // Nothing to monitor and nobody watching: release the service.
    final detachedAt = _detachedAt;
    if (!engine.isMonitoring &&
        detachedAt != null &&
        DateTime.now().difference(detachedAt) > _selfStopDelay) {
      _logger?.info('idle with no UI attached; stopping service');
      await _shutdown();
      await FlutterForegroundTask.stopService();
    }
  }

  Future<void> _updateNotification(MonitorEngine engine) async {
    final connection = switch (engine.connectionPhase) {
      ConnectionPhase.ready => 'онлайн',
      ConnectionPhase.updating => 'оновлення',
      ConnectionPhase.waitingForNetwork => 'немає мережі',
      _ => 'підключення',
    };
    final text = engine.isMonitoring
        ? 'Моніторинг • ${engine.chatCount} чатів • '
              '${engine.matchCount} збігів • $connection'
        : 'Моніторинг зупинено • $connection';

    // A "Стоп" action is only meaningful while something is running.
    final showStop = engine.isMonitoring;
    if (text == _lastNotificationText &&
        showStop == _lastNotificationHadStopButton) {
      return;
    }
    _lastNotificationText = text;
    _lastNotificationHadStopButton = showStop;
    try {
      await FlutterForegroundTask.updateService(
        notificationTitle: 'TG Alert Monitor',
        notificationText: text,
        notificationButtons: showStop ? _stopButtons : const [],
      );
    } catch (error) {
      _logger?.warn('notification update failed: $error');
    }
  }

  static const List<NotificationButton> _stopButtons = [
    NotificationButton(id: stopButtonId, text: 'Стоп'),
  ];

  @override
  void onNotificationButtonPressed(String id) {
    if (id != stopButtonId) return;
    _logger?.info('stop pressed in notification');
    unawaited(_stopFromNotification());
  }

  /// Stops monitoring without tearing the service down: the owner can start it
  /// again from the app, and `monitoringActive` is cleared so a reboot does not
  /// silently resume.
  Future<void> _stopFromNotification() async {
    final engine = _engine;
    if (engine == null) return;
    try {
      await engine.stopMonitoring();
      await _updateNotification(engine);
    } catch (error) {
      _logger?.error('stop from notification failed: $error');
    }
  }

  @override
  void onReceiveData(Object data) {
    unawaited(_handleData(data));
  }

  Future<void> _handleData(Object data) async {
    final Command command;
    try {
      command = Command.decode(data);
    } catch (error) {
      _logger?.warn('ignored malformed command: $error');
      return;
    }

    if (command.cmd == Cmd.uiAttached) _detachedAt = null;
    if (command.cmd == Cmd.uiDetached) _detachedAt = DateTime.now();

    final engine = _engine;
    if (engine == null) {
      // Settings may have arrived after a failed bootstrap; retry once.
      if (command.cmd == Cmd.uiAttached) {
        _send(Event(Ev.state, _emptyState()));
        await _ensureBootstrapped().catchError(
          (Object error) => _logger?.error('late bootstrap failed: $error'),
        );
      }
      return;
    }

    try {
      await engine.handleCommand(command);
      // Reflect a start/stop in the notification now rather than on the next
      // one-minute tick.
      if (command.cmd == Cmd.monitorStart || command.cmd == Cmd.monitorStop) {
        await _updateNotification(engine);
      }
    } catch (error) {
      _logger?.error('command ${command.cmd} failed: $error');
    }
  }

  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {
    _logger?.info('service destroyed (timeout: $isTimeout)');
    await _shutdown();
  }

  Future<void> _shutdown() async {
    final engine = _engine;
    final client = _client;
    engine?.markClosing();
    await engine?.dispose();

    if (client != null) {
      try {
        // Give TDLib a chance to flush its database before the isolate dies.
        await client
            .send({'@type': 'close'}, timeout: const Duration(seconds: 5))
            .catchError((Object _) => <String, dynamic>{});
        await Future<void>.delayed(const Duration(milliseconds: 500));
      } catch (_) {
        // Best effort only.
      }
      await client.close();
    }

    _engine = null;
    _client = null;
  }

  @override
  void onNotificationPressed() => FlutterForegroundTask.launchApp();
}
