# Amader Khamar — Phase 0 source-freeze baseline

Date: 2026-11-18. Scope: uploaded Flutter/Android source archive; **no Laravel source, deployed backend, QA device or Play Console access was supplied**.

## Source freeze and isolation

- Original upload: `Archive(1).zip` (left unchanged in the working environment).
- SHA-256 of source upload: `c13da37653d510a82ed256f59e7d33755192053351be37a08cfea5086130efac`.
- Original source baseline commit (sanitized local repository): `519d97ad4f47dd102390fcfca2571b358bfc907c`.
- Baseline reference: `baseline/source-freeze`.
- Phase 1 work is isolated on local branch: `fix/phase-0-1-evidence-integrity`.
- No remote Git repository was present; **remote branch protection cannot be configured here**. Configure protected `release/*` branch rules and review requirements when connected to your team's Git hosting.
- A `.gitignore` excludes build caches, local paths, `.env` files, Android signing properties and private keystores.
- 25 existing Flutter `*_test.dart` files were present in the original archive. Baseline execution snapshot: **NOT RUN** (Flutter/Dart SDK absent in this environment).
- `flutter analyze`, `flutter test`, Android emulator/device testing and signed AAB builds are **NOT RUN** here; must run on the development/CI machine. Test results must not be inferred from source inspection.

## Key / secret exposure assessment

- The original archive contains `android/key.properties` and `android/app/upload-keystore.jks`, which must be treated as private signing material. These are **not included in the export** and not tracked in the sanitized Git baseline.
- Review who has received this archive. If signing credentials were exposed, assess Play App Signing upload-key reset/rotation. Do not paste passwords, tokens, keystore contents or private backend URLs into issue trackers/logs.
- All other secrets (including API credentials in Android generated caches) require a dedicated repository/dependency scan on the owner's secure machine. This report does **not** assert successful rotation.

## Architecture and unmodified scope

- Flutter UI: Riverpod providers in `lib/state`, services in `lib/services`, screens in `lib/presentation`, HTTP API via `ApiService`/`ApiClient`.
- Laravel API paths used by Phase 1: `GET /farms`, `POST /assignments/{id}/submit` (relative to configured API base).
- Phase 1 is limited to issues 01–04 and the minimum safeguarding of their existing capture/upload call paths. Phase 2 queue durability/idempotency, Phase 3 auth/HTTPS/privacy, Phase 4 backend/map hardening, Phase 5 packaging, Phase 6 Play publishing are intentionally untouched.

## Staging access status

**BLOCKED / not provisioned:** No staging backend hostname, deploy permission, seed data, reviewer identities or Laravel backend source was provided. Do not point the test app at production by default. Provide a protected HTTPS staging endpoint and non-production farmer/owner test accounts; test assignments must have real authorized farm/field geometry and safe fixture photos. Backend acceptance cannot be marked PASS until the Laravel team tests the contract in `STAGING_BACKEND_CONTRACT.md`.
