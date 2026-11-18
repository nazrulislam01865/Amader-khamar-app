import '../core/constants/api_constants.dart';
import '../core/network/api_client.dart';
import '../core/storage/local_storage_service.dart';
import '../models/auth_model.dart';
import 'api_service.dart';

class AuthService {
  final ApiService _apiService;
  final LocalStorageService _storage;

  AuthUser? _currentUser;
  FarmerProfile? _farmerProfile;
  String? _token;
  bool lastLogoutRevocationConfirmed = false;
  bool _logoutWarningPending = false;

  bool takeLogoutRevocationWarning() {
    final pending = _logoutWarningPending;
    _logoutWarningPending = false;
    return pending;
  }

  /// Callback when backend returns 401 Unauthorized
  void Function()? onSessionExpired;

  AuthService({ApiService? apiService, LocalStorageService? storage})
      : _apiService = apiService ?? ApiService(),
        _storage = storage ?? LocalStorageService.instance {
    _restoreSessionFromStorage();
    ApiClient.onUnauthorized = () {
      _handleUnauthorized();
    };
  }

  Future<void> _handleUnauthorized() async {
    _token = null;
    _currentUser = null;
    _farmerProfile = null;
    _apiService.client.setAuthToken(null);
    try {
      await _storage.clearAuthSession();
    } finally {
      onSessionExpired?.call();
    }
  }

  AuthUser? get currentUser => _currentUser;
  FarmerProfile? get farmerProfile => _farmerProfile;
  String? get token => _token;
  bool get isAuthenticated => _token != null && _token!.isNotEmpty;

  void _restoreSessionFromStorage() {
    _token = _storage.getString(ApiConstants.tokenKey);
    final userJson = _storage.getJson(ApiConstants.userKey);
    final profileJson = _storage.getJson(ApiConstants.profileKey);

    if (userJson != null) {
      try {
        _currentUser = AuthUser.fromJson(userJson as Map<String, dynamic>);
      } catch (_) {}
    }
    if (profileJson != null) {
      try {
        _farmerProfile = FarmerProfile.fromJson(profileJson as Map<String, dynamic>);
      } catch (_) {}
    }

    if (_token != null && _token!.isNotEmpty) {
      _apiService.client.setAuthToken(_token);
    }
  }

  /// Initialize and restore stored session
  Future<bool> initializeSession() async {
    _restoreSessionFromStorage();
    return isAuthenticated;
  }

  /// Validates session with backend (/auth/me). If token is rejected (401), clears session.
  Future<bool> validateSessionWithBackend() async {
    if (!isAuthenticated) return false;

    try {
      final user = await _apiService.getMe();
      _currentUser = user;
      await _storage.setJson(ApiConstants.userKey, user.toJson());
      return true;
    } on ApiException catch (e) {
      if (e.statusCode == 401 || e.statusCode == 403) {
        await logout();
        return false;
      }
      return true;
    } catch (_) {
      // Offline / network failure -> allow cached offline session
      return true;
    }
  }

  /// Perform login against Laravel API
  Future<LoginResponse> login(String login, String password) async {
    try {
      final response = await _apiService.login(login, password);

      if (response.success && response.token != null) {
        // Require successful secure persistence before declaring login.
        await _storage.setString(ApiConstants.tokenKey, response.token!);
        _token = response.token;
        _currentUser = response.user;
        _farmerProfile = response.farmerProfile;
        _apiService.client.setAuthToken(_token);
        if (_currentUser != null) {
          await _storage.setJson(ApiConstants.userKey, _currentUser!.toJson());
        }
        if (_farmerProfile != null) {
          await _storage.setJson(ApiConstants.profileKey, _farmerProfile!.toJson());
        }
      }
      return response;
    } catch (_) {
      // Never authenticate a cached identity by phone alone without verifying the password.
      rethrow;
    }
  }

  /// Revoke the active token before deleting local credentials; queued
  /// evidence is preserved and cannot be uploaded under another account.
  Future<void> logout() async {
    lastLogoutRevocationConfirmed = false;
    _logoutWarningPending = false;
    final active = _token;
    if (active != null && active.isNotEmpty) {
      _apiService.client.setAuthToken(active);
      try {
        await _apiService.logout().timeout(const Duration(seconds: 5));
        lastLogoutRevocationConfirmed = true;
      } catch (_) {
        // Server token may remain valid; show uncertainty after returning to login.
        _logoutWarningPending = true;
      }
    }
    try {
      await _storage.clearAuthSession();
    } finally {
      _token = null;
      _currentUser = null;
      _farmerProfile = null;
      _apiService.client.setAuthToken(null);
    }
  }
}
