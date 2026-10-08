import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// The Komga API key, kept encrypted: on Android with a key held in the Android Keystore, on Windows with DPAPI (only
/// this Windows user can read it). It used to sit in plain text in the app's settings file (backlog, user 2026-09-28;
/// done 2026-10-08 - no migration: the key is entered once more).
class KeyStore {
  static const _storage = FlutterSecureStorage();
  static const _name = 'apiKey';

  /// The saved key; null if there's none, or it can't be read (the device's keystore reset): signed out.
  static Future<String?> read() async {
    try {
      return await _storage.read(key: _name);
    } catch (_) {
      return null;
    }
  }

  static Future<void> write(String key) => _storage.write(key: _name, value: key);

  static Future<void> delete() async {
    try {
      await _storage.delete(key: _name);
    } catch (_) {
      // nothing readable to remove
    }
  }
}
