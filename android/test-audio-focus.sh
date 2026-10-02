#!/usr/bin/env bash
# Deterministic JVM contract tests. No Android SDK, emulator or Maven needed.
set -euo pipefail
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
classes=$(mktemp -d "${TMPDIR:-/tmp}/yun-audio-focus.XXXXXX")
trap 'rm -rf -- "$classes"' EXIT
if command -v javac >/dev/null 2>&1; then
  compiler=(javac --release 17)
else
  # Some minimal JDK images retain the compiler module without a javac launcher.
  compiler=(java -m jdk.compiler/com.sun.tools.javac.Main -source 17 -target 17 -Xlint:-options)
fi
"${compiler[@]}" -Xlint:all -Werror -d "$classes" \
  "$root/../packages/yun_android_audio_focus/android/src/main/java/app/yun/yun/AudioFocusCoordinator.java" \
  "$root/../packages/yun_android_audio_focus/android/src/main/java/app/yun/yun/NoisyAudioFocusRegistration.java" \
  "$root/../packages/yun_android_audio_focus/android/src/test/java/app/yun/yun/AudioFocusCoordinatorTest.java" \
  "$root/../packages/yun_android_audio_focus/android/src/test/java/app/yun/yun/NoisyAudioFocusRegistrationTest.java"
java -ea -cp "$classes" app.yun.yun.AudioFocusCoordinatorTest
java -ea -cp "$classes" app.yun.yun.NoisyAudioFocusRegistrationTest
