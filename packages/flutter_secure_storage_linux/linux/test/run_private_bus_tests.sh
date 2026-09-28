#!/usr/bin/env bash
# No Flutter SDK, host wallet, or external test framework required.
set -euo pipefail
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
build=$(mktemp -d)
trap 'rm -rf -- "$build"' EXIT
flags_text=$(pkg-config --cflags --libs libsecret-1 gio-2.0)
read -r -a flags <<< "$flags_text"
"${CXX:-c++}" -std=c++14 -Wall -Wextra -Wno-missing-field-initializers \
  "$here/private_bus_test.cc" -o "$build/private_bus_test" "${flags[@]}"
# All scenarios create a private GTestDBus (no host activation directories).
# Never run the inherited upstream wallet tests against a desktop session.
unset DBUS_SESSION_BUS_ADDRESS SECRET_BACKEND SNAP_NAME
"$build/private_bus_test" "$@"
