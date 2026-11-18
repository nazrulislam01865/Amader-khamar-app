enum SubmissionSyncStatus { pendingSync, syncing, synced, failed, needsAttention }

/// v2 queue metadata. Existing v1 records are decoded without data loss.
class OfflineSubmissionItem {
  final String localId;
  final String idempotencyKey;
  final int assignmentId;
  final int? ownerUserId;
  final double latitude;
  final double longitude;
  final double? accuracy;
  final String? notes;
  final List<String> photoPaths;
  final List<String> photoHashes;
  final List<Map<String, dynamic>> photoMetadata;
  final DateTime createdAt;
  final bool overrideGeofence;
  final int payloadVersion;
  SubmissionSyncStatus syncStatus;
  int attemptCount;
  DateTime? retryAt;
  String? errorMessage;
  String? serverReceiptId;

  OfflineSubmissionItem({
    required this.localId,
    required this.assignmentId,
    required this.latitude,
    required this.longitude,
    required this.photoPaths,
    required this.createdAt,
    String? idempotencyKey,
    this.ownerUserId,
    this.accuracy,
    this.notes,
    this.photoHashes = const [],
    this.photoMetadata = const [],
    this.overrideGeofence = false,
    this.payloadVersion = 2,
    this.syncStatus = SubmissionSyncStatus.pendingSync,
    this.attemptCount = 0,
    this.retryAt,
    this.errorMessage,
    this.serverReceiptId,
  }) : idempotencyKey = idempotencyKey ?? localId;

  factory OfflineSubmissionItem.fromJson(Map<String, dynamic> json) {
    double asDouble(Object? value) => value is num
        ? value.toDouble() : double.parse(value.toString());
    return OfflineSubmissionItem(
      localId: json['local_id']?.toString() ?? '',
      idempotencyKey: json['idempotency_key']?.toString(),
      assignmentId: int.tryParse(json['assignment_id'].toString()) ?? 0,
      ownerUserId: int.tryParse(json['owner_user_id']?.toString() ?? ''),
      latitude: asDouble(json['latitude']),
      longitude: asDouble(json['longitude']),
      accuracy: json['accuracy'] == null ? null : asDouble(json['accuracy']),
      notes: json['notes']?.toString(),
      photoPaths: (json['photo_paths'] as List<dynamic>? ?? [])
          .map((e) => e.toString()).toList(),
      photoHashes: (json['photo_hashes'] as List<dynamic>? ?? [])
          .map((e) => e.toString()).toList(),
      photoMetadata: (json['photo_metadata'] as List<dynamic>? ?? [])
          .whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList(),
      createdAt: DateTime.tryParse(json['created_at']?.toString() ?? '') ?? DateTime.now(),
      overrideGeofence: json['override_geofence'] == true,
      payloadVersion: int.tryParse(json['payload_version']?.toString() ?? '1') ?? 1,
      syncStatus: SubmissionSyncStatus.values.firstWhere(
        (e) => e.name == json['sync_status'],
        orElse: () => SubmissionSyncStatus.needsAttention,
      ),
      attemptCount: int.tryParse(json['attempt_count']?.toString() ?? '0') ?? 0,
      retryAt: DateTime.tryParse(json['retry_at']?.toString() ?? ''),
      errorMessage: json['error_message']?.toString(),
      serverReceiptId: json['server_receipt_id']?.toString(),
    );
  }

  Map<String, dynamic> toJson() => {
    'local_id': localId,
    'idempotency_key': idempotencyKey,
    'assignment_id': assignmentId,
    'owner_user_id': ownerUserId,
    'latitude': latitude,
    'longitude': longitude,
    'accuracy': accuracy,
    'notes': notes,
    'photo_paths': photoPaths,
    'photo_hashes': photoHashes,
    'photo_metadata': photoMetadata,
    'created_at': createdAt.toIso8601String(),
    'override_geofence': overrideGeofence,
    'payload_version': payloadVersion,
    'sync_status': syncStatus.name,
    'attempt_count': attemptCount,
    'retry_at': retryAt?.toIso8601String(),
    'error_message': errorMessage,
    'server_receipt_id': serverReceiptId,
  };
}

class ApiSubmissionResult {
  final bool success;
  final String message;
  final int? submissionId;
  final String? receiptId;
  final String? receiptKey;
  final int? receiptAssignmentId;
  final bool geofencePassed;
  final double? distanceMeters;
  final double? radiusMeters;
  final bool isPolygonBoundary;
  final String? status;
  final String? verificationStatus;

  const ApiSubmissionResult({
    required this.success,
    required this.message,
    this.submissionId,
    this.receiptId,
    this.receiptKey,
    this.receiptAssignmentId,
    this.geofencePassed = true,
    this.distanceMeters,
    this.radiusMeters,
    this.isPolygonBoundary = false,
    this.status,
    this.verificationStatus,
  });

  bool get isGeofenceRejected => !success && (!geofencePassed || distanceMeters != null);
  bool get isGeofenceFlagged => success && !geofencePassed;

  factory ApiSubmissionResult.fromJson(Map<String, dynamic> json) {
    final data = json['data'] as Map<String, dynamic>?;
    final receipt = json['receipt'] as Map<String, dynamic>?;
    final geofence = (json['geofence'] ?? data?['geofence']) as Map<String, dynamic>?;

    final dist = geofence?['distance_meters'] != null
        ? (geofence!['distance_meters'] as num).toDouble()
        : (data?['distance_meters'] != null ? (data!['distance_meters'] as num).toDouble() : null);

    final radius = geofence?['radius_meters'] != null
        ? (geofence!['radius_meters'] as num).toDouble()
        : null;

    final isPolygon = geofence?['polygon_boundary'] == true ||
        geofence?['polygon_validated'] == true;

    return ApiSubmissionResult(
      success: json['success'] == true,
      message: json['message']?.toString() ?? '',
      submissionId: data?['id'] is int ? data!['id'] : null,
      receiptId: receipt?['receipt_id']?.toString(),
      receiptKey: receipt?['idempotency_key']?.toString(),
      receiptAssignmentId: int.tryParse(receipt?['assignment_id']?.toString() ?? ''),
      geofencePassed: geofence != null ? (geofence['passed'] == true) : (json['success'] == true),
      distanceMeters: dist,
      radiusMeters: radius,
      isPolygonBoundary: isPolygon,
      status: data?['status']?.toString() ?? (json['success'] == true ? 'submitted' : 'failed'),
      verificationStatus: data?['verification_status']?.toString() ?? (json['success'] == true ? 'pending' : 'rejected'),
    );
  }

  factory ApiSubmissionResult.fromError(String message, [dynamic errors]) {
    double? dist;
    double? radius;
    bool isPolygon = false;

    if (errors is Map) {
      final geofence = errors['geofence'] as Map<String, dynamic>?;
      if (geofence != null) {
        dist = (geofence['distance_meters'] as num?)?.toDouble();
        radius = (geofence['radius_meters'] as num?)?.toDouble();
        isPolygon = geofence['polygon_boundary'] == true;
      }
    }

    return ApiSubmissionResult(
      success: false,
      message: message,
      geofencePassed: false,
      distanceMeters: dist,
      radiusMeters: radius,
      isPolygonBoundary: isPolygon,
      status: 'rejected',
      verificationStatus: 'failed',
    );
  }
}
