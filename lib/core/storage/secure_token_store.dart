import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Platform-backed credential storage. Inject a fake in tests; never persist
/// bearer tokens in SharedPreferences or a Dart fallback file.
abstract class SecureTokenStore {
  Future<String?> read();
  Future<void> write(String token);
  Future<void> delete();
}

class PlatformSecureTokenStore implements SecureTokenStore {
  final FlutterSecureStorage _storage;
  PlatformSecureTokenStore([FlutterSecureStorage? storage])
      : _storage = storage ?? const FlutterSecureStorage(
          aOptions: AndroidOptions(migrateWithBackup: true),
        );

  static const _key = 'bashir_agro_auth_token';
  @override
  Future<String?> read() => _storage.read(key: _key);
  @override
  Future<void> write(String token) => _storage.write(key: _key, value: token);
  @override
  Future<void> delete() => _storage.delete(key: _key);
}

class MemorySecureTokenStore implements SecureTokenStore {
  String? value;
  MemorySecureTokenStore([this.value]);
  @override Future<String?> read() async => value;
  @override
  Future<void> write(String token) async { value = token; }
  @override
  Future<void> delete() async { value = null; }
}
