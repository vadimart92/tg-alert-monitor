import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

import 'core/storage/settings_store.dart';
import 'ui/screens/home_screen.dart';
import 'ui/service_bridge.dart';

class App extends StatefulWidget {
  const App({super.key});

  @override
  State<App> createState() => _AppState();
}

class _AppState extends State<App> {
  final ServiceBridge _bridge = ServiceBridge();
  SettingsStore? _settings;

  @override
  void initState() {
    super.initState();
    ServiceBridge.initTask();
    SettingsStore.open().then((store) {
      if (mounted) setState(() => _settings = store);
    });
  }

  @override
  void dispose() {
    _bridge.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final settings = _settings;
    return MaterialApp(
      title: 'TG Alert Monitor',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorSchemeSeed: const Color(0xFF2AABEE),
        useMaterial3: true,
      ),
      darkTheme: ThemeData(
        colorSchemeSeed: const Color(0xFF2AABEE),
        brightness: Brightness.dark,
        useMaterial3: true,
      ),
      // The foreground task needs this so a notification tap can bring the
      // existing Activity back instead of starting a second one.
      home: WithForegroundTask(
        child: settings == null
            ? const Scaffold(body: Center(child: CircularProgressIndicator()))
            : HomeScreen(bridge: _bridge, settings: settings),
      ),
    );
  }
}
