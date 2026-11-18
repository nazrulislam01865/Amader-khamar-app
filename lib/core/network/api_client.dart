import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;

import '../constants/api_constants.dart';
import '../storage/local_storage_service.dart';

class ApiException implements Exception {
  final int statusCode;
  final String message;
  final dynamic errors;

  ApiException(this.statusCode, this.message, [this.errors]);

  @override
  String toString() => 'ApiException: $statusCode - $message';
}

class NetworkException implements Exception {
  final String message;
  NetworkException([this.message = 'ইন্টারনেট সংযোগ পাওয়া যায়নি।']);

  @override
  String toString() => message;
}

class ApiClient {
  static void Function()? onUnauthorized;
  static bool _isHandlingUnauthorized = false;

  final http.Client _client;
  String? _authToken;

  ApiClient({http.Client? client}) : _client = client ?? http.Client() {
    _authToken = LocalStorageService.instance.getString(ApiConstants.tokenKey);
  }

  void setAuthToken(String? token) {
    _authToken = token;
    // Storage is exclusively owned by AuthService; no unawaited writes here.
  }

  String? get authToken =>
      _authToken ?? LocalStorageService.instance.getString(ApiConstants.tokenKey);

  Map<String, String> _buildHeaders([Map<String, String>? customHeaders]) {
    final headers = <String, String>{
      'Accept': 'application/json',
      'Content-Type': 'application/json',
    };
    final effectiveToken = authToken;
    if (effectiveToken != null && effectiveToken.isNotEmpty) {
      headers['Authorization'] = 'Bearer $effectiveToken';
    }
    if (customHeaders != null) {
      headers.addAll(customHeaders);
    }
    return headers;
  }

  Uri _buildUri(String path, [Map<String, dynamic>? queryParams, String? overrideBase]) {
    final base = (overrideBase ?? ApiConstants.baseUrl).replaceAll(RegExp(r'/+$'), '');
    final cleanPath = path.startsWith('/') ? path : '/$path';
    final fullUrl = '$base$cleanPath';

    if (queryParams != null && queryParams.isNotEmpty) {
      final stringParams = queryParams.map(
        (k, v) => MapEntry(k, v?.toString() ?? ''),
      );
      return Uri.parse(fullUrl).replace(queryParameters: stringParams);
    }
    return Uri.parse(fullUrl);
  }

  Uri _validateEndpoint(Uri uri) {
    if (uri.userInfo.isNotEmpty || uri.host.isEmpty || uri.hasFragment) {
      throw const FormatException('Invalid API endpoint.');
    }
    const release = bool.fromEnvironment('dart.vm.product');
    if (release && uri.scheme != 'https') {
      throw StateError('Production API requires a configured HTTPS endpoint.');
    }
    if (uri.scheme != 'https' && uri.scheme != 'http') {
      throw const FormatException('Unsupported API scheme.');
    }
    return uri;
  }

  /// No implicit redirect forwarding of Authorization or multipart evidence.
  /// API_HOST must point directly to the canonical HTTPS origin.
  Future<http.Response> _send(http.BaseRequest request, Duration timeout) async {
    request.followRedirects = false;
    final stream = await _client.send(request).timeout(timeout);
    return http.Response.fromStream(stream).timeout(timeout);
  }

  http.Request _jsonRequest(String method, Uri uri, [dynamic body]) {
    final request = http.Request(method, _validateEndpoint(uri));
    request.headers.addAll(_buildHeaders());
    if (body != null) request.body = jsonEncode(body);
    return request;
  }

  Future<Map<String, dynamic>> get(String path, {Map<String, dynamic>? queryParams}) async {
    try {
      final response = await _send(_jsonRequest('GET', _buildUri(path, queryParams)), const Duration(seconds: 15));
      return _processResponse(response);
    } on SocketException catch (_) {
      throw NetworkException();
    } on TimeoutException catch (_) {
      throw NetworkException('অনুরোধটির সময় শেষ হয়ে গেছে।');
    } on http.ClientException catch (_) {
      throw NetworkException('সার্ভারের সংযোগ বিচ্ছিন্ন হয়েছে।');
    }
  }

  Future<Map<String, dynamic>> post(String path, {dynamic body}) async {
    try {
      final response = await _send(_jsonRequest('POST', _buildUri(path), body), const Duration(seconds: 20));
      return _processResponse(response);
    } on SocketException catch (_) {
      throw NetworkException();
    } on TimeoutException catch (_) {
      throw NetworkException('অনুরোধটির সময় শেষ হয়ে গেছে।');
    } on http.ClientException catch (_) {
      throw NetworkException('সার্ভারের নিশ্চিতকরণ পাওয়া যায়নি।');
    }
  }

  Future<Map<String, dynamic>> postMultipart(String path, {
    required Map<String, String> fields,
    List<http.MultipartFile>? files,
    Map<String, String>? extraHeaders,
  }) async {
    try {
      final request = http.MultipartRequest('POST', _validateEndpoint(_buildUri(path)));
      final headers = _buildHeaders()..remove('Content-Type');
      request.headers.addAll(headers);
      // Allow stable idempotency header but not Authorization overriding the active account.
      if (extraHeaders != null) {
        for (final entry in extraHeaders.entries) {
          if (entry.key.toLowerCase() == 'idempotency-key') request.headers[entry.key] = entry.value;
        }
      }
      request.fields.addAll(fields);
      if (files != null) request.files.addAll(files);
      final response = await _send(request, const Duration(seconds: 40));
      return _processResponse(response);
    } on SocketException catch (_) {
      throw NetworkException();
    } on TimeoutException catch (_) {
      throw NetworkException('ফাইল আপলোডের সময় শেষ হয়ে গেছে।');
    } on http.ClientException catch (_) {
      throw NetworkException('সার্ভারের নিশ্চিতকরণ পাওয়া যায়নি।');
    }
  }

  Map<String, dynamic> _processResponse(http.Response response) {
    dynamic decoded;
    try {
      decoded = jsonDecode(response.body);
    } catch (_) {
      decoded = {'message': response.body};
    }

    if (response.statusCode >= 300 && response.statusCode < 400) {
      throw ApiException(response.statusCode, 'API redirected. Check the configured HTTPS URL.');
    }
    if (response.statusCode >= 200 && response.statusCode < 300) {
      if (decoded is Map<String, dynamic>) {
        return decoded;
      }
      return {'data': decoded, 'success': true};
    }

    String message;
    if (decoded is Map && decoded['message'] != null) {
      final rawMsg = decoded['message'].toString();
      if (rawMsg.trim().startsWith('<') || rawMsg.contains('<html') || rawMsg.contains('<body')) {
        message = 'সার্ভার সংযোগে সমস্যা হয়েছে (কোড: ${response.statusCode})';
      } else {
        message = rawMsg;
      }
    } else {
      message = 'সার্ভার ত্রুটি: ${response.statusCode}';
    }
    final errors = (decoded is Map && decoded['errors'] != null) ? decoded['errors'] : null;

    if (response.statusCode == 401 && !_isHandlingUnauthorized) {
      final hasToken = authToken != null && authToken!.isNotEmpty;
      if (hasToken) {
        _isHandlingUnauthorized = true;
        try {
          onUnauthorized?.call();
        } finally {
          _isHandlingUnauthorized = false;
        }
      }
    }

    throw ApiException(response.statusCode, message, errors);
  }
}
