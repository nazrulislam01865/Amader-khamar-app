import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import '../constants/api_constants.dart';
import 'secure_token_store.dart';

class LocalStorageService {
  static LocalStorageService? _instance;
  final Map<String, dynamic> _memoryCache = {};
  SharedPreferences? _prefs;
  SecureTokenStore _secureTokens = PlatformSecureTokenStore();
  String? _secureToken;
  bool _tokenReady = false;

  LocalStorageService._();

  static LocalStorageService get instance {
    _instance ??= LocalStorageService._();
    return _instance!;
  }

  Future<void> init() async {
    try {
      _prefs = await SharedPreferences.getInstance();
    } catch (_) {
      // Preferences unavailable in isolated unit tests; token security stays fail-closed.
      _prefs = null;
    }
    await restoreSecureToken();
  }

  /// Must complete before app router reads a session. If the keystore is
  /// unreadable, require login instead of restoring unencrypted credentials.
  Future<void> restoreSecureToken() async {
    _secureToken = null;
    _tokenReady = false;
    try {
      final existing = await _secureTokens.read();
      if (existing != null && existing.isNotEmpty) {
        _secureToken = existing;
        // Clear any leftover legacy token without modifying evidence or tasks.
        await _prefs?.remove(ApiConstants.tokenKey);
      } else {
        final legacy = _prefs?.getString(ApiConstants.tokenKey);
        if (legacy != null && legacy.isNotEmpty) {
          await _secureTokens.write(legacy);
          final verified = await _secureTokens.read();
          if (verified != legacy) throw StateError('Secure token migration failed.');
          _secureToken = verified;
          await _prefs!.remove(ApiConstants.tokenKey);
        }
      }
    } catch (_) {
      // Fail closed: force re-login; never retain a usable plaintext token.
      _secureToken = null;
      try { await _prefs?.remove(ApiConstants.tokenKey); } catch (_) {}
    } finally {
      _tokenReady = true;
    }
  }

  void setSecureStoreForTest(SecureTokenStore store) {
    _secureTokens = store;
    _secureToken = null;
    _tokenReady = false;
  }

  Future<void> clearAuthSession() async {
    await remove(ApiConstants.tokenKey);
    await remove(ApiConstants.userKey);
    await remove(ApiConstants.profileKey);
  }

  // Set shared preferences directly (useful for tests)
  void setPreferencesForTest(SharedPreferences prefs) {
    _prefs = prefs;
  }

  Future<void> setString(String key, String value) async {
    if (key == ApiConstants.tokenKey) {
      await _secureTokens.write(value);
      if (await _secureTokens.read() != value) {
        throw StateError('Unable to verify secure credential write.');
      }
      _secureToken = value;
      _tokenReady = true;
      await _prefs?.remove(ApiConstants.tokenKey);
      return;
    }
    _memoryCache[key] = value;
    if (_prefs != null) await _prefs!.setString(key, value);
  }

  String? getString(String key) {
    if (key == ApiConstants.tokenKey) {
      return _tokenReady ? _secureToken : null;
    }
    if (_memoryCache.containsKey(key)) {
      return _memoryCache[key] as String?;
    }
    final val = _prefs?.getString(key);
    if (val != null) {
      _memoryCache[key] = val;
    }
    return val;
  }

  Future<void> setJson(String key, dynamic value) async {
    final str = jsonEncode(value);
    await setString(key, str);
  }

  dynamic getJson(String key) {
    final str = getString(key);
    if (str == null || str.isEmpty) return null;
    try {
      return jsonDecode(str);
    } catch (_) {
      return null;
    }
  }

  Future<void> remove(String key) async {
    if (key == ApiConstants.tokenKey) {
      await _secureTokens.delete();
      _secureToken = null;
      _tokenReady = true;
      await _prefs?.remove(ApiConstants.tokenKey);
      return;
    }
    _memoryCache.remove(key);
    if (_prefs != null) await _prefs!.remove(key);
  }

  /// Session cleanup never deletes unsynced evidence or task caches.
  Future<void> clearAll() async {
    await clearAuthSession();
    _memoryCache.clear();
  }

  /// Isolated unit-test reset only. Runtime code must never call this.
  Future<void> resetForTest() async {
    await clearAuthSession();
    _memoryCache.clear();
    await _prefs?.clear();
  }
}
