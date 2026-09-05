/// SharedPreferences wrapper, used from both isolates.
///
/// The service isolate has its own copy of the preference cache, so every read
/// there must be preceded by [reload].
library;

import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../matcher/keyword_matcher.dart';
import '../model/app_config.dart';

class SettingsStore {
  SettingsStore(this._prefs);

  static const String keyApiId = 'apiId';
  static const String keyApiHash = 'apiHash';
  static const String keyTargetChatId = 'targetChatId';
  static const String keyMaxAgeMinutes = 'maxAgeMinutes';
  static const String keyFolderId = 'folderId';
  static const String keyFolderName = 'folderName';
  static const String keyKeywords = 'keywords';
  static const String keyMonitoringActive = 'monitoringActive';
  static const String keyCachedChats = 'cachedChats';
  static const String keyPhoneDisplay = 'phoneDisplay';
  static const String keyAlertDelivery = 'alertDelivery';

  final SharedPreferences _prefs;

  static Future<SettingsStore> open() async =>
      SettingsStore(await SharedPreferences.getInstance());

  /// Picks up writes made by the other isolate.
  Future<void> reload() => _prefs.reload();

  // --- Telegram application credentials -----------------------------------

  int get apiId => _prefs.getInt(keyApiId) ?? 0;
  Future<void> setApiId(int value) => _prefs.setInt(keyApiId, value);

  String get apiHash => _prefs.getString(keyApiHash) ?? '';
  Future<void> setApiHash(String value) => _prefs.setString(keyApiHash, value);

  TdCredentials get credentials =>
      TdCredentials(apiId: apiId, apiHash: apiHash);

  String get phoneDisplay => _prefs.getString(keyPhoneDisplay) ?? '';
  Future<void> setPhoneDisplay(String value) =>
      _prefs.setString(keyPhoneDisplay, value);

  // --- Monitoring configuration -------------------------------------------

  bool get monitoringActive => _prefs.getBool(keyMonitoringActive) ?? false;
  Future<void> setMonitoringActive(bool value) =>
      _prefs.setBool(keyMonitoringActive, value);

  MonitorConfig readConfig() {
    final rawChats = _prefs.getString(keyCachedChats);
    final chats = <ChatRef>[];
    if (rawChats != null && rawChats.isNotEmpty) {
      try {
        final decoded = jsonDecode(rawChats);
        if (decoded is List) {
          for (final item in decoded) {
            if (item is Map) {
              chats.add(ChatRef.fromJson(Map<String, dynamic>.from(item)));
            }
          }
        }
      } catch (_) {
        // A corrupt cache is not fatal: the folder is re-resolved on start.
      }
    }

    final folderId = _prefs.getInt(keyFolderId);
    return MonitorConfig(
      folderId: (folderId ?? -1) < 0 ? null : folderId,
      folderName: _prefs.getString(keyFolderName) ?? '',
      keywords: _prefs.getStringList(keyKeywords) ?? const <String>[],
      targetChatId: _prefs.getString(keyTargetChatId) ?? '',
      maxAgeMinutes:
          _prefs.getInt(keyMaxAgeMinutes) ?? MonitorConfig.defaultMaxAgeMinutes,
      chats: chats,
      delivery: AlertDelivery.parse(_prefs.getString(keyAlertDelivery)),
    );
  }

  Future<void> writeConfig(MonitorConfig config) async {
    await _prefs.setInt(keyFolderId, config.folderId ?? -1);
    await _prefs.setString(keyFolderName, config.folderName);
    await _prefs.setStringList(
      keyKeywords,
      KeywordMatcher.sanitize(config.keywords),
    );
    await _prefs.setString(keyTargetChatId, config.targetChatId);
    await _prefs.setInt(
      keyMaxAgeMinutes,
      config.maxAgeMinutes.clamp(
        MonitorConfig.minMaxAgeMinutes,
        MonitorConfig.maxMaxAgeMinutes,
      ),
    );
    await _prefs.setString(keyAlertDelivery, config.delivery.name);
    await writeCachedChats(config.chats);
  }

  Future<void> writeCachedChats(List<ChatRef> chats) => _prefs.setString(
    keyCachedChats,
    jsonEncode([for (final chat in chats) chat.toJson()]),
  );

  /// Clears the session-scoped state after a log out, keeping api credentials.
  Future<void> clearSession() async {
    await _prefs.remove(keyPhoneDisplay);
    await _prefs.setBool(keyMonitoringActive, false);
  }
}
