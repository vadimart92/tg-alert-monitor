/// Answers "I posted the keyword and nothing happened".
///
/// Every check here runs the real code path rather than a parallel test one,
/// so a green result means the thing itself works.
library;

import 'package:flutter/material.dart';

import '../../core/ipc/protocol.dart';
import '../../core/matcher/keyword_matcher.dart';
import '../../core/model/app_config.dart';
import '../../core/storage/settings_store.dart';
import '../../l10n/app_localizations.dart';
import '../service_bridge.dart';

class DiagnosticsScreen extends StatefulWidget {
  const DiagnosticsScreen({
    super.key,
    required this.bridge,
    required this.settings,
  });

  final ServiceBridge bridge;
  final SettingsStore settings;

  @override
  State<DiagnosticsScreen> createState() => _DiagnosticsScreenState();
}

class _DiagnosticsScreenState extends State<DiagnosticsScreen> {
  final _sample = TextEditingController();
  late MonitorConfig _config;

  L get l => L.of(context);

  @override
  void initState() {
    super.initState();
    _config = widget.settings.readConfig();
    widget.bridge.requestDiagState();
  }

  @override
  void dispose() {
    _sample.dispose();
    super.dispose();
  }

  Future<void> _refreshChats() async {
    final folderId = _config.folderId;
    if (folderId == null) return;
    widget.bridge.send(Command(Cmd.foldersChats, {'folderId': folderId}));
    // The service adopts the refreshed list, then this asks what it now holds.
    await Future<void>.delayed(const Duration(seconds: 2));
    widget.bridge.requestDiagState();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(l.diagnostics)),
      body: ListenableBuilder(
        listenable: widget.bridge,
        builder: (context, _) => ListView(
          padding: const EdgeInsets.all(16),
          children: [
            _watchedCard(widget.bridge),
            const SizedBox(height: 12),
            _matchCard(),
            const SizedBox(height: 12),
            _actionsCard(widget.bridge),
          ],
        ),
      ),
    );
  }

  Widget _watchedCard(ServiceBridge bridge) {
    final diag = bridge.diagState;
    final refreshed = diag?.lastFolderRefresh;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              l.diagWhatIsWatched,
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Icon(
                  (diag?.monitoring ?? false)
                      ? Icons.check_circle
                      : Icons.pause_circle,
                  size: 18,
                  color: (diag?.monitoring ?? false)
                      ? Colors.green
                      : Theme.of(context).colorScheme.error,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    (diag?.monitoring ?? false)
                        ? l.diagMonitoringOn
                        : l.diagMonitoringOff,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(l.diagWatchedChats(diag?.watching.length ?? 0)),
            Text(
              refreshed == null
                  ? l.diagNeverRefreshed
                  : l.diagRefreshedAt(_hhmm(refreshed)),
              style: TextStyle(
                fontSize: 12,
                color: Theme.of(context).hintColor,
              ),
            ),
            if (diag != null && diag.watching.isNotEmpty) ...[
              const SizedBox(height: 8),
              Wrap(
                spacing: 6,
                runSpacing: 4,
                children: [
                  for (final chat in diag.watching) Chip(label: Text(chat)),
                ],
              ),
            ],
            const SizedBox(height: 8),
            Text(l.diagFolderHint, style: const TextStyle(fontSize: 12)),
            const SizedBox(height: 4),
            Align(
              alignment: Alignment.centerLeft,
              child: OutlinedButton.icon(
                onPressed: _config.folderId == null ? null : _refreshChats,
                icon: const Icon(Icons.refresh, size: 18),
                label: Text(l.diagRefreshChats),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Runs the real [KeywordMatcher] over pasted text, so "why did this post
  /// not fire" is answerable without posting anything.
  Widget _matchCard() {
    final text = _sample.text.trim();
    final matcher = KeywordMatcher(_config.keywords);
    final matched = text.isEmpty ? const <String>[] : matcher.match(text);
    final hasIncludes = text.isNotEmpty && _rawIncludeHit(text);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(l.diagTryText, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            TextField(
              controller: _sample,
              maxLines: 3,
              decoration: InputDecoration(
                hintText: l.diagTryTextHint,
                border: const OutlineInputBorder(),
                isDense: true,
              ),
              onChanged: (_) => setState(() {}),
            ),
            if (text.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(
                matched.isNotEmpty
                    ? l.diagMatched(matched.join(', '))
                    // A keyword present but no match means an exclusion ate it.
                    : (hasIncludes ? l.diagExcluded : l.diagNotMatched),
                style: TextStyle(
                  color: matched.isNotEmpty
                      ? Colors.green
                      : Theme.of(context).colorScheme.error,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// True when some include keyword is in [text], ignoring exclusions.
  bool _rawIncludeHit(String text) {
    final includes = [
      for (final keyword in _config.keywords)
        if (!keyword.startsWith(exclusionPrefix)) keyword,
    ];
    return KeywordMatcher(includes).match(text).isNotEmpty;
  }

  Widget _actionsCard(ServiceBridge bridge) {
    final result = bridge.diagResult;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: () => bridge.runDiagnostic(Cmd.diagAlert),
                icon: const Icon(Icons.notifications_active),
                label: Text(l.diagTestAlert),
              ),
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: () => bridge.runDiagnostic(Cmd.diagForward),
                icon: const Icon(Icons.forward_to_inbox),
                label: Text(l.diagTestForward),
              ),
            ),
            const SizedBox(height: 4),
            Text(
              l.diagTestForwardHint,
              style: TextStyle(
                fontSize: 12,
                color: Theme.of(context).hintColor,
              ),
            ),
            if (result != null) ...[
              const SizedBox(height: 12),
              Card(
                margin: EdgeInsets.zero,
                color: result.ok
                    ? Theme.of(context).colorScheme.secondaryContainer
                    : Theme.of(context).colorScheme.errorContainer,
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Text(result.message),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  static String _hhmm(DateTime time) =>
      '${time.hour.toString().padLeft(2, '0')}:'
      '${time.minute.toString().padLeft(2, '0')}';
}
