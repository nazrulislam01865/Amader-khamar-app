import 'dart:convert';
import 'dart:typed_data';
import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';

import '../core/constants/api_constants.dart';
import '../core/network/api_client.dart';
import '../models/auth_model.dart';
import '../models/task_assignment_model.dart';
import '../models/submission_model.dart';
import '../models/notification_model.dart';
import '../data/models/owner_models.dart';

class ApiService {
  final ApiClient _client;

  ApiService({ApiClient? client}) : _client = client ?? ApiClient();

  ApiClient get client => _client;

  /// Authenticate with phone/email and password
  Future<LoginResponse> login(String login, String password, [String? deviceName]) async {
    final response = await _client.post(
      ApiConstants.login,
      body: {
        'login': login,
        'password': password,
        'device_name': deviceName ?? 'bashir-agro-farmer-app',
      },
    );
    return LoginResponse.fromJson(response);
  }

  /// Get current authenticated user profile
  Future<AuthUser> getMe() async {
    final response = await _client.get(ApiConstants.me);
    final data = response['data'] as Map<String, dynamic>;
    return AuthUser.fromJson(data['user']);
  }

  /// Logout and invalidate session
  Future<void> logout() async {
    await _client.post(ApiConstants.logout);
  }

  /// Get Farmer Profile
  Future<FarmerProfile> getFarmerProfile() async {
    final response = await _client.get(ApiConstants.farmerProfile);
    return FarmerProfile.fromJson(response['data']);
  }

  /// Get Assignments (Today's, Pending, Completed)
  Future<List<TaskAssignmentModel>> getAssignments({
    String? status,
    String? date,
    int? perPage,
  }) async {
    final queryParams = <String, dynamic>{};
    if (status != null && status.isNotEmpty) queryParams['status'] = status;
    if (date != null && date.isNotEmpty) queryParams['date'] = date;
    if (perPage != null) queryParams['per_page'] = perPage;

    queryParams['per_page'] = perPage ?? 100;
    final tasks = <TaskAssignmentModel>[];
    var page = 1;
    while (true) {
      queryParams['page'] = page;
      final response = await _client.get(ApiConstants.assignments, queryParams: queryParams);
      final data = response['data'] as List<dynamic>? ?? [];
      tasks.addAll(data.map((item) => TaskAssignmentModel.fromJson(item as Map<String, dynamic>)));
      final meta = response['meta'] as Map<String, dynamic>?;
      final lastPage = int.tryParse(meta?['last_page']?.toString() ?? '1') ?? 1;
      if (page >= lastPage || data.isEmpty) break;
      page++;
    }
    return tasks;
  }

  /// Get Assignment Details
  Future<TaskAssignmentModel> getAssignmentDetails(int id) async {
    final response = await _client.get(ApiConstants.assignmentDetails(id));
    return TaskAssignmentModel.fromJson(response['data']);
  }

  /// Start Assignment (transitions to in_progress)
  Future<TaskAssignmentModel> startAssignment(int id) async {
    final response = await _client.post(ApiConstants.startAssignment(id));
    return TaskAssignmentModel.fromJson(response['data']);
  }

  /// Submit Assignment with GPS coordinates and evidence photos
  Future<ApiSubmissionResult> submitAssignment({
    required int assignmentId,
    required double latitude,
    required double longitude,
    double? accuracy,
    String? notes,
    List<Uint8List>? photoBytesList,
    List<Map<String, dynamic>>? photoMetadata,
    bool overrideGeofence = false,
    String? idempotencyKey,
  }) async {
    final fields = <String, String>{
      'latitude': latitude.toString(),
      'longitude': longitude.toString(),
    };
    if (accuracy != null) {
      fields['accuracy'] = accuracy.toString();
    }
    if (notes != null && notes.isNotEmpty) {
      fields['notes'] = notes;
    }
    if (overrideGeofence) {
      fields['override_geofence'] = '1';
    }
    if (photoMetadata != null && photoMetadata.isNotEmpty) {
      fields['photo_metadata'] = jsonEncode(photoMetadata);
    }

    final files = <http.MultipartFile>[];
    if (photoBytesList != null) {
      for (int i = 0; i < photoBytesList.length; i++) {
        final bytes = photoBytesList[i];
        final isPng = bytes.length > 8 &&
            bytes[0] == 0x89 &&
            bytes[1] == 0x50 &&
            bytes[2] == 0x4E &&
            bytes[3] == 0x47;
        final ext = isPng ? 'png' : 'jpg';
        final mimeType = isPng ? MediaType('image', 'png') : MediaType('image', 'jpeg');

        files.add(
          http.MultipartFile.fromBytes(
            'photos[]',
            bytes,
            filename: 'evidence_${assignmentId}_$i.$ext',
            contentType: mimeType,
          ),
        );
      }
    }

    final response = await _client.postMultipart(
      ApiConstants.submitAssignment(assignmentId),
      fields: fields,
      files: files,
      extraHeaders: idempotencyKey == null ? null : {'Idempotency-Key': idempotencyKey},
    );

    return ApiSubmissionResult.fromJson(response);
  }

  Future<Map<String, dynamic>?> lookupSubmissionReceipt(int assignmentId, String key) async {
    try {
      final response = await _client.get('/assignments/$assignmentId/submission-receipts/$key');
      if (response['success'] != true) return null;
      final receipt = response['receipt'];
      return receipt is Map<String, dynamic> ? receipt : null;
    } on ApiException catch (e) {
      if (e.statusCode == 404) return null;
      rethrow;
    }
  }

  /// Submit farmer self-reported completed task
  Future<TaskAssignmentModel> selfReportTask({
    required String description,
    double? latitude,
    double? longitude,
    double? accuracy,
    int? locationId,
    Uint8List? photoBytes,
    String? photoFileName,
  }) async {
    final fields = <String, String>{
      'description': description,
    };
    if (latitude != null) fields['latitude'] = latitude.toString();
    if (longitude != null) fields['longitude'] = longitude.toString();
    if (accuracy != null) fields['accuracy'] = accuracy.toString();
    if (locationId != null) fields['farm_location_id'] = locationId.toString();

    final files = <http.MultipartFile>[];
    if (photoBytes != null && photoBytes.isNotEmpty) {
      files.add(
        http.MultipartFile.fromBytes(
          'photos[]',
          photoBytes,
          filename: photoFileName ?? 'evidence_${DateTime.now().millisecondsSinceEpoch}.jpg',
          contentType: MediaType('image', 'jpeg'),
        ),
      );
    }

    final response = await _client.postMultipart(
      '/farmer/self-report-task',
      fields: fields,
      files: files,
    );

    return TaskAssignmentModel.fromJson(response['data'] as Map<String, dynamic>);
  }

  /// Get Farms with Field Boundary polygons (Phase 12A V2 / 12B V2)
  Future<List<FarmLocationDetail>> getFarms() async {
    final response = await _client.get(ApiConstants.farms);
    final data = response['data'] as List<dynamic>?;
    if (data == null) return [];
    return data
        .map((item) => FarmLocationDetail.fromJson(item as Map<String, dynamic>))
        .toList();
  }

  /// Get Farm Details with boundary polygon
  Future<FarmLocationDetail> getFarmDetails(int id) async {
    final response = await _client.get(ApiConstants.farmDetails(id));
    return FarmLocationDetail.fromJson(response['data'] as Map<String, dynamic>);
  }

  /// Get Farm Location Details
  Future<FarmLocationDetail> getLocationDetails(int id) async {
    final response = await _client.get(ApiConstants.locationDetails(id));
    return FarmLocationDetail.fromJson(response['data'] as Map<String, dynamic>);
  }

  /// Get Owner Dashboard summary (KPIs, farmers progress, active locations)
  Future<Map<String, dynamic>> getOwnerDashboard({String? date, int? locationId}) async {
    final queryParams = <String, dynamic>{};
    if (date != null && date.isNotEmpty) queryParams['date'] = date;
    if (locationId != null && locationId > 0) queryParams['location_id'] = locationId;

    final response = await _client.get(
      ApiConstants.ownerDashboard,
      queryParams: queryParams,
    );
    return response['data'] as Map<String, dynamic>? ?? {};
  }

  /// Get list of farmers from backend
  Future<List<Map<String, dynamic>>> getFarmersList({String? search, String? status, String? date}) async {
    final queryParams = <String, dynamic>{};
    if (search != null && search.isNotEmpty) queryParams['search'] = search;
    if (status != null && status.isNotEmpty) queryParams['status'] = status;
    if (date != null && date.isNotEmpty) queryParams['date'] = date;

    final response = await _client.get(
      ApiConstants.farmers,
      queryParams: queryParams,
    );
    final data = response['data'] as List<dynamic>?;
    if (data == null) return [];
    return data.map((e) => e as Map<String, dynamic>).toList();
  }

  /// Get raw task assignments for owner planning
  Future<List<Map<String, dynamic>>> getRawAssignments({
    String? date,
    String? startDate,
    String? endDate,
    String? filter,
    int? locationId,
    int? farmerId,
    String? status,
  }) async {
    final queryParams = <String, dynamic>{};
    if (date != null && date.isNotEmpty) queryParams['date'] = date;
    if (startDate != null && startDate.isNotEmpty) queryParams['start_date'] = startDate;
    if (endDate != null && endDate.isNotEmpty) queryParams['end_date'] = endDate;
    if (filter != null && filter.isNotEmpty) queryParams['filter'] = filter;
    if (locationId != null && locationId > 0) queryParams['location_id'] = locationId;
    if (farmerId != null && farmerId > 0) queryParams['farmer_id'] = farmerId;
    if (status != null && status.isNotEmpty) queryParams['status'] = status;
    queryParams['per_page'] = 100;
    var page = 1;
    final all = <Map<String, dynamic>>[];
    while (true) {
      queryParams['page'] = page;
      final response = await _client.get(ApiConstants.assignments, queryParams: queryParams);
      final items = response['data'] as List<dynamic>? ?? [];
      all.addAll(items.map((e) => e as Map<String, dynamic>));
      final meta = response['meta'] as Map<String, dynamic>?;
      final lastPage = int.tryParse(meta?['last_page']?.toString() ?? '1') ?? 1;
      if (page >= lastPage || items.isEmpty) break;
      page++;
    }
    return all;
  }

  /// Get notifications for authenticated user
  Future<List<AppNotificationModel>> getNotifications() async {
    final response = await _client.get(ApiConstants.notifications);
    final data = response['data'] as List<dynamic>?;
    if (data == null) return [];
    return data
        .map((item) => AppNotificationModel.fromJson(item as Map<String, dynamic>))
        .toList();
  }

  /// Mark notification as read
  Future<bool> markNotificationAsRead(String id) async {
    final response = await _client.post(ApiConstants.markNotificationRead(id));
    return response['success'] == true;
  }

  /// Mark all notifications as read
  Future<bool> markAllNotificationsAsRead() async {
    final response = await _client.post(ApiConstants.markAllNotificationsRead);
    return response['success'] == true;
  }

  /// Get list of active farm locations created from the admin panel
  Future<List<OwnerLocationItem>> getFarmLocations() async {
    final response = await _client.get(ApiConstants.locations);
    final data = response['data'] as List<dynamic>?;
    if (data == null) return [];
    return data
        .map((item) => OwnerLocationItem.fromJson(item as Map<String, dynamic>))
        .toList();
  }
}
