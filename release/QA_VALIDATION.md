# QA handoff — Phase 0/1

## Current verification

- Static source audit: all production call sites of `generateSimulatedPhotoBytes()` removed; no simulated image generated in camera/review/offline upload code; no `LOC-001`/`LOC-002` creation in `NewTaskScreen`.
- Existing test inventory: 25 original `*_test.dart` files, now 28 with 3 Phase 1 test files. Two older tests that directly invoked the deleted production image generator now read a fixture inside `test/fixtures/`.
- Tests written but **NOT EXECUTED**: image codec requires Flutter test engine and camera/geolocation plugin needs device integration; Flutter/Dart SDK absent here. This report is not a PASS for build or device QA.

## Developer / QA commands (project root)

```bash
flutter doctor -v
flutter pub get
dart format --output=none --set-exit-if-changed lib test
flutter analyze
flutter test test/evidence_integrity_phase1_test.dart
flutter test test/gps_quality_phase1_test.dart
flutter test test/authorized_farms_phase1_test.dart
flutter test
flutter build apk --debug --dart-define=API_BASE_URL=https://STAGING-HOST/api/v1
```

Run the app against staging, not production. Check permission denied/permanently denied, unavailable camera, empty storage, real 64+ px image, 1×1/corrupt image, GPS disabled/weak/stale, empty/failing farm API and changing selected farms. Verify outside geofence with real authorized/unauthorized users. Monitor crashes, submission error rates and whether the owner sees only successfully accepted evidence.

## Known Phase 2 dependencies — no public release yet

- Photo file paths in existing offline queue are not durably copied to app-private persistent storage, so restart/cache cleanup remains a data-loss risk.
- Old offline HTTP 400/404/409 handling still marks some responses as `synced`. This and idempotency/retry must be addressed in Phase 2 before production.
- Backend receipt validation and farmer/owner authorization must pass staging integration; not verifiable from the supplied archive.

## Rollback / hotfix

Keep source archive and baseline Git commit. Roll back the isolated branch in development or use a higher-versionCode forward fix for deployed versions. Never reintroduce fake photo, dummy farm or fallback GPS to hide a failure.
