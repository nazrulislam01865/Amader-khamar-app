# Phase 1 Laravel staging contract — implementation handoff (NOT VERIFIED)

## Staging prerequisites

Provide a separately configured `https://STAGING-HOST/api/v1` using `--dart-define=API_BASE_URL=...`, an authenticated farmer owning a real assignment, an owner account and assigned farm boundary/test photos. No production account data. Record request/response identifiers without logging credentials or exact personal GPS coordinates.

## Required server-side checks

1. `GET /farms`: return only authorized farms for the current authenticated user/tenant. Empty dataset returns an empty array; error returns explicit non-2xx. Never substitute demo `LOC-*` records. If a farm is reassigned/deleted, reject stale location/assignment association.
2. `POST /assignments/{id}/submit`: authenticated assigned farmer only; validate task state and required photo count. Inspect real decoded image bytes, MIME, dimensions and size; reject empty/1×1/corrupt/missing photos with 422. Do not treat filename/content-type declarations as proof.
3. Require valid latitude/longitude/accuracy, compare submission and each photo's capture-time GPS metadata with the server's freshness/accuracy policy. `photo_metadata` currently includes `latitude`, `longitude`, `accuracy`, `inside_geofence` (client estimate only), `captured_at`, `gps_at`. Verify server compatibility with `gps_at` before release.
4. Evaluate geofence against authoritative farm/plot boundary. A client-side `inside_geofence` boolean **must not** determine acceptance. `override_geofence` must be authorized according to an explicitly approved policy, with audit trail; the app currently offers an outside warning/confirmation, so align permission behavior before release.
5. Store evidence in access-controlled storage. Return explicit success/rejection; link each accepted photo to an authenticated assignment. Ensure owner can view only authorized images. Do not accept fabricated coordinates on missing GPS.
6. Rate limits and upload size limits should align with mobile defaults; publish max bytes/photo and minimum dimensions. Under slow mobile connectivity, avoid repeated expensive boundary queries by indexing owned assignments/locations.

## QA matrix

| ID | Input | Required result |
|---|---|---|
| E01 | Camera permission denied | No photo submission; app retry/settings UI |
| E02 | Missing local file / camera returns null | No invented photo or upload |
| E03 | Empty/1×1/invalid binary passed to API | 422; nothing stored |
| E04 | Valid captured evidence, matching authorized assignment | Accepted with real server identifier |
| G01 | GPS disabled or permission denied | App cannot mark evidence verified |
| G02 | Old, inaccurate, out-of-range coordinates | App prevents submission; server independently rejects invalid data |
| G03 | Outside farm; authorized vs unauthorized override | Server policy and audit explicitly verified |
| F01 | `/farms` returns empty/error | No fabricated selectable farm |
| F02 | Plot reassigned to another farmer | 403/404 as appropriate, no cross-owner data disclosure |

## Readiness gate

**OPEN:** Backend source, staging credentials/API deployment and API integration test results were unavailable. This is a contract and verification checklist, **not** an assertion that server-side rules are implemented or operational.
