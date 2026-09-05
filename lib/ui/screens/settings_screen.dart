/// Telegram application credentials, bot token and target channel.
library;

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/ipc/protocol.dart';
import '../../core/model/app_config.dart';
import '../../core/storage/settings_store.dart';
import '../../l10n/app_localizations.dart';
import '../service_bridge.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({
    super.key,
    required this.bridge,
    required this.settings,
  });

  final ServiceBridge bridge;
  final SettingsStore settings;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  /// Device-language strings, for every method on this state.
  L get l => L.of(context);

  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _apiId;
  late final TextEditingController _apiHash;
  late final TextEditingController _targetChatId;
  late final TextEditingController _maxAge;
  late final TextEditingController _botToken;

  bool _saved = false;
  bool _manualTarget = false;

  /// Chosen on the home screen; here it only decides whether a target channel
  /// is required.
  late AlertDelivery _delivery;

  @override
  void initState() {
    super.initState();
    final config = widget.settings.readConfig();
    _delivery = config.delivery;
    _apiId = TextEditingController(
      text: widget.settings.apiId == 0 ? '' : '${widget.settings.apiId}',
    );
    _apiHash = TextEditingController(text: widget.settings.apiHash);
    _targetChatId = TextEditingController(text: config.targetChatId);
    _maxAge = TextEditingController(text: '${config.maxAgeMinutes}');
    _botToken = TextEditingController(text: config.botToken);
  }

  @override
  void dispose() {
    _apiId.dispose();
    _apiHash.dispose();
    _targetChatId.dispose();
    _maxAge.dispose();
    _botToken.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    final settings = widget.settings;
    await settings.reload();
    await settings.setApiId(int.parse(_apiId.text.trim()));
    await settings.setApiHash(_apiHash.text.trim());
    final config = settings.readConfig().copyWith(
      targetChatId: _targetChatId.text.trim(),
      maxAgeMinutes: int.parse(_maxAge.text.trim()),
      botToken: _botToken.text.trim(),
    );
    await settings.writeConfig(config);
    // Apply to a running engine immediately, and keep its copy authoritative.
    widget.bridge.pushConfig(config);
    if (!mounted) return;
    setState(() => _saved = true);
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(l.settingsSaved)));
  }

  /// Opens the page where api_id and api_hash are created.
  ///
  /// It is a plain browser hand-off: the sign-in there is Telegram's, done by
  /// the owner, and the two values are copied back by hand.
  Future<void> _openMyTelegram() async {
    var opened = false;
    try {
      opened = await launchUrl(
        Uri.parse('https://my.telegram.org/apps'),
        mode: LaunchMode.externalApplication,
      );
    } catch (_) {
      opened = false;
    }
    if (opened || !mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(l.couldNotOpenLink)));
  }

  void _checkBot() {
    widget.bridge.clearError();
    widget.bridge.send(
      Command(Cmd.botCheck, {'targetChatId': _targetChatId.text.trim()}),
    );
  }

  void _testBot() {
    widget.bridge.clearError();
    widget.bridge.send(
      Command(Cmd.botTest, {'targetChatId': _targetChatId.text.trim()}),
    );
  }

  /// Target channel picker.
  ///
  /// Telegram gives bots no way to list their own chats, so the candidates are
  /// discovered through the owner's logged-in session (channels where this bot
  /// can post). Manual entry stays available: discovery needs the owner to be
  /// an administrator of the channel, which is not guaranteed.
  Widget _targetChatField() {
    final bridge = widget.bridge;
    final targets = bridge.botTargets;
    final current = _targetChatId.text.trim();
    final knownIds = [for (final t in targets ?? const <ChatRef>[]) '${t.id}'];
    final useDropdown = !_manualTarget && targets != null && targets.isNotEmpty;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (useDropdown)
          DropdownButtonFormField<String>(
            initialValue: knownIds.contains(current) ? current : null,
            isExpanded: true,
            decoration: InputDecoration(
              labelText: l.targetChannel,
              helperText: l.targetChannelHelp,
              border: const OutlineInputBorder(),
            ),
            items: [
              for (final target in targets)
                DropdownMenuItem(
                  value: '${target.id}',
                  child: Text(
                    target.title.isEmpty ? '${target.id}' : target.title,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
            ],
            onChanged: (value) {
              if (value == null) return;
              setState(() => _targetChatId.text = value);
            },
            validator: (value) => (value == null || value.isEmpty)
                ? _requiredTargetError(l.pickChannel)
                : null,
          )
        else
          TextFormField(
            controller: _targetChatId,
            decoration: InputDecoration(
              labelText: l.targetChat,
              helperText: _delivery.forwards
                  ? l.targetChatHelp
                  : l.targetChatNotNeeded(l.deliveryLocal),
              border: const OutlineInputBorder(),
            ),
            validator: (value) {
              final trimmed = (value ?? '').trim();
              if (trimmed.isEmpty) {
                return _requiredTargetError(l.usernameOrInteger);
              }
              if (trimmed.startsWith('@') && trimmed.length > 1) return null;
              if (int.tryParse(trimmed) != null) return null;
              return l.usernameOrInteger;
            },
          ),
        Row(
          children: [
            TextButton.icon(
              onPressed: bridge.discoveringTargets
                  ? null
                  : () {
                      setState(() => _manualTarget = false);
                      bridge.discoverTargets();
                    },
              icon: bridge.discoveringTargets
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.refresh, size: 18),
              label: Text(l.findMyChannels),
            ),
            const Spacer(),
            if (targets != null && targets.isNotEmpty)
              TextButton(
                onPressed: () => setState(() => _manualTarget = !_manualTarget),
                child: Text(_manualTarget ? l.fromList : l.manually),
              ),
          ],
        ),
        if (targets != null && targets.isEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(
              l.noChannelsFound,
              style: const TextStyle(fontSize: 12),
            ),
          ),
      ],
    );
  }

  /// A target channel is only needed when matches are forwarded, so in
  /// «Локально» mode an empty field must not block saving api credentials.
  String? _requiredTargetError(String message) =>
      _delivery.forwards ? message : null;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(l.settings)),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Text(l.apiCredentialsHelp, style: const TextStyle(fontSize: 12)),
            const SizedBox(height: 4),
            Text(
              l.apiCredentialsSteps,
              style: TextStyle(
                fontSize: 12,
                color: Theme.of(context).hintColor,
              ),
            ),
            const SizedBox(height: 4),
            Align(
              alignment: Alignment.centerLeft,
              child: OutlinedButton.icon(
                onPressed: _openMyTelegram,
                icon: const Icon(Icons.open_in_new, size: 18),
                label: Text(l.openMyTelegram),
              ),
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _apiId,
              decoration: const InputDecoration(
                labelText: 'api_id',
                border: OutlineInputBorder(),
              ),
              keyboardType: TextInputType.number,
              validator: (value) {
                final parsed = int.tryParse((value ?? '').trim());
                if (parsed == null || parsed <= 0) {
                  return l.positiveInteger;
                }
                return null;
              },
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _apiHash,
              decoration: const InputDecoration(
                labelText: 'api_hash',
                border: OutlineInputBorder(),
              ),
              validator: (value) =>
                  RegExp(r'^[0-9a-fA-F]{32}$').hasMatch((value ?? '').trim())
                  ? null
                  : l.thirtyTwoHexCharacters,
            ),
            const SizedBox(height: 12),
            ListenableBuilder(
              listenable: widget.bridge,
              builder: (context, _) => _targetChatField(),
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _maxAge,
              decoration: InputDecoration(
                labelText: l.maxAgeLabel,
                helperText: l.maxAgeHelp,
                border: const OutlineInputBorder(),
              ),
              keyboardType: TextInputType.number,
              validator: (value) {
                final parsed = int.tryParse((value ?? '').trim());
                if (parsed == null ||
                    parsed < MonitorConfig.minMaxAgeMinutes ||
                    parsed > MonitorConfig.maxMaxAgeMinutes) {
                  return l.rangeFromTo(
                    MonitorConfig.minMaxAgeMinutes,
                    MonitorConfig.maxMaxAgeMinutes,
                  );
                }
                return null;
              },
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _botToken,
              decoration: InputDecoration(
                labelText: l.botToken,
                helperText: l.botTokenHelp,
                helperMaxLines: 3,
                border: const OutlineInputBorder(),
              ),
              validator: (value) {
                final trimmed = (value ?? '').trim();
                if (trimmed.isEmpty) return null;
                return RegExp(r'^\d+:[A-Za-z0-9_-]{20,}$').hasMatch(trimmed)
                    ? null
                    : l.botTokenInvalid;
              },
            ),
            const SizedBox(height: 4),
            Text(
              l.botWhyHelp,
              style: TextStyle(
                fontSize: 12,
                color: Theme.of(context).hintColor,
              ),
            ),
            const SizedBox(height: 20),
            FilledButton.icon(
              onPressed: _save,
              icon: const Icon(Icons.save),
              label: Text(l.save),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: _checkBot,
                    child: Text(l.checkChannel),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton(
                    onPressed: _testBot,
                    child: Text(l.testMessage),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            ListenableBuilder(
              listenable: widget.bridge,
              builder: (context, _) {
                final bridge = widget.bridge;
                final error = bridge.lastError;
                if (error != null && error.scope == ErrorScope.bot) {
                  return Card(
                    color: Theme.of(context).colorScheme.errorContainer,
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Text(error.message),
                    ),
                  );
                }
                if (bridge.botName != null || bridge.botChatTitle != null) {
                  return Card(
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if ((bridge.botChatTitle ?? '').isNotEmpty)
                            Text(l.channelNamed(bridge.botChatTitle!)),
                        ],
                      ),
                    ),
                  );
                }
                return const SizedBox.shrink();
              },
            ),
            if (_saved)
              Padding(
                padding: const EdgeInsets.only(top: 16),
                child: Text(
                  l.apiChangeNeedsRestart,
                  style: const TextStyle(fontSize: 12),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
