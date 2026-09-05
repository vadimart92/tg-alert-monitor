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
  late final TextEditingController _botToken;
  late final TextEditingController _targetChatId;
  late final TextEditingController _maxAge;

  bool _obscureToken = true;
  bool _saved = false;

  @override
  void initState() {
    super.initState();
    final config = widget.settings.readConfig();
    _apiId = TextEditingController(
      text: widget.settings.apiId == 0 ? '' : '${widget.settings.apiId}',
    );
    _apiHash = TextEditingController(text: widget.settings.apiHash);
    _botToken = TextEditingController(text: config.botToken);
    _targetChatId = TextEditingController(text: config.targetChatId);
    _maxAge = TextEditingController(text: '${config.maxAgeMinutes}');
  }

  @override
  void dispose() {
    _apiId.dispose();
    _apiHash.dispose();
    _botToken.dispose();
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
      botToken: _botToken.text.trim(),
      targetChatId: _targetChatId.text.trim(),
      maxAgeMinutes: int.parse(_maxAge.text.trim()),
    );
    await settings.writeConfig(config);
    if (!mounted) return;
    setState(() => _saved = true);
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text('Налаштування збережено')));
  }

  void _checkBot() {
    widget.bridge.clearError();
    widget.bridge.send(
      Command(Cmd.botCheck, {
        'botToken': _botToken.text.trim(),
        'targetChatId': _targetChatId.text.trim(),
      }),
    );
  }

  void _testBot() {
    widget.bridge.clearError();
    widget.bridge.send(
      Command(Cmd.botTest, {
        'botToken': _botToken.text.trim(),
        'targetChatId': _targetChatId.text.trim(),
      }),
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
            TextFormField(
              controller: _botToken,
              obscureText: _obscureToken,
              decoration: InputDecoration(
                labelText: 'Токен бота',
                border: const OutlineInputBorder(),
                suffixIcon: IconButton(
                  icon: Icon(
                    _obscureToken ? Icons.visibility : Icons.visibility_off,
                  ),
                  onPressed: () =>
                      setState(() => _obscureToken = !_obscureToken),
                ),
              ),
              validator: (value) =>
                  RegExp(r'^\d+:[A-Za-z0-9_-]{30,}$')
                      .hasMatch((value ?? '').trim())
                  ? null
                  : 'Формат 123456:AA…',
            ),
            const SizedBox(height: 12),
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
                    child: const Text('Перевірити бота'),
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
                          if ((bridge.botName ?? '').isNotEmpty)
                            Text('Бот: ${bridge.botName}'),
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
