import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:bashir_agro_app_2/core/constants/api_constants.dart';
import 'package:bashir_agro_app_2/core/config/mapbox_config.dart';
import 'package:bashir_agro_app_2/core/network/api_client.dart';
import 'package:bashir_agro_app_2/core/storage/local_storage_service.dart';
import 'package:bashir_agro_app_2/core/storage/secure_token_store.dart';
import 'package:bashir_agro_app_2/services/api_service.dart';
import 'package:bashir_agro_app_2/services/auth_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final store = LocalStorageService.instance;
  setUp(() {
    ApiConstants.baseUrl = 'https://staging.example.test/api/v1';
  });

  test('migrates plaintext legacy token with readback, leaves evidence intact', () async {
    SharedPreferences.setMockInitialValues({
      ApiConstants.tokenKey: 'legacy-secret',
      ApiConstants.offlineQueueKey: 'pending-evidence',
    });
    final secure = MemorySecureTokenStore();
    store.setSecureStoreForTest(secure);
    await store.init();
    expect(store.getString(ApiConstants.tokenKey), 'legacy-secret');
    expect(secure.value, 'legacy-secret');
    expect((await SharedPreferences.getInstance()).containsKey(ApiConstants.tokenKey), false);
    await store.clearAuthSession();
    expect(secure.value, isNull);
    expect(store.getString(ApiConstants.offlineQueueKey), 'pending-evidence');
  });

  test('does not reuse a plaintext token when secure storage cannot write', () async {
    SharedPreferences.setMockInitialValues({ApiConstants.tokenKey: 'unprotected'});
    store.setSecureStoreForTest(_BrokenSecureStore());
    await store.init();
    expect(store.getString(ApiConstants.tokenKey), isNull);
    expect((await SharedPreferences.getInstance()).containsKey(ApiConstants.tokenKey), false);
  });

  test('rejects cross-origin redirect without leaking bearer token', () async {
    var count = 0;
    final client = ApiClient(client: MockClient((request) async {
      count++;
      expect(request.headers['authorization'], 'Bearer private-token');
      return http.Response('', 302, headers: {'location': 'https://attacker.invalid/steal'});
    }));
    client.setAuthToken('private-token');
    await expectLater(client.get('/assignments'), throwsA(isA<ApiException>()));
    expect(count, 1);
  });

  test('logout revokes before local token deletion; evidence survives', () async {
    SharedPreferences.setMockInitialValues({ApiConstants.offlineQueueKey: 'pending-evidence'});
    final secure = MemorySecureTokenStore();
    store.setSecureStoreForTest(secure);
    await store.init();
    await store.setString(ApiConstants.tokenKey, 'live-secret');
    var sent = false;
    final apiClient = ApiClient(client: MockClient((request) async {
      expect(request.url.path, '/api/v1/auth/logout');
      expect(request.headers['authorization'], 'Bearer live-secret');
      sent = true;
      return http.Response('{"success":true}', 200, headers: {'content-type': 'application/json'});
    }));
    final auth = AuthService(apiService: ApiService(client: apiClient), storage: store);
    await auth.logout();
    expect(sent, true);
    expect(secure.value, isNull);
    expect(store.getString(ApiConstants.offlineQueueKey), 'pending-evidence');
  });

  test('restores previous satellite/street tile source selection', () {
    MapboxConfig.accessToken = null;
    expect(MapboxConfig.getSatelliteTileUrl(), contains('mt{s}.google.com'));
    expect(MapboxConfig.getStreetTileUrl(), contains('tile.openstreetmap.org'));
    expect(MapboxConfig.getSatelliteSubdomains(), contains('0'));
    MapboxConfig.accessToken = 'test-token';
    expect(MapboxConfig.getSatelliteTileUrl(), contains('api.mapbox.com'));
    expect(MapboxConfig.getStreetTileUrl(), contains('access_token=test-token'));
    MapboxConfig.accessToken = null;
  });

}

class _BrokenSecureStore implements SecureTokenStore {
  @override Future<String?> read() async => null;
  @override Future<void> write(String token) async => throw StateError('keystore locked');
  @override Future<void> delete() async {}
}
