/// Telegram login: phone, code, optional two-factor password.
library;

import 'package:flutter/material.dart';

import '../../core/ipc/protocol.dart';
import '../../service/monitor_engine.dart';
import '../../l10n/app_localizations.dart';
import '../service_bridge.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key, required this.bridge});

  final ServiceBridge bridge;

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  /// Device-language strings, for every method on this state.
  L get l => L.of(context);

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
        title: Text(l.logOutTitle),
        content: Text(l.logOutBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(l.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(l.logOut),
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
        title: Text(l.telegramSignIn),
        actions: [
          IconButton(
            tooltip: l.logOut,
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
          Text(l.enterPhoneInternational),
          const SizedBox(height: 12),
          TextField(
            controller: _phone,
            keyboardType: TextInputType.phone,
            decoration: InputDecoration(
              labelText: l.phoneNumber,
              hintText: '+380…',
              border: const OutlineInputBorder(),
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
            child: Text(l.next),
          ),
        ];

      case AuthPhase.waitCode:
        return [
          Text(bridge.authDetail.isEmpty ? l.enterCode : bridge.authDetail),
          const SizedBox(height: 12),
          TextField(
            controller: _code,
            keyboardType: TextInputType.number,
            decoration: InputDecoration(
              labelText: l.code,
              border: const OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          FilledButton(
            onPressed: () {
              bridge.clearError();
              bridge.send(Command(Cmd.authCode, {'code': _code.text.trim()}));
            },
            child: Text(l.confirm),
          ),
          TextButton(
            onPressed: () {
              bridge.clearError();
              bridge.send(Command(Cmd.authResend));
            },
            child: Text(l.resendCode),
          ),
        ];

      case AuthPhase.waitPassword:
        return [
          Text(
            bridge.authDetail.isEmpty
                ? l.enterTwoFactorPassword
                : l.passwordHint(bridge.authDetail),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _password,
            obscureText: true,
            decoration: InputDecoration(
              labelText: l.twoFactorPassword,
              border: const OutlineInputBorder(),
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
            child: Text(l.signIn),
          ),
        ];

      case AuthPhase.unsupported:
        return [
          Card(
            color: Theme.of(context).colorScheme.errorContainer,
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Text(l.unsupportedSignIn(bridge.authDetail)),
            ),
          ),
        ];

      case AuthPhase.ready:
        return [
          ListTile(
            leading: const Icon(Icons.check_circle, color: Colors.green),
            title: Text(bridge.userName.isEmpty ? l.done : bridge.userName),
            subtitle: Text(l.signedIn),
          ),
        ];

      default:
        return [
          Center(
            child: Padding(
              padding: const EdgeInsets.all(32),
              child: Column(
                children: [
                  const CircularProgressIndicator(),
                  const SizedBox(height: 16),
                  Text(l.connectingToTelegram),
                ],
              ),
            ),
          ),
        ];
    }
  }

  /// Turns the raw TDLib error codes into something a person can act on.
  String _humanError(String raw) {
    if (raw.contains('PHONE_CODE_INVALID')) return l.invalidCode;
    if (raw.contains('PHONE_CODE_EXPIRED')) return l.codeExpired;
    if (raw.contains('PASSWORD_HASH_INVALID')) {
      return l.invalidTwoFactorPassword;
    }
    if (raw.contains('PHONE_NUMBER_INVALID')) return l.invalidPhoneNumber;
    final flood = RegExp(r'FLOOD_WAIT_(\d+)').firstMatch(raw);
    if (flood != null) {
      final seconds = int.tryParse(flood.group(1) ?? '') ?? 0;
      return l.tooManyAttempts((seconds / 60).ceil());
    }
    return raw;
  }
}
