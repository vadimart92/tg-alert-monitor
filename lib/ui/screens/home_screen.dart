/// Status, folder picker, keywords, start/stop and permission cards.
library;

import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

import '../../core/ipc/protocol.dart';
import '../../core/matcher/keyword_matcher.dart';
import '../../core/model/app_config.dart';
import '../../core/storage/settings_store.dart';
import '../../l10n/app_localizations.dart';
import '../../service/monitor_engine.dart';
import '../service_bridge.dart';
import 'log_screen.dart';
import 'login_screen.dart';
import 'settings_screen.dart';
import 'setup_scan_screen.dart';
import 'setup_share_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, required this.bridge, required this.settings});

  final ServiceBridge bridge;
  final SettingsStore settings;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  /// Device-language strings, for every method on this state.
  L get l => L.of(context);

  final _keywordController = TextEditingController();
  final _exclusionController = TextEditingController();

  late MonitorConfig _config;
  bool _notificationsGranted = true;
  bool _batteryUnrestricted = true;
  bool _showChats = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _config = widget.settings.readConfig();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      // Both need localised strings for the service notification, so they run
      // from here rather than from `App`, which sits above `MaterialApp`.
      ServiceBridge.initTask(l);
      await widget.bridge.ensureServiceRunning(l);
      await _refreshPermissions();
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _keywordController.dispose();
    _exclusionController.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      widget.bridge.send(Command(Cmd.uiAttached));
      unawaitedRefresh();
    } else if (state == AppLifecycleState.paused) {
      widget.bridge.detach();
    }
  }

  void unawaitedRefresh() {
    _refreshPermissions();
  }

  Future<void> _refreshPermissions() async {
    final notification =
        await FlutterForegroundTask.checkNotificationPermission();
    final battery = await FlutterForegroundTask.isIgnoringBatteryOptimizations;
    if (!mounted) return;
    setState(() {
      _notificationsGranted = notification == NotificationPermission.granted;
      _batteryUnrestricted = battery;
    });
  }

  Future<void> _persist(MonitorConfig config) async {
    setState(() => _config = config);
    await widget.settings.reload();
    await widget.settings.writeConfig(config);
    // The service keeps its own copy of the config; without this a keyword
    // added mid-alert would not take effect until monitoring was restarted,
    // and the next folder refresh would write the stale list back.
    widget.bridge.pushConfig(config);
  }

  /// Stored as one list; an entry prefixed with `-` is an exclusion.
  List<String> get _includes => [
    for (final keyword in _config.keywords)
      if (!keyword.startsWith(exclusionPrefix)) keyword,
  ];

  List<String> get _exclusions => [
    for (final keyword in _config.keywords)
      if (keyword.startsWith(exclusionPrefix) && keyword.length > 1)
        keyword.substring(1),
  ];

  void _addKeyword({required bool isExclusion}) {
    final controller = isExclusion ? _exclusionController : _keywordController;
    final raw = controller.text.trim();
    if (raw.isEmpty) return;
    final entry = isExclusion ? '$exclusionPrefix$raw' : raw;
    final merged = KeywordMatcher.sanitize([..._config.keywords, entry]);
    controller.clear();
    _persist(_config.copyWith(keywords: merged));
  }

  void _removeKeyword(String keyword, {required bool isExclusion}) {
    final entry = isExclusion ? '$exclusionPrefix$keyword' : keyword;
    _persist(_config.copyWith(keywords: [..._config.keywords]..remove(entry)));
  }

  bool get _canStart =>
      widget.bridge.isReady && _config.isRunnable && _notificationsGranted;

  void _start() {
    widget.bridge.send(Command(Cmd.monitorStart, {'config': _config.toJson()}));
  }

  void _stop() => widget.bridge.send(Command(Cmd.monitorStop));

  void _shareSetup() => Navigator.push(
    context,
    MaterialPageRoute<void>(
      builder: (_) => SetupShareScreen(bridge: widget.bridge),
    ),
  );

  /// Reloads the config afterwards: a scan rewrites folder, keywords and
  /// delivery mode behind this screen's back.
  Future<void> _scanSetup() async {
    await Navigator.push(
      context,
      MaterialPageRoute<void>(
        builder: (_) => SetupScanScreen(bridge: widget.bridge),
      ),
    );
    await widget.settings.reload();
    if (mounted) setState(() => _config = widget.settings.readConfig());
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('TG Alert Monitor'),
        actions: [
          PopupMenuButton<void Function()>(
            tooltip: l.setupShare,
            icon: const Icon(Icons.qr_code_2),
            onSelected: (action) => action(),
            itemBuilder: (context) => [
              PopupMenuItem(
                value: _shareSetup,
                child: ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.qr_code_2),
                  title: Text(l.setupShare),
                ),
              ),
              PopupMenuItem(
                value: _scanSetup,
                child: ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.qr_code_scanner),
                  title: Text(l.setupScan),
                ),
              ),
            ],
          ),
          IconButton(
            tooltip: l.journal,
            icon: const Icon(Icons.receipt_long),
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute<void>(
                builder: (_) => LogScreen(bridge: widget.bridge),
              ),
            ),
          ),
          IconButton(
            tooltip: l.settings,
            icon: const Icon(Icons.settings),
            onPressed: () async {
              await Navigator.push(
                context,
                MaterialPageRoute<void>(
                  builder: (_) => SettingsScreen(
                    bridge: widget.bridge,
                    settings: widget.settings,
                  ),
                ),
              );
              await widget.settings.reload();
              if (mounted) {
                setState(() => _config = widget.settings.readConfig());
              }
            },
          ),
        ],
      ),
      body: ListenableBuilder(
        listenable: widget.bridge,
        builder: (context, _) {
          final bridge = widget.bridge;
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              _statusCard(bridge),
              const SizedBox(height: 12),
              if (!bridge.isReady) _loginCard(bridge),
              if (bridge.isReady) ...[
                _folderCard(bridge),
                const SizedBox(height: 12),
                _keywordsCard(),
                const SizedBox(height: 12),
                _deliveryCard(),
                const SizedBox(height: 12),
                _startStopCard(bridge),
              ],
              const SizedBox(height: 12),
              if (!_notificationsGranted || !_batteryUnrestricted)
                _permissionsCard(),
              const SizedBox(height: 12),
              _oemHintCard(),
            ],
          );
        },
      ),
    );
  }

  Widget _statusCard(ServiceBridge bridge) {
    final connection = switch (bridge.connection) {
      ConnectionPhase.ready => l.connectionReady,
      ConnectionPhase.updating => l.connectionUpdating,
      ConnectionPhase.waitingForNetwork => l.connectionNoNetwork,
      _ => l.connectionConnecting,
    };
    final startedAt = bridge.startedAt;
    final monitoring = bridge.monitoring
        ? (startedAt == null
              ? l.monitoringActive
              : l.monitoringActiveSince(_hhmm(startedAt)))
        : l.monitoringStopped;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  bridge.monitoring ? Icons.podcasts : Icons.pause_circle,
                  color: bridge.monitoring ? Colors.green : Colors.grey,
                ),
                const SizedBox(width: 8),
                Text(
                  l.monitoringStatus(monitoring),
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ],
            ),
            const Divider(),
            _row(l.rowConnection, connection),
            _row(
              l.rowAccount,
              bridge.userName.isEmpty ? l.dash : bridge.userName,
            ),
            _row(l.rowChatsInFolder, '${bridge.chatCount}'),
            _row(l.rowMatchesThisSession, '${bridge.matchCount}'),
            _row(
              l.rowLastMatch,
              bridge.lastMatchAt == null ? l.dash : _hhmm(bridge.lastMatchAt!),
            ),
            if (bridge.tdVersion.isNotEmpty) _row('TDLib', bridge.tdVersion),
          ],
        ),
      ),
    );
  }

  Widget _loginCard(ServiceBridge bridge) => Card(
    child: ListTile(
      leading: const Icon(Icons.login),
      title: Text(l.signInRequired),
      subtitle: Text(_authLabel(bridge.auth)),
      trailing: const Icon(Icons.chevron_right),
      onTap: () => Navigator.push(
        context,
        MaterialPageRoute<void>(builder: (_) => LoginScreen(bridge: bridge)),
      ),
    ),
  );

  Widget _folderCard(ServiceBridge bridge) {
    final chats = _config.folderId == null
        ? const <ChatRef>[]
        : bridge.folderChats[_config.folderId] ?? _config.chats;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(l.folder, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            DropdownButtonFormField<int>(
              initialValue: bridge.folders.any((f) => f.id == _config.folderId)
                  ? _config.folderId
                  : null,
              decoration: InputDecoration(
                border: const OutlineInputBorder(),
                labelText: l.telegramFolder,
              ),
              items: [
                for (final folder in bridge.folders)
                  DropdownMenuItem(value: folder.id, child: Text(folder.name)),
              ],
              onChanged: (value) {
                if (value == null) return;
                final folder = bridge.folders.firstWhere((f) => f.id == value);
                _persist(
                  _config.copyWith(
                    folderId: folder.id,
                    folderName: folder.name,
                    chats: const <ChatRef>[],
                  ),
                );
                bridge.send(Command(Cmd.foldersChats, {'folderId': folder.id}));
              },
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Text(l.chatCount(chats.length)),
                const Spacer(),
                TextButton(
                  onPressed: () {
                    if (_config.folderId != null) {
                      bridge.send(
                        Command(Cmd.foldersChats, {
                          'folderId': _config.folderId,
                        }),
                      );
                    }
                    setState(() => _showChats = !_showChats);
                  },
                  child: Text(_showChats ? l.hideChats : l.showChats),
                ),
              ],
            ),
            if (_showChats)
              ...chats.map(
                (chat) => ListTile(
                  dense: true,
                  leading: Icon(
                    chat.isChannel ? Icons.campaign : Icons.chat_bubble_outline,
                    size: 20,
                  ),
                  title: Text(chat.title.isEmpty ? '${chat.id}' : chat.title),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _keywordsCard() => Card(
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(l.keywords, style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 4),
          Text(l.keywordsHelp, style: const TextStyle(fontSize: 12)),
          const SizedBox(height: 8),
          _chips(_includes, isExclusion: false),
          _addRow(
            controller: _keywordController,
            hint: l.keywordHint,
            isExclusion: false,
          ),
          if (_includes.any(KeywordMatcher.isStemmed)) ...[
            const SizedBox(height: 4),
            Text(
              l.stemHelp,
              style: TextStyle(
                fontSize: 11,
                color: Theme.of(context).hintColor,
              ),
            ),
          ],
          const Divider(height: 28),
          Row(
            children: [
              Icon(
                Icons.block,
                size: 18,
                color: Theme.of(context).colorScheme.error,
              ),
              const SizedBox(width: 6),
              Text(
                l.exclusions,
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(l.exclusionsHelp, style: const TextStyle(fontSize: 12)),
          const SizedBox(height: 8),
          _chips(_exclusions, isExclusion: true),
          _addRow(
            controller: _exclusionController,
            hint: l.exclusionHint,
            isExclusion: true,
          ),
        ],
      ),
    ),
  );

  /// Chips for one of the two lists; the grey suffix is the stem actually
  /// searched for, so an automatic guess is never invisible.
  Widget _chips(List<String> keywords, {required bool isExclusion}) {
    if (keywords.isEmpty) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 4),
        child: Text(
          isExclusion ? l.noExclusionsYet : l.noKeywordsYet,
          style: TextStyle(fontSize: 12, color: Theme.of(context).hintColor),
        ),
      );
    }
    final scheme = Theme.of(context).colorScheme;
    return Wrap(
      spacing: 8,
      runSpacing: 4,
      children: [
        for (final keyword in keywords)
          Chip(
            backgroundColor: isExclusion ? scheme.errorContainer : null,
            label: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(keyword),
                if (KeywordMatcher.isStemmed(keyword))
                  Text(
                    ' · ${KeywordMatcher.stemOf(keyword)}',
                    style: TextStyle(
                      fontSize: 11,
                      color: Theme.of(context).hintColor,
                    ),
                  ),
              ],
            ),
            onDeleted: () => _removeKeyword(keyword, isExclusion: isExclusion),
          ),
      ],
    );
  }

  Widget _addRow({
    required TextEditingController controller,
    required String hint,
    required bool isExclusion,
  }) => Row(
    children: [
      Expanded(
        child: TextField(
          controller: controller,
          decoration: InputDecoration(
            labelText: isExclusion ? l.newExclusion : l.newKeyword,
            hintText: hint,
            border: const OutlineInputBorder(),
            isDense: true,
          ),
          onSubmitted: (_) => _addKeyword(isExclusion: isExclusion),
        ),
      ),
      IconButton(
        icon: const Icon(Icons.add_circle),
        onPressed: () => _addKeyword(isExclusion: isExclusion),
      ),
    ],
  );

  /// Three-position delivery switch.
  ///
  /// Forwarding into a channel is what other people see; the local siren is
  /// what wakes this phone. Neither replaces the other, so «Обидва» is a real
  /// option rather than a convenience.
  Widget _deliveryCard() {
    final delivery = _config.delivery;
    final target = _targetLabel();
    final subtitle = switch (delivery) {
      AlertDelivery.forward => l.deliveryForwardHelp(target),
      AlertDelivery.local => l.deliveryLocalHelp,
      AlertDelivery.both => l.deliveryBothHelp(target),
    };

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              l.notifications,
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: SegmentedButton<AlertDelivery>(
                showSelectedIcon: false,
                segments: [
                  ButtonSegment(
                    value: AlertDelivery.forward,
                    icon: const Icon(Icons.forward_to_inbox, size: 18),
                    label: Text(l.deliveryForward),
                  ),
                  ButtonSegment(
                    value: AlertDelivery.local,
                    icon: const Icon(Icons.notifications_active, size: 18),
                    label: Text(l.deliveryLocal),
                  ),
                  ButtonSegment(
                    value: AlertDelivery.both,
                    icon: const Icon(Icons.done_all, size: 18),
                    label: Text(l.deliveryBoth),
                  ),
                ],
                selected: {delivery},
                onSelectionChanged: (selection) =>
                    _persist(_config.copyWith(delivery: selection.first)),
              ),
            ),
            const SizedBox(height: 8),
            Text(subtitle, style: const TextStyle(fontSize: 12)),
            if (delivery.notifies) ...[
              const SizedBox(height: 4),
              Text(
                l.sirenHelp(l.matchChannelName),
                style: TextStyle(
                  fontSize: 11,
                  color: Theme.of(context).hintColor,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// Names the configured target channel for the delivery description, and
  /// says so plainly when there is none — the switch is reachable long before
  /// the channel is picked.
  String _targetLabel() {
    final configured = _config.targetChatId.trim();
    if (configured.isEmpty) return l.targetNotPicked;
    final id = int.tryParse(configured);
    for (final target in widget.bridge.botTargets ?? const <ChatRef>[]) {
      if (target.id == id && target.title.isNotEmpty) {
        return l.quoted(target.title);
      }
    }
    return l.quoted(configured);
  }

  Widget _startStopCard(ServiceBridge bridge) {
    final reasons = <String>[
      if (!bridge.isReady) l.reasonSignIn,
      if (_config.folderId == null) l.reasonNoFolder,
      if (_includes.isEmpty) l.reasonNoKeywords,
      if (_config.delivery.forwards && _config.targetChatId.isEmpty)
        l.reasonNoTarget,
      if (!_notificationsGranted) l.reasonNoNotificationPermission,
    ];

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            SizedBox(
              width: double.infinity,
              child: bridge.monitoring
                  ? FilledButton.icon(
                      style: FilledButton.styleFrom(
                        backgroundColor: Theme.of(context).colorScheme.error,
                      ),
                      onPressed: _stop,
                      icon: const Icon(Icons.stop),
                      label: Text(l.stop),
                    )
                  : FilledButton.icon(
                      onPressed: _canStart ? _start : null,
                      icon: const Icon(Icons.play_arrow),
                      label: Text(l.start),
                    ),
            ),
            if (!bridge.monitoring && reasons.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  l.cannotStart(reasons.join(', ')),
                  style: const TextStyle(fontSize: 12),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _permissionsCard() => Card(
    color: Theme.of(context).colorScheme.secondaryContainer,
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(l.permissions, style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          if (!_notificationsGranted) ...[
            Text(
              l.notificationPermissionHelp,
              style: const TextStyle(fontSize: 12),
            ),
            const SizedBox(height: 4),
            OutlinedButton(
              onPressed: () async {
                await FlutterForegroundTask.requestNotificationPermission();
                await _refreshPermissions();
              },
              child: Text(l.allowNotifications),
            ),
          ],
          if (!_batteryUnrestricted) ...[
            const SizedBox(height: 8),
            Text(l.batteryHelp, style: const TextStyle(fontSize: 12)),
            const SizedBox(height: 4),
            OutlinedButton(
              onPressed: () async {
                await FlutterForegroundTask.requestIgnoreBatteryOptimization();
                await _refreshPermissions();
              },
              child: Text(l.disableBatteryOptimisation),
            ),
          ],
        ],
      ),
    ),
  );

  Widget _oemHintCard() => Card(
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Text(l.oemHint, style: const TextStyle(fontSize: 12)),
    ),
  );

  Widget _row(String label, String value) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 2),
    child: Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(label, style: const TextStyle(color: Colors.grey)),
        Flexible(child: Text(value, textAlign: TextAlign.end)),
      ],
    ),
  );

  String _authLabel(String auth) => switch (auth) {
    AuthPhase.waitPhone => l.authWaitPhone,
    AuthPhase.waitCode => l.authWaitCode,
    AuthPhase.waitPassword => l.authWaitPassword,
    AuthPhase.closed => l.authClosed,
    AuthPhase.unsupported => l.authUnsupported,
    _ => l.authConnecting,
  };

  static String _hhmm(DateTime time) =>
      '${time.hour.toString().padLeft(2, '0')}:'
      '${time.minute.toString().padLeft(2, '0')}';
}
