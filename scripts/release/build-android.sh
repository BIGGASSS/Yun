#!/usr/bin/env bash
# Run from the repository root. Credentials exist only in this process tree and
# an owner-only temporary directory, never in Gradle properties or artifacts.
set +x
set -euo pipefail
mode=${1:-}
case "$mode" in
  debug-signed)
    unset YUN_ANDROID_RELEASE_SIGNING YUN_ANDROID_KEYSTORE_PATH
    unset ANDROID_KEYSTORE_BASE64 ANDROID_KEYSTORE_PASSWORD ANDROID_KEY_ALIAS ANDROID_KEY_PASSWORD
    fvm flutter build apk --debug --target-platform android-arm64
    mkdir -p dist
    cp build/app/outputs/flutter-apk/app-debug.apk dist/yun-android-arm64-debug-signed.apk
    exit 0
    ;;
  release-signed) ;;
  *) echo 'Usage: build-android.sh {debug-signed|release-signed}' >&2; exit 1 ;;
esac

for name in ANDROID_KEYSTORE_BASE64 ANDROID_KEYSTORE_PASSWORD ANDROID_KEY_ALIAS ANDROID_KEY_PASSWORD; do
  if [[ -z "${!name:-}" ]]; then
    echo "Release signing requires $name (no debug fallback)" >&2
    exit 1
  fi
  if [[ "${GITHUB_ACTIONS:-}" == true ]]; then
    # Escape workflow command data, including multi-line base64 values.
    value=${!name}
    value=${value//'%'/'%25'}
    value=${value//$'\r'/'%0D'}
    value=${value//$'\n'/'%0A'}
    printf '::add-mask::%s\n' "$value"
    unset value
  fi
done
umask 077
signing_dir=$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/yun-android-signing.XXXXXX")
trap 'rm -rf -- "$signing_dir"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
export YUN_ANDROID_KEYSTORE_PATH="$signing_dir/release.keystore"
export YUN_ANDROID_RELEASE_SIGNING=true
python3 - <<'PY'
import base64
import os
import sys
from pathlib import Path
try:
    encoded = ''.join(os.environ['ANDROID_KEYSTORE_BASE64'].split())
    decoded = base64.b64decode(encoded, validate=True)
    if not decoded:
        raise ValueError('empty keystore')
    Path(os.environ['YUN_ANDROID_KEYSTORE_PATH']).write_bytes(decoded)
except (ValueError, OSError):
    sys.exit('Invalid base64 keystore or unable to write temporary keystore')
PY
unset ANDROID_KEYSTORE_BASE64
fvm flutter build apk --release --target-platform android-arm64
unset ANDROID_KEYSTORE_PASSWORD ANDROID_KEY_ALIAS ANDROID_KEY_PASSWORD
unset YUN_ANDROID_RELEASE_SIGNING YUN_ANDROID_KEYSTORE_PATH
# Build-tools are installed by Flutter/Android setup. Select the newest installed
# version, not an arbitrary filesystem glob result.
sdk=${ANDROID_SDK_ROOT:-${ANDROID_HOME:-}}
[[ -n "$sdk" && -d "$sdk/build-tools" ]] || { echo 'Android build-tools missing' >&2; exit 1; }
apksigner=$(find "$sdk/build-tools" -mindepth 2 -maxdepth 2 -type f -name apksigner | sort -V | tail -n 1)
[[ -n "$apksigner" ]] || { echo 'apksigner missing' >&2; exit 1; }
"$apksigner" verify --verbose --print-certs build/app/outputs/flutter-apk/app-release.apk
mkdir -p dist
cp build/app/outputs/flutter-apk/app-release.apk dist/yun-android-arm64-release-signed.apk
