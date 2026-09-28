#!/usr/bin/env bash
set -euo pipefail
stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT
mkdir -p "$stage/yun"
cp -a build/linux/x64/release/bundle/. "$stage/yun/"
cp scripts/release/install-linux.sh "$stage/yun/install.sh"
cp scripts/release/yun.desktop "$stage/yun/yun.desktop"
cp assets/icon.png "$stage/yun/yun.png"
cp docs/RELEASE.md docs/VALIDATION.md "$stage/yun/"
cp scripts/release/NOTICES.txt "$stage/yun/NOTICES.txt"
cp dist/flutter-dependencies.txt dist/pubspec.lock dist/BUILD.txt "$stage/yun/"
chmod +x "$stage/yun/install.sh" "$stage/yun/yun"
mkdir -p dist
tar -czf dist/yun-linux-x64.tar.gz -C "$stage" yun
