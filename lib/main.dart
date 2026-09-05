import 'package:flutter/widgets.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

import 'app.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // Must run before the service can send anything back to this isolate.
  FlutterForegroundTask.initCommunicationPort();
  runApp(const App());
}
