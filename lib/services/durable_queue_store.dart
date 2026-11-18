import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:path_provider/path_provider.dart';

import '../core/constants/api_constants.dart';
import '../core/storage/local_storage_service.dart';
import '../models/submission_model.dart';
import 'evidence_integrity_service.dart';

String newSubmissionKey() {
  final random = Random.secure();
  final bytes = List<int>.generate(16, (_) => random.nextInt(256));
  bytes[6] = (bytes[6] & 0x0f) | 0x40;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  final hex = bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
}

/// App-private evidence and atomic queue journal (not SharedPreferences).
/// No cleanup runs automatically: retention belongs to a later approved policy.
class DurableQueueStore {
  static final DurableQueueStore instance = DurableQueueStore();
  final Directory? directoryOverride;
  final LocalStorageService storage;
  DurableQueueStore({this.directoryOverride, LocalStorageService? storage})
      : storage = storage ?? LocalStorageService.instance;

  Directory? _root;
  List<OfflineSubmissionItem> _items = [];
  Future<void>? _opening;
  Future<void> _tail = Future.value();
  bool _ready = false;

  List<OfflineSubmissionItem> get items => List.unmodifiable(_items);
  int get pendingCount => _items.where((e) => e.syncStatus != SubmissionSyncStatus.synced).length;
  int get needsAttentionCount => _items.where((e) => e.syncStatus == SubmissionSyncStatus.needsAttention).length;

  Future<void> initialize() => _opening ??= _initialize();

  Future<void> _initialize() async {
    final base = directoryOverride ?? await getApplicationSupportDirectory();
    _root = Directory('${base.path}/submission_queue_v2');
    await _root!.create(recursive: true);
    final current = File('${_root!.path}/queue.json');
    final backup = File('${_root!.path}/queue.backup.json');
    final incomplete = File('${_root!.path}/queue.tmp');
    if (!await current.exists() && !await backup.exists() && await incomplete.exists()) {
      // A crash after flushing but before rename: recover only a valid journal.
      await _readItems(incomplete);
      await incomplete.rename(current.path);
    }
    if (await current.exists() || await backup.exists()) {
      try {
        _items = await _readItems(current);
      } catch (_) {
        if (!await backup.exists()) rethrow; // Never silently reset a corrupt journal.
        _items = await _readItems(backup);
        // The last good journal can recover the primary without erasing the bad bytes.
        if (await current.exists()) {
          await current.copy('${_root!.path}/queue.corrupt.json');
        }
        await backup.copy(current.path);
      }
    } else {
      // Migrate legacy preferences once. Keep a complete copy for rollback.
      final old = storage.getJson(ApiConstants.offlineQueueKey);
      final oldRaw = storage.getString(ApiConstants.offlineQueueKey);
      if (oldRaw != null && old == null) {
        await File('${_root!.path}/queue.legacy.corrupt.json')
            .writeAsString(oldRaw, flush: true);
        throw const FormatException('Legacy offline journal is corrupt; backup retained.');
      }
      if (old is List && old.isNotEmpty) {
        final legacy = File('${_root!.path}/queue.legacy.backup.json');
        await legacy.writeAsString(jsonEncode(old), flush: true);
        final migrated = <OfflineSubmissionItem>[];
        for (final row in old) {
          if (row is! Map) continue;
          try {
            final item = OfflineSubmissionItem.fromJson(Map<String, dynamic>.from(row));
            // v1 entries were not tied to a user and may point at temp files.
            // Preserve them, but do NOT auto-upload under an unverified account.
            item.syncStatus = SubmissionSyncStatus.needsAttention;
            item.errorMessage = 'Legacy evidence requires account and photo review.';
            final staged = <String>[];
            final hashes = <String>[];
            for (var i = 0; i < item.photoPaths.length; i++) {
              final file = File(item.photoPaths[i]);
              if (!await file.exists()) {
                staged.add(item.photoPaths[i]);
                hashes.add('MISSING');
                continue;
              }
              try {
                final copied = await _stagePhoto(file.path, newSubmissionKey(), i);
                staged.add(copied.path);
                hashes.add(copied.hash);
              } catch (_) {
                staged.add(file.path);
                hashes.add('INVALID');
              }
            }
            migrated.add(OfflineSubmissionItem(
              localId: item.localId, idempotencyKey: newSubmissionKey(),
              assignmentId: item.assignmentId, latitude: item.latitude,
              longitude: item.longitude, accuracy: item.accuracy,
              notes: item.notes, photoPaths: staged, photoHashes: hashes,
              photoMetadata: item.photoMetadata, createdAt: item.createdAt,
              overrideGeofence: item.overrideGeofence,
              syncStatus: SubmissionSyncStatus.needsAttention,
              errorMessage: item.errorMessage,
            ));
          } catch (_) {
            // Preserve the complete source in the legacy backup for manual recovery.
          }
        }
        _items = migrated;
        await _persist(_items);
        // Don't erase v1 preferences; rollback remains possible.
      } else {
        await _persist(_items);
      }
    }
    _ready = true;
  }

  Future<List<OfflineSubmissionItem>> _readItems(File file) async {
    final json = jsonDecode(await file.readAsString());
    if (json is! Map || json['schema'] != 2 || json['items'] is! List) {
      throw const FormatException('Unrecognized offline queue schema');
    }
    return (json['items'] as List)
        .map((item) => OfflineSubmissionItem.fromJson(Map<String, dynamic>.from(item as Map)))
        .toList();
  }

  Future<void> _persist(List<OfflineSubmissionItem> items) async {
    final current = File('${_root!.path}/queue.json');
    final backup = File('${_root!.path}/queue.backup.json');
    final temp = File('${_root!.path}/queue.tmp');
    final backupTemp = File('${_root!.path}/queue.backup.tmp');
    final document = jsonEncode({'schema': 2, 'items': items.map((e) => e.toJson()).toList()});
    // Publish two flushed copies of the same new snapshot, then commit primary.
    // Never confirm a queue mutation after only the primary was written.
    await temp.writeAsString(document, flush: true);
    await temp.copy(backupTemp.path);
    await _flushFile(backupTemp);
    await backupTemp.rename(backup.path);
    await temp.rename(current.path);
  }

  Future<T> mutate<T>(Future<T> Function(List<OfflineSubmissionItem> items) operation) async {
    await initialize();
    final previous = _tail;
    final release = Completer<void>();
    _tail = release.future;
    await previous;
    try {
      if (!_ready) throw StateError('Offline queue not initialized');
      final copy = _items.map((e) => OfflineSubmissionItem.fromJson(e.toJson())).toList();
      final result = await operation(copy);
      await _persist(copy);
      _items = copy;
      return result;
    } finally {
      release.complete();
    }
  }

  /// Stage original bytes into support storage; the temp capture may disappear.
  Future<({String path, String hash})> stagePhoto(String sourcePath, String key, int index) async {
    await initialize();
    return _stagePhoto(sourcePath, key, index);
  }

  Future<({String path, String hash})> _stagePhoto(String sourcePath, String key, int index) async {
    final raw = File(sourcePath);
    final photos = Directory('${_root!.path}/evidence/$key');
    await photos.create(recursive: true);
    final suffix = sourcePath.toLowerCase().endsWith('.png') ? 'png' : 'jpg';
    final target = File('${photos.path}/$index.$suffix');
    final partial = File('${target.path}.partial');
    await raw.copy(partial.path);
    try {
      await _flushFile(partial);
      await EvidenceIntegrityService.readValidPhoto(partial);
      final hash = (await sha256.bind(partial.openRead()).first).toString();
      await partial.rename(target.path);
      return (path: target.path, hash: hash);
    } finally {
      if (await partial.exists()) await partial.delete();
    }
  }

  Future<void> _flushFile(File file) async {
    final handle = await file.open(mode: FileMode.append);
    try {
      await handle.flush();
    } finally {
      await handle.close();
    }
  }

  Future<bool> verify(OfflineSubmissionItem item) async {
    if (item.photoPaths.isEmpty || item.photoHashes.length != item.photoPaths.length) return false;
    for (var i = 0; i < item.photoPaths.length; i++) {
      final file = File(item.photoPaths[i]);
      if (!await file.exists()) return false;
      if ((await sha256.bind(file.openRead()).first).toString() != item.photoHashes[i]) return false;
      try {
        await EvidenceIntegrityService.readValidPhoto(file);
      } catch (_) { return false; }
    }
    return true;
  }
}
