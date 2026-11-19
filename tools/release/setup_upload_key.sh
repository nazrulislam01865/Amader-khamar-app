#!/usr/bin/env bash
# One-time local setup for Amader Khamar's Google Play upload key.
# No private key or password is included in the downloadable source archive.
set -euo pipefail
set +x
umask 077

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PROPERTIES_FILE="$PROJECT_ROOT/android/key.properties"
KEYSTORE_FILE="${AMADER_KEYSTORE_PATH:-$HOME/.amaderkhamar/signing/upload-keystore.jks}"
KEY_ALIAS="upload"

if ! command -v keytool >/dev/null 2>&1; then
  echo "ERROR: Java keytool is missing. Install a JDK (17 or later)." >&2
  exit 1
fi
if [[ -f "$PROPERTIES_FILE" ]]; then
  echo "Existing android/key.properties found. Not changing a configured signing identity."
  echo "If this app was previously uploaded to Play Console, reuse its registered upload key."
  exit 0
fi
if [[ "$KEYSTORE_FILE" != /* ]]; then
  echo "ERROR: AMADER_KEYSTORE_PATH must be an absolute path." >&2
  exit 1
fi

if [[ ! -f "$KEYSTORE_FILE" ]]; then
  mkdir -p "$(dirname "$KEYSTORE_FILE")"
  chmod 700 "$(dirname "$KEYSTORE_FILE")"
  echo "Creating a NEW RSA 4096-bit upload keystore on this Mac: $KEYSTORE_FILE"
  echo "Choose a strong password at the keytool prompts. Back up this key and password privately."
  keytool -genkeypair \
    -keystore "$KEYSTORE_FILE" \
    -storetype PKCS12 \
    -alias "$KEY_ALIAS" \
    -keyalg RSA \
    -keysize 4096 \
    -validity 10000 \
    -dname "CN=Amader Khamar Upload, OU=Mobile, O=Amader Khamar, L=Dhaka, ST=Dhaka, C=BD"
  chmod 600 "$KEYSTORE_FILE"
else
  echo "Reusing existing upload keystore at $KEYSTORE_FILE"
fi

echo
read -r -s -p "Enter upload-keystore password to configure Gradle: " KEY_PASSWORD
echo
if [[ ${#KEY_PASSWORD} -lt 6 ]]; then
  echo "ERROR: Keystore password must contain at least 6 characters." >&2
  exit 1
fi
read -r -s -p "Confirm upload-keystore password: " CONFIRM_PASSWORD
echo
if [[ "$KEY_PASSWORD" != "$CONFIRM_PASSWORD" ]]; then
  echo "ERROR: Passwords do not match. android/key.properties was not created." >&2
  exit 1
fi
unset CONFIRM_PASSWORD
# Keytool reads the secret through an environment variable rather than a CLI argument.
# This also verifies the key alias and the supplied keystore password.
export AMADER_LOCAL_UPLOAD_PASSWORD="$KEY_PASSWORD"
if ! keytool -list \
  -keystore "$KEYSTORE_FILE" \
  -storetype PKCS12 \
  -alias "$KEY_ALIAS" \
  -storepass:env AMADER_LOCAL_UPLOAD_PASSWORD >/dev/null 2>&1; then
  unset AMADER_LOCAL_UPLOAD_PASSWORD KEY_PASSWORD
  echo "ERROR: Could not open upload key with that password. Config not written." >&2
  exit 1
fi

# java.util.Properties escaping for path and password values.
escape_property() {
  local v="$1"
  v="${v//\\/\\\\}"
  v="${v//=/\\=}"
  v="${v//:/\\:}"
  v="${v//#/\\#}"
  v="${v//!/\\!}"
  v="${v// /\\ }"
  printf '%s' "$v"
}
TEMP_FILE="$(mktemp "${PROPERTIES_FILE}.XXXXXX")"
trap 'rm -f "$TEMP_FILE"' EXIT
{
  printf 'storeFile=%s\n' "$(escape_property "$KEYSTORE_FILE")"
  printf 'storePassword=%s\n' "$(escape_property "$KEY_PASSWORD")"
  printf 'keyAlias=%s\n' "$KEY_ALIAS"
  printf 'keyPassword=%s\n' "$(escape_property "$KEY_PASSWORD")"
} > "$TEMP_FILE"
chmod 600 "$TEMP_FILE"
mv "$TEMP_FILE" "$PROPERTIES_FILE"
trap - EXIT
unset KEY_PASSWORD

echo
printf 'Configured ignored local Gradle signing file: %s\n' "$PROPERTIES_FILE"
echo 'Public upload certificate fingerprint (safe to share if requested by Play Console):'
keytool -list -v -keystore "$KEYSTORE_FILE" -alias "$KEY_ALIAS" \
  -storepass:env AMADER_LOCAL_UPLOAD_PASSWORD | grep -E 'Alias name:|SHA256:|Valid from:' || true
unset AMADER_LOCAL_UPLOAD_PASSWORD
printf '\nBACK UP your .jks and password privately. Never add either to Git or upload it to chat.\n'
