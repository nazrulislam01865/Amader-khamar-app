import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import '../core/constants/api_constants.dart';
import '../core/network/api_client.dart';
import '../core/storage/local_storage_service.dart';
import '../models/submission_model.dart';
import 'api_service.dart';
import 'durable_queue_store.dart';
import 'image_compression_service.dart';

class OfflineSyncService {
  final ApiService _apiService;
  final LocalStorageService _storage;
  final DurableQueueStore _queue;
  bool _isOnline = true;
  Future<int>? _syncInFlight;
  Timer? _retryTimer;
  final StreamController<int> _pendingCountController = StreamController<int>.broadcast();
  Stream<int> get pendingCountStream => _pendingCountController.stream;

  OfflineSyncService({ApiService? apiService, LocalStorageService? storage, DurableQueueStore? queue})
      : _apiService = apiService ?? ApiService(),
        _storage = storage ?? LocalStorageService.instance,
        _queue = queue ?? DurableQueueStore.instance;

  bool get isOnline => _isOnline;
  int get pendingCount => _queue.pendingCount;
  int get needsAttentionCount => _queue.needsAttentionCount;
  List<OfflineSubmissionItem> getPendingSubmissions() =>
      _queue.items.where((e) => e.syncStatus != SubmissionSyncStatus.synced).toList();

  int? get _currentUserId {
    final json = _storage.getJson(ApiConstants.userKey);
    if (json is! Map) return null;
    return int.tryParse(json['id']?.toString() ?? '');
  }

  void setOnlineStatus(bool online, {bool autoSync = true}) {
    _isOnline = online;
    if (!online) _retryTimer?.cancel();
    if (online && autoSync) unawaited(syncPendingSubmissions());
  }

  /// Unsafe destructive API intentionally disabled: retained evidence must
  /// only be deleted following an approved server-receipt retention policy.
  Future<void> clearQueue() async =>
      throw StateError('Cannot clear unsynced evidence or submission receipts.');

  Future<OfflineSubmissionItem> queueSubmission({
    required int assignmentId,
    required double latitude,
    required double longitude,
    double? accuracy,
    String? notes,
    List<String>? photoPaths,
    List<Map<String, dynamic>>? photoMetadata,
    bool overrideGeofence = false,
    String? idempotencyKey,
  }) async {
    final owner = _currentUserId;
    if (owner == null || owner <= 0) {
      throw StateError('Authenticated user required for offline evidence.');
    }
    if (assignmentId <= 0 || photoPaths == null || photoPaths.isEmpty) {
      throw const FormatException('Assignment and evidence photos are required.');
    }
    final key = idempotencyKey ?? newSubmissionKey();
    final created = await _queue.mutate((items) async {
      for (final existing in items) {
        if (existing.ownerUserId == owner && existing.assignmentId == assignmentId &&
            existing.syncStatus != SubmissionSyncStatus.synced &&
            existing.idempotencyKey != key) {
          throw StateError('A submission for this assignment is already queued.');
        }
        if (existing.idempotencyKey == key) {
          if (existing.ownerUserId != owner || existing.assignmentId != assignmentId) {
            throw StateError('Idempotency key already belongs to another submission.');
          }
          return existing;
        }
      }
      final staged = <String>[];
      final hashes = <String>[];
      for (var i = 0; i < photoPaths.length; i++) {
        final entry = await _queue.stagePhoto(photoPaths[i], key, i);
        staged.add(entry.path);
        hashes.add(entry.hash);
      }
      final item = OfflineSubmissionItem(
        localId: key, idempotencyKey: key, ownerUserId: owner,
        assignmentId: assignmentId, latitude: latitude, longitude: longitude,
        accuracy: accuracy, notes: notes, photoPaths: staged, photoHashes: hashes,
        photoMetadata: photoMetadata ?? const [], createdAt: DateTime.now(),
        overrideGeofence: overrideGeofence,
      );
      items.add(item);
      return item;
    });
    _pendingCountController.add(pendingCount);
    return created;
  }

  Future<int> syncPendingSubmissions() {
    if (!_isOnline) return Future.value(0);
    if (_syncInFlight != null) return _syncInFlight!;
    final running = _sync();
    _syncInFlight = running;
    return running.whenComplete(() => _syncInFlight = null);
  }

  Future<int> _sync() async {
    await _queue.initialize();
    var synced = 0;
    for (final snapshot in _queue.items) {
      if (!_isOnline) break;
      if (snapshot.syncStatus == SubmissionSyncStatus.synced ||
          snapshot.syncStatus == SubmissionSyncStatus.needsAttention ||
          (snapshot.retryAt != null && snapshot.retryAt!.isAfter(DateTime.now()))) {
        continue;
      }
      final owner = _currentUserId;
      if (owner == null || owner != snapshot.ownerUserId) {
        // Never upload work under a different login (or after logout).
        continue;
      }
      if (!await _queue.verify(snapshot)) {
        await _setStatus(snapshot.localId, SubmissionSyncStatus.needsAttention,
            'Evidence missing, damaged, or changed. Original files retained.');
        continue;
      }
      await _setStatus(snapshot.localId, SubmissionSyncStatus.syncing, null);
      try {
        // A previous request may have committed before the app timed out.
        if (snapshot.attemptCount > 0 || snapshot.syncStatus == SubmissionSyncStatus.syncing) {
          final existing = await _apiService.lookupSubmissionReceipt(
            snapshot.assignmentId, snapshot.idempotencyKey,
          );
          if (_validReceipt(existing, snapshot)) {
            await _setStatus(snapshot.localId, SubmissionSyncStatus.synced, null,
                receiptId: existing!['receipt_id'].toString());
            synced++;
            continue;
          }
        }
        final photos = <Uint8List>[];
        final compression = ImageCompressionService();
        for (final path in snapshot.photoPaths) {
          final original = await File(path).readAsBytes();
          photos.add((await compression.compressImage(original, targetMaxKb: 800)).compressedBytes);
        }
        final result = await _apiService.submitAssignment(
          assignmentId: snapshot.assignmentId,
          latitude: snapshot.latitude,
          longitude: snapshot.longitude,
          accuracy: snapshot.accuracy,
          notes: snapshot.notes,
          photoBytesList: photos,
          photoMetadata: snapshot.photoMetadata,
          // Old farmer queues may contain override=true from the previous UI.
          // Submit them normally; the server alone validates and flags location.
          // Keep the durable record and idempotency key unchanged.
          overrideGeofence: false,
          idempotencyKey: snapshot.idempotencyKey,
        );
        if (result.success && result.receiptId != null &&
            result.receiptKey == snapshot.idempotencyKey &&
            result.receiptAssignmentId == snapshot.assignmentId &&
            result.submissionId != null) {
          await _setStatus(snapshot.localId, SubmissionSyncStatus.synced, null, receiptId: result.receiptId);
          synced++;
        } else {
          await _setStatus(snapshot.localId, SubmissionSyncStatus.needsAttention,
              'Server response did not contain a matching submission receipt.');
        }
      } on ApiException catch (e) {
        if (e.statusCode == 409) {
          // A conflicting payload must never be interpreted as success.
          await _setStatus(snapshot.localId, SubmissionSyncStatus.needsAttention,
              'Idempotency conflict: review submission before retrying.');
        } else if (e.statusCode == 429 || e.statusCode >= 500) {
          await _setStatus(snapshot.localId, SubmissionSyncStatus.failed, e.message, retry: true);
        } else {
          await _setStatus(snapshot.localId, SubmissionSyncStatus.needsAttention, e.message);
        }
      } on NetworkException catch (e) {
        await _setStatus(snapshot.localId, SubmissionSyncStatus.failed, e.toString(), retry: true);
      } on SocketException catch (_) {
        await _setStatus(snapshot.localId, SubmissionSyncStatus.failed, 'Network unavailable.', retry: true);
      } on TimeoutException catch (_) {
        await _setStatus(snapshot.localId, SubmissionSyncStatus.failed, 'Request timed out.', retry: true);
      } catch (_) {
        await _setStatus(snapshot.localId, SubmissionSyncStatus.needsAttention,
            'Unexpected sync error. Evidence retained; review required.');
      }
    }
    _pendingCountController.add(pendingCount);
    _scheduleNextRetry();
    return synced;
  }

  void _scheduleNextRetry() {
    _retryTimer?.cancel();
    if (!_isOnline) return;
    final userId = _currentUserId;
    DateTime? earliest;
    for (final item in _queue.items) {
      if (item.ownerUserId != userId ||
          item.syncStatus != SubmissionSyncStatus.failed || item.retryAt == null) continue;
      if (earliest == null || item.retryAt!.isBefore(earliest)) earliest = item.retryAt;
    }
    if (earliest != null) {
      final remaining = earliest.difference(DateTime.now());
      _retryTimer = Timer(remaining.isNegative ? Duration.zero : remaining,
          () => unawaited(syncPendingSubmissions()));
    }
  }

  Future<int> retryNow() async {
    await _queue.mutate((items) async {
      for (final item in items) {
        if (item.ownerUserId == _currentUserId && item.syncStatus == SubmissionSyncStatus.failed) {
          item.retryAt = null;
        }
      }
    });
    return syncPendingSubmissions();
  }

  void dispose() {
    _retryTimer?.cancel();
    _pendingCountController.close();
  }

  bool _validReceipt(Map<String, dynamic>? receipt, OfflineSubmissionItem item) {
    return receipt != null && receipt['receipt_id'] is String &&
        (receipt['receipt_id'] as String).isNotEmpty &&
        receipt['idempotency_key'] == item.idempotencyKey &&
        int.tryParse(receipt['assignment_id']?.toString() ?? '') == item.assignmentId &&
        int.tryParse(receipt['submission_id']?.toString() ?? '') != null;
  }

  Future<void> _setStatus(String id, SubmissionSyncStatus status, String? message,
      {bool retry = false, String? receiptId}) async {
    await _queue.mutate((items) async {
      for (final item in items) {
        if (item.localId != id) continue;
        item.syncStatus = status;
        item.errorMessage = message;
        item.serverReceiptId = receiptId ?? item.serverReceiptId;
        if (status == SubmissionSyncStatus.syncing) item.attemptCount++;
        if (retry) {
          final seconds = min(1800, 5 * (1 << min(item.attemptCount, 8)));
          final jitter = Random.secure().nextInt(5);
          item.retryAt = DateTime.now().add(Duration(seconds: seconds + jitter));
        } else {
          item.retryAt = null;
        }
        break;
      }
    });
    _pendingCountController.add(pendingCount);
  }
}
