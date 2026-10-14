#!/usr/bin/env bash
# Requires a Flutter Linux engine artifact; never connects to a bus or wallet.
set -euo pipefail
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
root=$(cd "$here/../../../.." && pwd)
sdk=${FLUTTER_ROOT:-$root/.fvm/flutter_sdk}
engine="$sdk/bin/cache/artifacts/engine/linux-x64"
[[ -f "$engine/libflutter_linux_gtk.so" ]] || {
  echo 'Set FLUTTER_ROOT to a Flutter SDK with Linux x64 engine artifacts' >&2
  exit 1
}
build=$(mktemp -d)
trap 'rm -rf -- "$build"' EXIT
flags_text=$(pkg-config --cflags --libs gtk+-3.0 libsecret-1)
read -r -a flags <<< "$flags_text"
"${CXX:-c++}" -std=c++14 -Wall -Wextra -Wno-unused-parameter \
  -Wno-missing-field-initializers -DAPPLICATION_ID='"app.yun.yun"' \
  -I"$engine" "$here/method_response_test.cc" -o "$build/method_response_test" \
  -L"$engine" -Wl,-rpath,"$engine" -lflutter_linux_gtk "${flags[@]}"
# GLib's test harness makes unexpected criticals fatal, detecting bad FlValue
# accessor types as well as missing/wrong responses.
"$build/method_response_test"
