# Phase 2 — Flutter + API validation checklist

Start with the Laravel Phase 2 backend **deployed to staging**. Use synthetic account/photo data, not real farmer evidence. Do not assume a queued report is server-approved.

| ID | Test | Expected result |
|---|---|---|
| O01 | Capture valid photo, queue in airplane mode, kill/restart app, delete camera temp file | App-private original exists, checksum verifies, pending count restored |
| O02 | Timeout after server committed, retry with same `Idempotency-Key` | One server submission, one photo set, same receipt; queue is marked synced only on matching receipt |
| O03 | API 400/403/404/409/422 | Evidence kept, needs-attention state, never counted as synced |
| O04 | Concurrent repeated sync taps | One in-flight sync; same key, no duplicate receipt/photo uploads |
| O05 | 429/5xx/network loss | Failed + bounded exponential backoff; manual sync possible after reconnection |
| O06 | Delete/modify a queued photo | Checksum/decode check blocks upload, needs-attention visible, never substituted with fake data |
| O07 | App session logs out or different user logs in | Queued evidence remains, but cannot be uploaded under the wrong account |
| O08 | Corrupt primary queue JSON | Restore from matching backup without clearing evidence; corrupted bytes retained for investigation |
| O09 | Upgrade device with v1 SharedPreferences queue | Original JSON backed up; readable files copied; legacy submissions quarantined for account review |
| O10 | Camera JPEG > target size | Real decode, resize/quality conversion; MIME stays readable and result no larger than input |
| O11 | Upload PNG / corrupted image / tiny photo | Valid PNG preserved; corrupt/tiny image rejected, not queued/synced |
| O12 | Duplicate key with different payload on staging | HTTP 409 conflict; original receipt and photo rows remain unchanged |
| O13 | Submissions from farmer not assigned to task | HTTP 403 and no created receipt |
| O14 | Valid 2xx reply missing receipt | Never labelled successful on updated app |
| O15 | Backend not yet deployed | App blocks receipt-less completion; upgrade backend first |

### Local commands

```bash
cd /path/to/flutter_project
flutter pub get
flutter analyze
flutter test test/phase2_durable_queue_test.dart
flutter test
```

New direct packages: `crypto` (SHA-256) and `image` (real decode/resize/encode). `flutter pub get` updates `pubspec.lock`; the archive lockfile reflects the Phase 1 baseline until this command is run. Do not edit `pubspec.lock` hashes manually.

### Known release boundaries

Phase 2 does **not** resolve: token storage/HTTPS/permissions (Phase 3), map licensing and private media geofence hardening (Phase 4), signing/target API (Phase 5), or Play publishing (Phase 6). Existing legacy suite tests may still assume Phase 1 demo GPS behavior and need separate reassessment; this package changes only two legacy tests directly broken by the fake-photo queue restriction.
