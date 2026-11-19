#!/usr/bin/env bash
# Signs a Google Play release AAB with the developer's local upload key.
set -euo pipefail
umask 077
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
KEY_PROPERTIES="$PROJECT_ROOT/android/key.properties"
GRADLE_FILE="$PROJECT_ROOT/android/app/build.gradle.kts"
API_BASE_URL="${API_BASE_URL:-https://129.212.239.216/api/v1}"
BUILD_NAME="${BUILD_NAME:-1.0.21}"
BUILD_NUMBER="${BUILD_NUMBER:-22}"
RUN_TESTS="${RUN_TESTS:-0}"

if ! command -v flutter >/dev/null 2>&1; then
  echo 'ERROR: flutter command not found in PATH.' >&2
  exit 1
fi
if [[ ! -f "$KEY_PROPERTIES" ]]; then
  echo 'ERROR: Missing android/key.properties. Run:' >&2
  echo '  bash tools/release/setup_upload_key.sh' >&2
  exit 1
fi
if ! grep -Eq '^[[:space:]]*applicationId = "com\.amaderkhamar"' "$GRADLE_FILE"; then
  echo 'ERROR: Application ID is not com.amaderkhamar.' >&2
  exit 1
fi
if ! grep -Eq '^[[:space:]]*targetSdk = 36' "$GRADLE_FILE"; then
  echo 'ERROR: Android target API is not 36. Review Play Console requirements.' >&2
  exit 1
fi
if [[ ! "$API_BASE_URL" =~ ^https://[^[:space:]]+/api/v1/?$ ]]; then
  echo 'ERROR: API_BASE_URL must be a production HTTPS URL ending in /api/v1.' >&2
  exit 1
fi
if [[ ! "$BUILD_NUMBER" =~ ^[1-9][0-9]*$ ]]; then
  echo 'ERROR: BUILD_NUMBER must be a positive integer unused on Play Console.' >&2
  exit 1
fi
if [[ ! "$BUILD_NAME" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo 'ERROR: BUILD_NAME must be in X.Y.Z form.' >&2
  exit 1
fi

cd "$PROJECT_ROOT"
echo "Building signed AAB | applicationId=com.amaderkhamar | version=$BUILD_NAME+$BUILD_NUMBER"
echo "Production API: $API_BASE_URL"
flutter pub get
if [[ "$RUN_TESTS" == 1 ]]; then
  flutter test
fi
flutter build appbundle --release \
  --dart-define="API_BASE_URL=$API_BASE_URL" \
  --build-name="$BUILD_NAME" \
  --build-number="$BUILD_NUMBER"

AAB="$PROJECT_ROOT/build/app/outputs/bundle/release/app-release.aab"
if [[ ! -s "$AAB" ]]; then
  echo "ERROR: Release AAB was not produced: $AAB" >&2
  exit 1
fi
if ! command -v jarsigner >/dev/null 2>&1; then
  echo 'ERROR: jarsigner is unavailable; signature verification is required before upload.' >&2
  exit 1
fi
# An AAB is a signed ZIP/JAR artifact. jarsigner validates its signature.
SIGNATURE_OUTPUT="$(jarsigner -verify "$AAB" 2>&1)" || {
  printf '%s\n' "$SIGNATURE_OUTPUT" >&2
  echo 'ERROR: AAB signature verification failed. Do not upload.' >&2
  exit 1
}
printf '%s\n' "$SIGNATURE_OUTPUT"
if [[ "$SIGNATURE_OUTPUT" != *'jar verified.'* ]]; then
  echo 'ERROR: The AAB is not confirmed signed. Do not upload.' >&2
  exit 1
fi

echo
echo "SIGNED APP BUNDLE: $AAB"
if command -v shasum >/dev/null 2>&1; then
  shasum -a 256 "$AAB"
elif command -v sha256sum >/dev/null 2>&1; then
  sha256sum "$AAB"
fi
if command -v keytool >/dev/null 2>&1; then
  echo 'AAB public signing certificate SHA-256 fingerprint:'
  keytool -printcert -jarfile "$AAB" | grep 'SHA256:' || true
fi
printf '\nVerify this upload certificate against Play Console > App integrity before uploading.\n'
