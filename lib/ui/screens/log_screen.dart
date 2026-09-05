/// Two tabs: keyword hits and the service's own system log.
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import '../../core/ipc/protocol.dart';
import '../../core/model/match_entry.dart';
import '../../core/storage/match_log.dart';
import '../service_bridge.dart';

class LogScreen extends StatefulWidget {
  const LogScreen({super.key, required this.bridge});

  final ServiceBridge bridge;

  @override
  State<LogScreen> createState() => _LogScreenState();
}

class _LogScreenState extends State<LogScreen> {
  MatchLog? _matchLog;
  bool _loading = true;

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
    if (!mounted) return;
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
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Журнал'),
          bottom: const TabBar(
            tabs: [
              Tab(text: 'Збіги'),
              Tab(text: 'Системний'),
            ],
          ),
          actions: [
            IconButton(
              tooltip: 'Очистити',
              icon: const Icon(Icons.delete_outline),
              onPressed: _clear,
            ),
          ],
        ),
        body: _loading
            ? const Center(child: CircularProgressIndicator())
            : ListenableBuilder(
                listenable: widget.bridge,
                builder: (context, _) => TabBarView(
                  children: [_matchesTab(widget.bridge.matches), _systemTab()],
                ),
              ),
      ),
    );
  }

  Widget _matchesTab(List<MatchEntry> matches) {
    if (matches.isEmpty) {
      return const Center(child: Text('Збігів ще не було'));
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
          }, style: const TextStyle(fontSize: 20)),
          title: Text(
            '${_hhmm(entry.time)} · ${entry.chatTitle}',
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
          subtitle: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('🔑 ${entry.keywords.join(', ')}'),
              Text(preview),
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
          onTap: entry.link.isEmpty
              ? null
              : () async {
                  await Clipboard.setData(ClipboardData(text: entry.link));
                  if (!context.mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('Скопійовано: ${entry.link}')),
                  );
                },
        );
      },
    );
  }

  Widget _systemTab() {
    final lines = widget.bridge.logLines;
    if (lines.isEmpty) {
      return const Center(child: Text('Журнал порожній'));
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
