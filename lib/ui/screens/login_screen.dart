/// Telegram login: phone, code, optional two-factor password.
library;

import 'package:flutter/material.dart';

import '../../core/ipc/protocol.dart';
import '../../service/monitor_engine.dart';
import '../service_bridge.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key, required this.bridge});

  final ServiceBridge bridge;

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _phone = TextEditingController();
  final _code = TextEditingController();
  final _password = TextEditingController();

  @override
  void dispose() {
    _phone.dispose();
    _code.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _confirmLogout() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Вийти з акаунта?'),
        content: const Text(
          'Моніторинг зупиниться, сесія Telegram буде видалена. '
          'Для повернення знадобиться новий код входу.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Скасувати'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Вийти'),
          ),
        ],
      ),
    );
    if (confirmed == true) widget.bridge.send(Command(Cmd.authLogout));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Вхід у Telegram'),
        actions: [
          IconButton(
            tooltip: 'Вийти',
            icon: const Icon(Icons.logout),
            onPressed: _confirmLogout,
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
              if (bridge.lastError case final error?
                  when error.scope == ErrorScope.auth)
                Card(
                  color: Theme.of(context).colorScheme.errorContainer,
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Text(_humanError(error.message)),
                  ),
                ),
              const SizedBox(height: 8),
              ..._stepFor(bridge),
            ],
          );
        },
      ),
    );
  }

  List<Widget> _stepFor(ServiceBridge bridge) {
    switch (bridge.auth) {
      case AuthPhase.waitPhone:
        return [
          const Text('Введіть номер телефону в міжнародному форматі.'),
          const SizedBox(height: 12),
          TextField(
            controller: _phone,
            keyboardType: TextInputType.phone,
            decoration: const InputDecoration(
              labelText: 'Номер телефону',
              hintText: '+380…',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          FilledButton(
            onPressed: () {
              bridge.clearError();
              bridge.send(
                Command(Cmd.authPhone, {'phone': _phone.text.trim()}),
              );
            },
            child: const Text('Далі'),
          ),
        ];

      case AuthPhase.waitCode:
        return [
          Text(
            bridge.authDetail.isEmpty
                ? 'Введіть код підтвердження.'
                : bridge.authDetail,
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _code,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(
              labelText: 'Код',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          FilledButton(
            onPressed: () {
              bridge.clearError();
              bridge.send(Command(Cmd.authCode, {'code': _code.text.trim()}));
            },
            child: const Text('Підтвердити'),
          ),
          TextButton(
            onPressed: () {
              bridge.clearError();
              bridge.send(Command(Cmd.authResend));
            },
            child: const Text('Надіслати код повторно'),
          ),
        ];

      case AuthPhase.waitPassword:
        return [
          Text(
            bridge.authDetail.isEmpty
                ? 'Введіть пароль двофакторної автентифікації.'
                : 'Підказка: ${bridge.authDetail}',
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _password,
            obscureText: true,
            decoration: const InputDecoration(
              labelText: 'Пароль 2FA',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          FilledButton(
            onPressed: () {
              bridge.clearError();
              bridge.send(
                Command(Cmd.authPassword, {'password': _password.text}),
              );
            },
            child: const Text('Увійти'),
          ),
        ];

      case AuthPhase.unsupported:
        return [
          Card(
            color: Theme.of(context).colorScheme.errorContainer,
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Text(
                'Цей сценарій входу не підтримується '
                '(${bridge.authDetail}). Увійдіть в офіційний Telegram '
                'і спробуйте ще раз.',
              ),
            ),
          ),
        ];

      case AuthPhase.ready:
        return [
          ListTile(
            leading: const Icon(Icons.check_circle, color: Colors.green),
            title: Text(bridge.userName.isEmpty ? 'Готово' : bridge.userName),
            subtitle: const Text('Вхід виконано'),
          ),
        ];

      default:
        return const [
          Center(
            child: Padding(
              padding: EdgeInsets.all(32),
              child: Column(
                children: [
                  CircularProgressIndicator(),
                  SizedBox(height: 16),
                  Text('Підключення до Telegram…'),
                ],
              ),
            ),
          ),
        ];
    }
  }

  /// Turns the raw TDLib error codes into something a person can act on.
  static String _humanError(String raw) {
    if (raw.contains('PHONE_CODE_INVALID')) return 'Невірний код.';
    if (raw.contains('PHONE_CODE_EXPIRED')) {
      return 'Код застарів, надішліть новий.';
    }
    if (raw.contains('PASSWORD_HASH_INVALID')) return 'Невірний пароль 2FA.';
    if (raw.contains('PHONE_NUMBER_INVALID')) return 'Невірний номер телефону.';
    final flood = RegExp(r'FLOOD_WAIT_(\d+)').firstMatch(raw);
    if (flood != null) {
      final seconds = int.tryParse(flood.group(1) ?? '') ?? 0;
      final minutes = (seconds / 60).ceil();
      return 'Забагато спроб. Зачекайте близько $minutes хв.';
    }
    return raw;
  }
}
