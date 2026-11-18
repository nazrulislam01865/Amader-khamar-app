# Phase 0–1 issue tracker and acceptance status

| Issue | Severity | Flutter source action | Test coverage | Current status |
|---|---|---|---|---|
| 01 Fake photo generation | P0 | Removed simulated 1×1 PNG generator from production source and replaced fallback upload paths with mandatory decodable-image checks. Test PNG now lives only in `test/fixtures/`. | `evidence_integrity_phase1_test.dart` (missing, 1×1, empty, corrupt, valid) | **Implemented in source; tests not executed** |
| 02 Camera failure | P0 | Both camera screens reject missing capture and corrupt/empty files; existing photo slot is unchanged; retry and app-settings actions presented; simulated viewfinder and virtual shutter removed. | Image unit tests; device permission/hardware/storage tests pending | **Implemented in source; device QA pending** |
| 03 GPS simulation | P0 | Release/profile cannot use app simulation; removed target/fabricated evidence coordinates; added finite/valid/accuracy/age checks; capture records hardware-fix time; task-start and photo-review reject unverified GPS. Debug simulator retained only to support existing test cases, not production. | `gps_quality_phase1_test.dart`; real device test pending | **Implemented in source; backend geofence unverified** |
| 04 Dummy farms | P0 | Removed `LOC-001`/`LOC-002` selectable farm construction; `GET /farms` is authoritative; no unscoped offline fallback; empty/retry and error state provided; selected plot revalidated after refresh. | `authorized_farms_phase1_test.dart` | **Implemented in source; backend authorization unverified** |

Other issues in the master plan (05–17) are not claimed complete. A minimal Phase 1 safeguard was needed in `offline_sync_service.dart`: it now refuses to upload fabricated photos, but the legacy queue's missing-file durability, status reconciliation and HTTP 400/404/409 semantics **still require Phase 2**. Do not ship publicly before those P0 gates pass.

## Explicit provisional parameters (not backend-approved)

- Client file gate: decodable JPEG/PNG/other supported Flutter decoder; min 64×64 px; max 10 MiB. The Laravel endpoint must publish and enforce the approved upload MIME, size, photo count and dimensions. No image compression is introduced in Phase 1 (that is issue 13).
- Client GPS gate: horizontal accuracy >0 and <=50 m, timestamp no older than 60 seconds, not more than 5 seconds in the future, geographic ranges and finite numbers. These are **engineering defaults for review**, not a final farm policy. Server must check assignment ownership, field boundary, GPS provenance and audit overrides.
- Pre-existing photos with no capture-time GPS metadata are not auto-promoted to verified evidence; users should retake the photo.

## Safety and rollback

- No database/schema migrations or backend changes were made.
- Original ZIP remains the immutable baseline. Locally: `git switch baseline/source-freeze` restores unchanged source; `git diff baseline/source-freeze..fix/phase-0-1-evidence-integrity` shows the exact patch.
- Do not roll back to the unsafe simulated-photo behavior in a production deployment. If verification fails, stop the rollout and correct forward rather than serving fake evidence.
- The UI may reject work previously accepted via placeholder data; that is an intentional fail-closed integrity correction, not a guaranteed zero-behavior-change release.
