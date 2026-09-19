import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tg_alert_monitor/core/model/app_config.dart';
import 'package:tg_alert_monitor/core/storage/settings_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<SettingsStore> openWith(Map<String, Object> initial) async {
    SharedPreferences.setMockInitialValues(initial);
    return SettingsStore.open();
  }

  test('an empty store yields safe defaults', () async {
    final store = await openWith({});
    final config = store.readConfig();

    expect(store.apiId, 0);
    expect(store.apiHash, '');
    expect(store.monitoringActive, isFalse);
    expect(config.folderId, isNull);
    expect(config.keywords, isEmpty);
    expect(config.maxAgeMinutes, MonitorConfig.defaultMaxAgeMinutes);
    expect(config.delivery, AlertDelivery.forward);
    expect(config.isRunnable, isFalse);
  });

  test('a full config survives a write/read round trip', () async {
    final store = await openWith({});
    const config = MonitorConfig(
      folderId: 7,
      folderName: 'Тривога',
      keywords: ['шахед', 'балістика'],
      targetChatId: '-1001234567890',
      maxAgeMinutes: 25,
      chats: [
        ChatRef(id: -100111, title: 'Канал А', isChannel: true),
        ChatRef(id: -100222, title: 'Група Б'),
      ],
      delivery: AlertDelivery.both,
      alertCooldownSeconds: 90,
    );

    await store.writeConfig(config);
    final restored = store.readConfig();

    expect(restored.folderId, 7);
    expect(restored.folderName, 'Тривога');
    expect(restored.keywords, ['шахед', 'балістика']);
    expect(restored.targetChatId, '-1001234567890');
    expect(restored.maxAgeMinutes, 25);
    expect(restored.chats, config.chats);
    expect(restored.delivery, AlertDelivery.both);
    expect(restored.alertCooldownSeconds, 90);
    expect(restored.isRunnable, isTrue);
  });

  test('an empty store yields the default alert pause', () async {
    final store = await openWith({});

    expect(
      store.readConfig().alertCooldownSeconds,
      MonitorConfig.defaultAlertCooldownSeconds,
    );
    expect(
      store.readConfig().alertCooldown,
      const Duration(seconds: MonitorConfig.defaultAlertCooldownSeconds),
    );
  });

  test('an out-of-range alert pause is clamped on the way in', () async {
    final store = await openWith({});

    await store.writeConfig(const MonitorConfig(alertCooldownSeconds: 99999));
    expect(
      store.readConfig().alertCooldownSeconds,
      MonitorConfig.maxAlertCooldownSeconds,
    );

    await store.writeConfig(const MonitorConfig(alertCooldownSeconds: -5));
    expect(
      store.readConfig().alertCooldownSeconds,
      MonitorConfig.minAlertCooldownSeconds,
    );
  });

  test('«Локально» is runnable without a target channel', () async {
    final store = await openWith({});
    const config = MonitorConfig(
      folderId: 7,
      keywords: ['шахед'],
      delivery: AlertDelivery.local,
    );

    await store.writeConfig(config);
    final restored = store.readConfig();

    expect(restored.delivery, AlertDelivery.local);
    expect(restored.targetChatId, isEmpty);
    expect(restored.isRunnable, isTrue);
    // The same config with forwarding switched back on is not.
    expect(
      restored.copyWith(delivery: AlertDelivery.forward).isRunnable,
      isFalse,
    );
  });

  test('an unknown delivery mode falls back to forwarding', () async {
    final store = await openWith({SettingsStore.keyAlertDelivery: 'telepathy'});

    expect(store.readConfig().delivery, AlertDelivery.forward);
  });

  test('keywords are de-duplicated case-insensitively on write', () async {
    final store = await openWith({});
    await store.writeConfig(
      const MonitorConfig(keywords: ['Шахед', 'шахед', ' ', 'ШАХЕД', 'Дрон']),
    );
    expect(store.readConfig().keywords, ['Шахед', 'Дрон']);
  });

  test('maxAgeMinutes is clamped to the documented range', () async {
    final store = await openWith({});

    await store.writeConfig(const MonitorConfig(maxAgeMinutes: 0));
    expect(store.readConfig().maxAgeMinutes, MonitorConfig.minMaxAgeMinutes);

    await store.writeConfig(const MonitorConfig(maxAgeMinutes: 9999));
    expect(store.readConfig().maxAgeMinutes, MonitorConfig.maxMaxAgeMinutes);
  });

  test('api credentials are stored and validated', () async {
    final store = await openWith({});
    await store.setApiId(1234567);
    await store.setApiHash('0123456789abcdef0123456789ABCDEF');

    expect(store.credentials.apiId, 1234567);
    expect(store.credentials.isValid, isTrue);

    await store.setApiHash('too-short');
    expect(store.credentials.isValid, isFalse);

    await store.setApiHash('0123456789abcdef0123456789abcdef');
    await store.setApiId(0);
    expect(store.credentials.isValid, isFalse);
  });

  test('a corrupt cached-chats blob does not break reading', () async {
    final store = await openWith({
      SettingsStore.keyCachedChats: 'definitely not json',
      SettingsStore.keyFolderId: 3,
    });
    final config = store.readConfig();
    expect(config.chats, isEmpty);
    expect(config.folderId, 3);
  });

  test('a folderId of -1 reads back as "no folder selected"', () async {
    final store = await openWith({});
    await store.writeConfig(const MonitorConfig());
    expect(store.readConfig().folderId, isNull);
  });

  test('clearSession stops monitoring but keeps api credentials', () async {
    final store = await openWith({});
    await store.setApiId(42);
    await store.setApiHash('0123456789abcdef0123456789abcdef');
    await store.setMonitoringActive(true);
    await store.setPhoneDisplay('+380…');

    await store.clearSession();

    expect(store.monitoringActive, isFalse);
    expect(store.phoneDisplay, '');
    expect(store.apiId, 42);
    expect(store.credentials.isValid, isTrue);
  });

  test('monitoringActive persists', () async {
    final store = await openWith({});
    await store.setMonitoringActive(true);
    expect(store.monitoringActive, isTrue);
    await store.setMonitoringActive(false);
    expect(store.monitoringActive, isFalse);
  });
}
