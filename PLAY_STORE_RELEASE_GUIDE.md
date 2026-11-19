# Amader Khamar — signed Google Play release guide

Source checked: latest supplied Flutter project with Android package `com.amaderkhamar`, launch icon, and the previous task/geofence/UI patches. No app-side features or backend security have been changed for this release setup.

## Status

The project is configured for an Android **release app bundle**, but the `.aab` **has not been compiled in this environment** because Flutter and Android SDKs are not installed here. Also, no private upload keystore is bundled. Create it locally on your Mac so the private signing identity never leaves your machine.

| Item | Value |
| --- | --- |
| Android package ID | `com.amaderkhamar` |
| Launcher app label | `আমাদের খামার` |
| Target SDK | API 36 (required for new Play submissions from Aug 31, 2026) |
| Compile SDK | 37 (unchanged from source) |
| Production API | `https://129.212.239.216/api/v1` |
| Current source version | `1.0.20+21` |
| Example next Play build | `1.0.21+22` (override if versionCode 22 already uploaded) |
| Bundle output | `build/app/outputs/bundle/release/app-release.aab` |

## 0. Check the Play Console package and key FIRST

- The installed Flutter package is `com.amaderkhamar`. A Play listing already created for `com.itqanconsulting.farmtrack` **cannot accept** this bundle because the application ID is different. Create/select the `com.amaderkhamar` listing.
- **If an AAB for `com.amaderkhamar` has already been uploaded to Play**, reuse its registered **upload key** (or follow Google's upload-key reset procedure). Do not create a new key and expect it to update a previously registered release.
- For a brand-new `com.amaderkhamar` Play listing with no upload key, generate the new upload key below. Let Google Play generate/manage the separate **app signing key**.

## 1. Setup on your Mac — first time only

Unzip the release-ready project and run from its root:

```bash
flutter doctor -v
bash tools/release/setup_upload_key.sh
```

The setup command creates `~/.amaderkhamar/signing/upload-keystore.jks` (RSA 4096, PKCS12, validity 10,000 days) on **your Mac** and writes **only your local ignored** `android/key.properties`. You choose and confirm the password interactively. If `key.properties` already exists, the script leaves it unchanged. **Do not upload your `.jks`, `key.properties`, or passwords** to Git, ChatGPT, Play listing assets, or a shared project ZIP.

Back up the `.jks` file and its password in your own private password manager/secure storage. If you later reinstall your Mac, you must restore the same upload key to publish normal updates.

## 2. Build release AAB — on your Mac

```bash
bash tools/release/build_release_aab.sh
```

By default, that command uses:

```bash
flutter build appbundle --release \
  --dart-define=API_BASE_URL=https://129.212.239.216/api/v1 \
  --build-name=1.0.21 \
  --build-number=22
```

If versionCode `22` is already used for this package in Play Console, select a higher unused number, e.g.:

```bash
BUILD_NUMBER=23 BUILD_NAME=1.0.22 bash tools/release/build_release_aab.sh
```

To run tests before producing the AAB:

```bash
RUN_TESTS=1 bash tools/release/build_release_aab.sh
```

The script verifies the output with `jarsigner -verify`, prints its path and SHA-256 checksum, and shows the public signing-certificate fingerprint (if `keytool` is available). **A successful signature verification does not prove the backend works or that Play Console will accept the release.**

## 3. Test and validate before uploading

```bash
flutter test
flutter analyze
```

- Test signup/login using real HTTPS on a device, including the admin-controlled login logo, maps and satellite tiles, GPS/geofence, photo upload, and offline behavior.
- Ensure HTTPS at `https://129.212.239.216` is reachable from a real phone and uses a **trusted certificate**. This endpoint was **not reachable from the provided execution environment**, so production networking is not verified.
- Test a **Play-installed build**, not just `flutter run` or a debug APK. Play may re-sign distributed APKs with its app-signing key.
- Verify the app's target SDK in Play Console is at least **36**. Inspect warnings about native 16 KB page size support, data safety, permissions, and signing after upload.
- If the app's existing test suite has a failing assertion, resolve it before rolling out to users.

## 4. Upload to Google Play

1. In [Google Play Console](https://play.google.com/console), open the app with package ID `com.amaderkhamar`.
2. Under **Test and release**, create a release in **Internal testing** or **Closed testing** (or Production once eligible).
3. Follow Play App Signing onboarding. For a new listing, use Google-managed app signing and your local `.jks` as the **upload key**.
4. Upload `build/app/outputs/bundle/release/app-release.aab`, not `app-debug.apk`.
5. Confirm package name, version code, signer/upload certificate, minimum target SDK, and Play pre-launch reports.
6. Complete store listing, privacy policy, data safety, permissions/consent declarations, country selection, and any testing requirements. Roll out only after successful verification.

## Security and release behavior

- No debug signing is used for releases. Gradle refuses release builds if signing credentials or the keystore are missing.
- The `key.properties` and keystore are excluded from the shared ZIP and `android/.gitignore` prevents accidental commits.
- `API_BASE_URL` remains compile-time fixed in release mode and is not redirected by development defaults.
- No backend code, API logic, storage tokens, location security, map service, database, or Flutter screen logic was modified.

## Official references

- https://docs.flutter.dev/deployment/android
- https://developer.android.com/studio/publish/app-signing
- https://support.google.com/googleplay/android-developer/answer/9842756
- https://support.google.com/googleplay/android-developer/answer/11926878
