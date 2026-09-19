/// Two tabs: keyword hits and the service's own system log.
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/bot/message_formatter.dart';
import '../../core/ipc/protocol.dart';
import '../../core/model/app_config.dart';
import '../../core/model/match_entry.dart';
import '../../core/storage/match_log.dart';
import '../../core/storage/settings_store.dart';
import '../../l10n/app_localizations.dart';
import '../duration_label.dart';
import '../service_bridge.dart';
import 'diagnostics_screen.dart';

class LogScreen extends StatefulWidget {
  const LogScreen({super.key, required this.bridge, required this.settings});

  final ServiceBridge bridge;
  final SettingsStore settings;

  @override
  State<LogScreen> createState() => _LogScreenState();
}

class _LogScreenState extends State<LogScreen> {
  MatchLog? _matchLog;
  bool _loading = true;

  /// The configured pause, for explaining a muted entry. Read once: the
  /// journal is a snapshot, and a storage read per row would be absurd.
  Duration _cooldown = const Duration(
    seconds: MonitorConfig.defaultAlertCooldownSeconds,
  );

  @override
  void initState() {
    super.initState();
    widget.bridge.send(Command(Cmd.logGet));
    _load();
  }

  Future<void> _load() async {
    final supportDir = await getApplicationSupportDirectory();
    final log = MatchLog(File('${supportDir.path}/matches.jsonl'));
    final entries = await log.read();
    // The service isolate writes settings too, so this isolate's cache can be
    // behind whatever the owner last saved.
    await widget.settings.reload();
    if (!mounted) return;
    _cooldown = widget.settings.readConfig().alertCooldown;
    _matchLog = log;
    widget.bridge.setMatches(entries);
    setState(() => _loading = false);
  }

  Future<void> _clear() async {
    await _matchLog?.clear();
    widget.bridge.setMatches(const <MatchEntry>[]);
  }

  @override
  Widget build(BuildContext context) {
    final l = L.of(context);
    return DefaultTabController(
      length: 3,
      child: Scaffold(
        appBar: AppBar(
          title: Text(l.journal),
          bottom: TabBar(
            tabs: [
              Tab(text: l.tabMatches),
              Tab(text: l.tabSystem),
              Tab(text: l.diagnostics),
            ],
          ),
          actions: [
            Builder(
              // Nothing to clear on the diagnostics tab.
              builder: (context) => DefaultTabController.of(context).index == 2
                  ? const SizedBox.shrink()
                  : IconButton(
                      tooltip: l.clear,
                      icon: const Icon(Icons.delete_outline),
                      onPressed: _clear,
                    ),
            ),
          ],
        ),
        body: _loading
            ? const Center(child: CircularProgressIndicator())
            : ListenableBuilder(
                listenable: widget.bridge,
                builder: (context, _) => TabBarView(
                  children: [
                    _matchesTab(widget.bridge.matches),
                    _systemTab(),
                    DiagnosticsView(
                      bridge: widget.bridge,
                      settings: widget.settings,
                    ),
                  ],
                ),
              ),
      ),
    );
  }

  /// Hands the message link to Telegram.
  ///
  /// `t.me` links are claimed by the Telegram app, so this lands on the post
  /// itself; without the app installed the browser opens the web version.
  Future<void> _open(MatchEntry entry) async {
    final uri = Uri.tryParse(entry.link);
    var opened = false;
    if (uri != null) {
      try {
        opened = await launchUrl(uri, mode: LaunchMode.externalApplication);
      } catch (_) {
        opened = false;
      }
    }
    if (opened || !mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(L.of(context).couldNotOpenLink)));
  }

  Future<void> _copy(MatchEntry entry) async {
    await Clipboard.setData(ClipboardData(text: entry.link));
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(L.of(context).copied(entry.link))));
  }

  Widget _matchesTab(List<MatchEntry> matches) {
    if (matches.isEmpty) {
      return Center(child: Text(L.of(context).noMatchesYet));
    }
    return ListView.separated(
      itemCount: matches.length,
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (context, index) {
        final entry = matches[index];
        final preview = entry.text.length > 200
            ? '${entry.text.substring(0, 200)}…'
            : entry.text;
        return ListTile(
          leading: Text(switch (entry.status) {
            MatchStatus.sent => '✅',
            MatchStatus.queued => '⏳',
            MatchStatus.failed => '❌',
            MatchStatus.muted => '🔇',
          }, style: const TextStyle(fontSize: 20)),
          title: Text(
            '${_hhmm(entry.time)} · ${entry.chatTitle}',
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
          subtitle: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // The tags no longer travel with the forward, so this is the
              // only place the matched keywords are shown.
              Text(
                MessageFormatter.renderKeywords(entry.keywords),
                style: TextStyle(color: Theme.of(context).colorScheme.primary),
              ),
              Text(preview),
              // Why this one was silent. Without it the owner is left deciding
              // between a broken app and a quiet night.
              if (entry.status == MatchStatus.muted)
                Text(
                  L.of(context).matchMuted(
                    durationLabel(L.of(context), _cooldown),
                  ),
                  style: TextStyle(
                    color: Theme.of(context).hintColor,
                    fontSize: 12,
                  ),
                ),
              if (entry.status == MatchStatus.failed && entry.error != null)
                Text(
                  entry.error!,
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.error,
                    fontSize: 12,
                  ),
                ),
            ],
          ),
          isThreeLine: true,
          onTap: entry.link.isEmpty ? null : () => _open(entry),
          onLongPress: entry.link.isEmpty ? null : () => _copy(entry),
        );
      },
    );
  }

  Widget _systemTab() {
    final lines = widget.bridge.logLines;
    if (lines.isEmpty) {
      return Center(child: Text(L.of(context).journalEmpty));
    }
    return ListView.builder(
      reverse: true,
      itemCount: lines.length,
      itemBuilder: (context, index) {
        final line = lines[lines.length - 1 - index];
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 3),
          child: Text(
            '${_hhmmss(line.time)} [${line.level}] ${line.message}',
            style: TextStyle(
              fontFamily: 'monospace',
              fontSize: 12,
              color: line.level == 'error'
                  ? Theme.of(context).colorScheme.error
                  : null,
            ),
          ),
        );
      },
    );
  }

  static String _hhmm(DateTime time) =>
      '${_two(time.hour)}:${_two(time.minute)}';

  static String _hhmmss(DateTime time) =>
      '${_two(time.hour)}:${_two(time.minute)}:${_two(time.second)}';

  static String _two(int value) => value.toString().padLeft(2, '0');
}
