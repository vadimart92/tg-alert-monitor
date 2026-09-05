/// UI-side view of the foreground service.
///
/// Owns the only channel to the service isolate and exposes its state as a
/// [ChangeNotifier] so screens can rebuild with `ListenableBuilder`.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

import '../core/ipc/protocol.dart';
import '../core/model/app_config.dart';
import '../core/model/match_entry.dart';
import '../core/util/app_logger.dart';
import '../l10n/app_localizations.dart';
import '../service/monitor_engine.dart';
import '../service/monitor_task_handler.dart';

class ServiceError {
  const ServiceError(this.scope, this.code, this.message, this.at);
  final String scope;
  final int code;
  final String message;
  final DateTime at;
}

class ServiceBridge extends ChangeNotifier {
  ServiceBridge() {
    FlutterForegroundTask.addTaskDataCallback(_onData);
  }

  // --- mirrored service state ---------------------------------------------
  String auth = AuthPhase.init;
  String authDetail = '';
  String userName = '';
  String connection = ConnectionPhase.connecting;
  bool monitoring = false;
  DateTime? startedAt;
  int chatCount = 0;
  int matchCount = 0;
  DateTime? lastMatchAt;
  String tdVersion = '';

  List<FolderRef> folders = const <FolderRef>[];
  Map<int, List<ChatRef>> folderChats = <int, List<ChatRef>>{};
  List<MatchEntry> matches = <MatchEntry>[];
  List<LogLine> logLines = <LogLine>[];

  ServiceError? lastError;
  String? botName;
  String? botChatTitle;

  /// Channels the bot can post to, for the target picker. Null until a
  /// discovery run has finished at least once.
  List<ChatRef>? botTargets;
  bool discoveringTargets = false;
  bool serviceRunning = false;

  bool get isReady => auth == AuthPhase.ready;

  // --- lifecycle ----------------------------------------------------------

  /// Configures the foreground task. Must run before [ensureServiceRunning].
  ///
  /// Takes its strings from the caller because the channel name is user
  /// visible, and this runs before any part of the service exists.
  static void initTask(L strings) {
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'tg_alert_monitor',
        channelName: strings.serviceChannelName,
        channelDescription: strings.serviceChannelDescription,
        channelImportance: NotificationChannelImportance.LOW,
        priority: NotificationPriority.LOW,
      ),
      iosNotificationOptions: const IOSNotificationOptions(),
      foregroundTaskOptions: ForegroundTaskOptions(
        eventAction: ForegroundTaskEventAction.repeat(60000),
        autoRunOnBoot: true,
        autoRunOnMyPackageReplaced: true,
        allowWakeLock: true,
        allowWifiLock: true,
      ),
    );
  }

  /// Starts the service if it is not running, then attaches to it.
  Future<void> ensureServiceRunning(L strings) async {
    serviceRunning = await FlutterForegroundTask.isRunningService;
    if (!serviceRunning) {
      final result = await FlutterForegroundTask.startService(
        serviceId: 4242,
        serviceTypes: const [ForegroundServiceTypes.specialUse],
        notificationTitle: strings.appTitle,
        notificationText: strings.connectingToTelegram,
        callback: startCallback,
      );
      switch (result) {
        case ServiceRequestSuccess():
          serviceRunning = true;
        case ServiceRequestFailure(:final error):
          serviceRunning = false;
          lastError = ServiceError(
            ErrorScope.service,
            0,
            strings.serviceCouldNotStart('$error'),
            DateTime.now(),
          );
      }
    }
    notifyListeners();
    send(Command(Cmd.uiAttached));
  }

  Future<void> stopService() async {
    await FlutterForegroundTask.stopService();
    serviceRunning = false;
    notifyListeners();
  }

  void send(Command command) =>
      FlutterForegroundTask.sendDataToTask(command.encode());

  void detach() => send(Command(Cmd.uiDetached));

  @override
  void dispose() {
    FlutterForegroundTask.removeTaskDataCallback(_onData);
    super.dispose();
  }

  // --- incoming events ----------------------------------------------------

  void _onData(Object data) {
    final Event event;
    try {
      event = Event.decode(data);
    } catch (_) {
      return;
    }

    switch (event.ev) {
      case Ev.state:
        auth = event.field<String>('auth') ?? auth;
        authDetail = event.field<String>('authDetail') ?? '';
        userName = event.field<String>('userName') ?? '';
        connection = event.field<String>('connection') ?? connection;
        monitoring = event.field<bool>('monitoring') ?? false;
        startedAt = _parseTime(event.data['startedAt']);
        chatCount = event.field<num>('chatCount')?.toInt() ?? 0;
        matchCount = event.field<num>('matchCount')?.toInt() ?? 0;
        lastMatchAt = _parseTime(event.data['lastMatchAt']);
        tdVersion = event.field<String>('tdVersion') ?? tdVersion;

      case Ev.folders:
        final items = event.data['items'];
        if (items is List) {
          folders = [
            for (final item in items)
              if (item is Map)
                FolderRef.fromJson(Map<String, dynamic>.from(item)),
          ];
        }

      case Ev.folderChats:
        final folderId = event.field<num>('folderId')?.toInt();
        final items = event.data['items'];
        if (folderId != null && items is List) {
          folderChats = {
            ...folderChats,
            folderId: [
              for (final item in items)
                if (item is Map)
                  ChatRef.fromJson(Map<String, dynamic>.from(item)),
            ],
          };
        }

      case Ev.match:
        matches = [MatchEntry.fromJson(event.data), ...matches];
        if (matches.length > 500) matches = matches.sublist(0, 500);

      case Ev.matchStatus:
        final chatId = event.field<num>('chatId')?.toInt();
        final messageId = event.field<num>('messageId')?.toInt();
        final status = MatchStatus.parse(event.field<String>('status'));
        if (chatId != null && messageId != null) {
          matches = [
            for (final entry in matches)
              if (entry.chatId == chatId && entry.messageId == messageId)
                entry.copyWith(
                  status: status,
                  error: event.field<String>('error'),
                )
              else
                entry,
          ];
        }

      case Ev.botInfo:
        botName = event.field<String>('botName');
        botChatTitle = event.field<String>('chatTitle');
        lastError = null;

      case Ev.botTargets:
        discoveringTargets = false;
        final name = event.field<String>('botName');
        if (name != null && name.isNotEmpty) botName = name;
        final items = event.data['items'];
        botTargets = [
          if (items is List)
            for (final item in items)
              if (item is Map)
                ChatRef.fromJson(Map<String, dynamic>.from(item)),
        ];

      case Ev.error:
        discoveringTargets = false;
        lastError = ServiceError(
          event.field<String>('scope') ?? ErrorScope.service,
          event.field<num>('code')?.toInt() ?? 0,
          event.field<String>('message') ?? '',
          DateTime.now(),
        );

      case Ev.log:
        logLines = [...logLines, LogLine.fromJson(event.data)];
        if (logLines.length > 300) {
          logLines = logLines.sublist(logLines.length - 300);
        }

      case Ev.logLines:
        final lines = event.data['lines'];
        if (lines is List) {
          logLines = [
            for (final line in lines)
              if (line is Map)
                LogLine.fromJson(Map<String, dynamic>.from(line)),
          ];
        }
    }
    notifyListeners();
  }

  static DateTime? _parseTime(Object? raw) =>
      raw is String ? DateTime.tryParse(raw) : null;

  void clearError() {
    lastError = null;
    notifyListeners();
  }

  /// Asks the service which channels we are allowed to publish in.
  void discoverTargets() {
    discoveringTargets = true;
    lastError = null;
    notifyListeners();
    send(Command(Cmd.botTargets));
  }

  /// Pushes edited settings to a running engine so they take effect at once.
  void pushConfig(MonitorConfig config) =>
      send(Command(Cmd.monitorConfig, {'config': config.toJson()}));

  void setMatches(List<MatchEntry> entries) {
    matches = entries;
    notifyListeners();
  }
}
