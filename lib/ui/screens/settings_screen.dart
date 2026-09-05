/// Telegram application credentials, bot token and target channel.
library;

import 'package:flutter/material.dart';

import '../../core/ipc/protocol.dart';
import '../../core/model/app_config.dart';
import '../../core/storage/settings_store.dart';
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
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _apiId;
  late final TextEditingController _apiHash;
  late final TextEditingController _targetChatId;
  late final TextEditingController _maxAge;

  bool _saved = false;
  bool _manualTarget = false;

  @override
  void initState() {
    super.initState();
    final config = widget.settings.readConfig();
    _apiId = TextEditingController(
      text: widget.settings.apiId == 0 ? '' : '${widget.settings.apiId}',
    );
    _apiHash = TextEditingController(text: widget.settings.apiHash);
    _targetChatId = TextEditingController(text: config.targetChatId);
    _maxAge = TextEditingController(text: '${config.maxAgeMinutes}');
  }

  @override
  void dispose() {
    _apiId.dispose();
    _apiHash.dispose();
    _targetChatId.dispose();
    _maxAge.dispose();
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
    );
    await settings.writeConfig(config);
    // Apply to a running engine immediately, and keep its copy authoritative.
    widget.bridge.pushConfig(config);
    if (!mounted) return;
    setState(() => _saved = true);
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text('Налаштування збережено')));
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
            decoration: const InputDecoration(
              labelText: 'Цільовий канал',
              helperText: 'Канали, у яких ви можете публікувати',
              border: OutlineInputBorder(),
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
            validator: (value) =>
                (value == null || value.isEmpty) ? 'Оберіть канал' : null,
          )
        else
          TextFormField(
            controller: _targetChatId,
            decoration: const InputDecoration(
              labelText: 'Цільовий чат',
              helperText: '@username або числовий id (-100…)',
              border: OutlineInputBorder(),
            ),
            validator: (value) {
              final trimmed = (value ?? '').trim();
              if (trimmed.startsWith('@') && trimmed.length > 1) return null;
              if (int.tryParse(trimmed) != null) return null;
              return '@username або ціле число';
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
              label: const Text('Знайти мої канали'),
            ),
            const Spacer(),
            if (targets != null && targets.isNotEmpty)
              TextButton(
                onPressed: () => setState(() => _manualTarget = !_manualTarget),
                child: Text(_manualTarget ? 'Зі списку' : 'Вручну'),
              ),
          ],
        ),
        if (targets != null && targets.isEmpty)
          const Padding(
            padding: EdgeInsets.only(bottom: 8),
            child: Text(
              'Каналів не знайдено. Створіть канал і переконайтеся, що ви '
              'його адміністратор із правом «Публікувати повідомлення». '
              'Або введіть id вручну.',
              style: TextStyle(fontSize: 12),
            ),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Налаштування')),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            const Text(
              'api_id та api_hash створюються на my.telegram.org → '
              'API development tools.',
              style: TextStyle(fontSize: 12),
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
                  return 'Ціле число більше нуля';
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
                  : '32 шістнадцяткові символи',
            ),
            const SizedBox(height: 12),
            ListenableBuilder(
              listenable: widget.bridge,
              builder: (context, _) => _targetChatField(),
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _maxAge,
              decoration: const InputDecoration(
                labelText: 'Максимальний вік повідомлення, хв',
                helperText: 'Захист від лавини старих постів після реконекту',
                border: OutlineInputBorder(),
              ),
              keyboardType: TextInputType.number,
              validator: (value) {
                final parsed = int.tryParse((value ?? '').trim());
                if (parsed == null ||
                    parsed < MonitorConfig.minMaxAgeMinutes ||
                    parsed > MonitorConfig.maxMaxAgeMinutes) {
                  return 'Від ${MonitorConfig.minMaxAgeMinutes} '
                      'до ${MonitorConfig.maxMaxAgeMinutes}';
                }
                return null;
              },
            ),
            const SizedBox(height: 20),
            FilledButton.icon(
              onPressed: _save,
              icon: const Icon(Icons.save),
              label: const Text('Зберегти'),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: _checkBot,
                    child: const Text('Перевірити канал'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton(
                    onPressed: _testBot,
                    child: const Text('Тестове повідомлення'),
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
                            Text('Канал: ${bridge.botChatTitle}'),
                        ],
                      ),
                    ),
                  );
                }
                return const SizedBox.shrink();
              },
            ),
            if (_saved)
              const Padding(
                padding: EdgeInsets.only(top: 16),
                child: Text(
                  'Зміна api_id / api_hash застосується після виходу з акаунта '
                  'та перезапуску застосунку: параметри TDLib задаються один '
                  'раз на базу даних.',
                  style: TextStyle(fontSize: 12),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
