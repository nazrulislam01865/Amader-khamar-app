import 'dart:io';
import 'dart:typed_data';

import 'package:bashir_agro_app_2/core/constants/api_constants.dart';
import 'package:bashir_agro_app_2/core/network/api_client.dart';
import 'package:bashir_agro_app_2/core/storage/local_storage_service.dart';
import 'package:bashir_agro_app_2/core/storage/secure_token_store.dart';
import 'package:bashir_agro_app_2/models/submission_model.dart';
import 'package:bashir_agro_app_2/services/api_service.dart';
import 'package:bashir_agro_app_2/services/durable_queue_store.dart';
import 'package:bashir_agro_app_2/services/image_compression_service.dart';
import 'package:bashir_agro_app_2/services/offline_sync_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:image/image.dart' as img;

class ReceiptApi extends ApiService {
  int uploads = 0;
  int? error;
  bool? lastOverrideGeofence;
  ReceiptApi();

  @override
  Future<ApiSubmissionResult> submitAssignment({
    required int assignmentId, required double latitude, required double longitude,
    double? accuracy, String? notes, List<Uint8List>? photoBytesList,
    List<Map<String, dynamic>>? photoMetadata, bool overrideGeofence = false,
    String? idempotencyKey,
  }) async {
    uploads++;
    lastOverrideGeofence = overrideGeofence;
    if (error != null) throw ApiException(error!, 'Server rejected test submission');
    return ApiSubmissionResult(
      success: true, message: 'ok', submissionId: 42,
      receiptId: 'receipt-42', receiptKey: idempotencyKey,
      receiptAssignmentId: assignmentId,
    );
  }

  @override
  Future<Map<String, dynamic>?> lookupSubmissionReceipt(int assignmentId, String key) async => null;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory tmp;
  late LocalStorageService prefs;
  late DurableQueueStore store;
  late File cameraFile;

  setUp(() async {
    LocalStorageService.instance.setSecureStoreForTest(MemorySecureTokenStore());
    SharedPreferences.setMockInitialValues({});
    prefs = LocalStorageService.instance;
    await prefs.init();
    await prefs.remove(ApiConstants.offlineQueueKey);
    await prefs.setJson(ApiConstants.userKey, {'id': 71});
    tmp = await Directory.systemTemp.createTemp('phase2-queue-test-');
    store = DurableQueueStore(directoryOverride: tmp, storage: prefs);
    await store.initialize();
    cameraFile = File('${tmp.path}/capture.jpg');
    await cameraFile.writeAsBytes(img.encodeJpg(img.Image(width: 160, height: 160)));
  });

  tearDown(() async { await tmp.delete(recursive: true); });

  test('copies evidence to durable location and survives process recreation', () async {
    final api = ReceiptApi();
    final sync = OfflineSyncService(apiService: api, storage: prefs, queue: store);
    final queued = await sync.queueSubmission(
      assignmentId: 12, latitude: 23.5, longitude: 90.3,
      photoPaths: [cameraFile.path],
    );
    expect(queued.idempotencyKey, isNotEmpty);
    expect(queued.photoHashes, hasLength(1));
    await cameraFile.delete();
    final reopened = DurableQueueStore(directoryOverride: tmp, storage: prefs);
    await reopened.initialize();
    expect(reopened.pendingCount, 1);
    expect(await reopened.verify(reopened.items.first), isTrue);
    final restartedSync = OfflineSyncService(apiService: api, storage: prefs, queue: reopened);
    expect(await restartedSync.syncPendingSubmissions(), 1);
    expect(reopened.pendingCount, 0);
    expect(reopened.items.first.serverReceiptId, 'receipt-42');
    expect(await File(reopened.items.first.photoPaths.first).exists(), true);
  });

  test('legacy outside-boundary queue replays without privileged geofence override', () async {
    final api = ReceiptApi();
    final sync = OfflineSyncService(apiService: api, storage: prefs, queue: store);
    final item = await sync.queueSubmission(
      assignmentId: 52, latitude: 23.5, longitude: 90.3,
      photoPaths: [cameraFile.path], overrideGeofence: true,
    );
    expect(item.overrideGeofence, isTrue); // Preserve the original evidence record.
    expect(await sync.syncPendingSubmissions(), 1);
    expect(api.lastOverrideGeofence, isFalse);
    expect(store.items.single.overrideGeofence, isTrue);
    expect(store.items.single.syncStatus, SubmissionSyncStatus.synced);
  });

  test('400 and 409 never cause false sync or delete photographs', () async {
    final api = ReceiptApi()..error = 409;
    final sync = OfflineSyncService(apiService: api, storage: prefs, queue: store);
    await sync.queueSubmission(assignmentId: 19, latitude: 23, longitude: 90,
      photoPaths: [cameraFile.path]);
    expect(await sync.syncPendingSubmissions(), 0);
    expect(store.items.single.syncStatus, SubmissionSyncStatus.needsAttention);
    expect(await File(store.items.single.photoPaths.single).exists(), true);
    expect(store.pendingCount, 1);
    expect(await sync.syncPendingSubmissions(), 0);
    expect(api.uploads, 1);
  });

  test('two concurrent triggers use a single flight', () async {
    final api = ReceiptApi();
    final sync = OfflineSyncService(apiService: api, storage: prefs, queue: store);
    await sync.queueSubmission(assignmentId: 21, latitude: 23, longitude: 90,
      photoPaths: [cameraFile.path]);
    await Future.wait([sync.syncPendingSubmissions(), sync.syncPendingSubmissions()]);
    expect(api.uploads, 1);
  });

  test('v1 queue migration preserves original and requires account review', () async {
    final legacyPath = '${tmp.path}/legacy_capture.jpg';
    await cameraFile.copy(legacyPath);
    await prefs.setJson(ApiConstants.offlineQueueKey, [{
      'local_id': 'OFFLINE_OLD_1', 'assignment_id': 20,
      'latitude': 23.5, 'longitude': 90.4,
      'photo_paths': [legacyPath],
      'created_at': DateTime.now().toIso8601String(),
      'sync_status': 'pendingSync',
    }]);
    final migrationDir = Directory('${tmp.path}/migration');
    final migrated = DurableQueueStore(directoryOverride: migrationDir, storage: prefs);
    await migrated.initialize();
    expect(migrated.pendingCount, 1);
    expect(migrated.items.single.syncStatus, SubmissionSyncStatus.needsAttention);
    expect(migrated.items.single.ownerUserId, isNull);
    expect(await migrated.verify(migrated.items.single), true);
    expect(await File('${migrationDir.path}/submission_queue_v2/queue.legacy.backup.json').exists(), true);
    expect(prefs.getJson(ApiConstants.offlineQueueKey), isNotNull);
  });

  test('backup restores a corrupted queue without deleting evidence', () async {
    final sync = OfflineSyncService(apiService: ReceiptApi(), storage: prefs, queue: store);
    await sync.queueSubmission(assignmentId: 33, latitude: 23, longitude: 90,
      photoPaths: [cameraFile.path]);
    final journal = File('${tmp.path}/submission_queue_v2/queue.json');
    await journal.writeAsString('damaged primary journal');
    final reopened = DurableQueueStore(directoryOverride: tmp, storage: prefs);
    await reopened.initialize();
    expect(reopened.pendingCount, 1);
    expect(await reopened.verify(reopened.items.single), true);
    expect(await File('${tmp.path}/submission_queue_v2/queue.corrupt.json').exists(), true);
  });

  test('retryable server errors remain durable with backoff', () async {
    final api = ReceiptApi()..error = 503;
    final sync = OfflineSyncService(apiService: api, storage: prefs, queue: store);
    await sync.queueSubmission(assignmentId: 35, latitude: 23, longitude: 90,
      photoPaths: [cameraFile.path]);
    expect(await sync.syncPendingSubmissions(), 0);
    expect(store.items.single.syncStatus, SubmissionSyncStatus.failed);
    expect(store.items.single.retryAt, isNotNull);
    expect(store.pendingCount, 1);
    sync.dispose();
  });

  test('real JPEG image compression keeps a valid image', () async {
    final bytes = Uint8List.fromList(img.encodeJpg(img.Image(width: 900, height: 900), quality: 100));
    final result = await ImageCompressionService().compressImage(bytes, targetMaxKb: 20);
    expect(img.decodeImage(result.compressedBytes), isNotNull);
    expect(result.compressedSize, lessThanOrEqualTo(result.originalSize));
  });
}
