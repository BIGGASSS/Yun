#!/usr/bin/env bash
# Host-only tests of the production native connection coordinator.
set -euo pipefail
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
classes=$(mktemp -d "${TMPDIR:-/tmp}/yun-audio-service-connection.XXXXXX")
trap 'rm -rf -- "$classes"' EXIT
if command -v javac >/dev/null 2>&1; then
  compiler=(javac --release 17)
else
  compiler=(java -m jdk.compiler/com.sun.tools.javac.Main -source 17 -target 17 -Xlint:-options)
fi
"${compiler[@]}" -Xlint:all -Werror -d "$classes" \
  "$root/src/main/java/com/ryanheise/audioservice/AudioServiceConnection.java" \
  "$root/src/test/java/com/ryanheise/audioservice/AudioServiceConnectionTest.java"
java -ea -cp "$classes" com.ryanheise.audioservice.AudioServiceConnectionTest
