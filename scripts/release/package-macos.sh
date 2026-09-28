#!/usr/bin/env bash
set -euo pipefail
apps=(build/macos/Build/Products/Release/*.app)
[[ ${#apps[@]} == 1 && -d "${apps[0]}" ]] || { echo 'Expected exactly one built macOS app' >&2; exit 1; }
app=${apps[0]}
executable=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$app/Contents/Info.plist")
lipo -verify_arch arm64 "$app/Contents/MacOS/$executable"
stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT
ditto "$app" "$stage/Yun.app"
ln -s /Applications "$stage/Applications"
cp docs/RELEASE.md docs/VALIDATION.md "$stage/"
cp scripts/release/NOTICES.txt "$stage/NOTICES.txt"
cp dist/flutter-dependencies.txt dist/pubspec.lock dist/BUILD.txt "$stage/"
mkdir -p dist
# Deliberately no Developer ID signing or notarization. Flutter may apply ad-hoc signatures.
hdiutil create -volname 'Yun (unsigned candidate)' -srcfolder "$stage" \
  -ov -format UDZO dist/yun-macos-arm64-unsigned.dmg
