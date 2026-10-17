#!/usr/bin/env bash
set -euo pipefail
bundle="$PWD/build/linux/x64/release/bundle"
[[ -x "$bundle/yun" && -d "$bundle/lib" && -d "$bundle/data" ]] || {
  echo 'Missing complete Linux release bundle' >&2; exit 1;
}
# Flutter's build name/number remains the source of truth, not the Git tag.
version=$(python3 - <<'PY'
import pathlib, re
text = pathlib.Path('pubspec.yaml').read_text()
versions = re.findall(r'^version:\s*([^\r\n]+)', text, re.M)
if len(versions) != 1:
    raise SystemExit('Expected one top-level Flutter version')
value = versions[0].split(' #', 1)[0].strip().strip('\"\'')
if not re.fullmatch(r'\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?(?:\+\d+)?', value):
    raise SystemExit('Invalid Flutter version')
# Debian sorts ~ prereleases before the corresponding stable version.
print(value.replace('-', '~', 1))
PY
)
stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT
mkdir -p dist
# Do not let an earlier run masquerade as fresh packaging after a failure.
rm -f dist/yun-linux-x64.AppImage dist/yun-linux-x64.deb dist/yun-linux-x64.tar.gz
appdir="$stage/Yun.AppDir"
mkdir -p "$appdir"
cp -a "$bundle/." "$appdir/"
cp docs/RELEASE.md docs/VALIDATION.md scripts/release/NOTICES.txt LICENSE "$appdir/"
cp dist/flutter-dependencies.txt dist/pubspec.lock dist/BUILD.txt "$appdir/"
cp scripts/release/AppRun "$appdir/AppRun"
cp linux/packaging/app.yun.yun.desktop "$appdir/"
cp linux/runner/resources/app.yun.yun.png "$appdir/"
chmod +x "$appdir/AppRun" "$appdir/yun"

# Keep the original user-local installation route alongside the new packages.
portable="$stage/yun"
mkdir -p "$portable"
cp -a "$appdir/." "$portable/"
rm "$portable/AppRun" "$portable/app.yun.yun.desktop" "$portable/app.yun.yun.png"
cp scripts/release/install-linux.sh "$portable/install.sh"
cp scripts/release/yun.desktop "$portable/yun.desktop"
cp assets/icon.png "$portable/yun.png"
chmod +x "$portable/install.sh"
tar -czf "$stage/yun-linux-x64.tar.gz" -C "$stage" yun

# Stage a normal Debian installation without flattening the Flutter bundle.
deb="$stage/deb"
mkdir -p "$deb/usr/lib/yun" "$deb/usr/bin" "$deb/DEBIAN" \
  "$deb/usr/share/applications" "$deb/usr/share/icons/hicolor/256x256/apps"
cp -a "$appdir/." "$deb/usr/lib/yun/"
rm "$deb/usr/lib/yun/AppRun" "$deb/usr/lib/yun/app.yun.yun.desktop" "$deb/usr/lib/yun/app.yun.yun.png"
ln -s /usr/lib/yun/yun "$deb/usr/bin/yun"
cp linux/packaging/app.yun.yun.desktop "$deb/usr/share/applications/"
cp linux/runner/resources/app.yun.yun.png "$deb/usr/share/icons/hicolor/256x256/apps/"

# Let dpkg determine actual ABI requirements of every bundled ELF, not a stale
# hand-written glibc/GTK dependency list. libmpv is dlopen'd, so add it explicitly.
mkdir -p "$stage/debian"
printf 'Source: yun\n\nPackage: yun\nArchitecture: amd64\nDescription: Personal music library\n' > "$stage/debian/control"
elfs=("-e$deb/usr/lib/yun/yun")
while IFS= read -r -d '' library; do elfs+=("-e$library"); done < <(find "$deb/usr/lib/yun/lib" -type f -name '*.so*' -print0)
dependencies=$(cd "$stage" && dpkg-shlibdeps --ignore-missing-info -O \
  "-l$deb/usr/lib/yun/lib" "${elfs[@]}")
dependencies=${dependencies#shlibs:Depends=}
[[ -n "$dependencies" && "$dependencies" != *$'\n'* ]] || { echo 'Missing shared library dependencies' >&2; exit 1; }
size=$(du -sk "$deb/usr" | cut -f1)
cat > "$deb/DEBIAN/control" <<EOF
Package: yun
Version: $version
Section: sound
Priority: optional
Architecture: amd64
Maintainer: Yun contributors <noreply@yun.app>
Homepage: https://github.com/BIGGASSS/Yun
Depends: $dependencies, libmpv2
Installed-Size: $size
Description: Personal music library
 Flutter music client with offline playback and library synchronization.
EOF
dpkg-deb --root-owner-group --build "$deb" "$stage/yun-linux-x64.deb"

# Pin and verify BOTH tools: appimagetool otherwise fetches a floating runtime.
# Updates must review upstream provenance and replace these hashes together.
curl --fail --location --retry 3 --output "$stage/appimagetool.AppImage" \
  https://github.com/AppImage/appimagetool/releases/download/1.9.1/appimagetool-x86_64.AppImage
curl --fail --location --retry 3 --output "$stage/runtime-x86_64" \
  https://github.com/AppImage/type2-runtime/releases/download/20251108/runtime-x86_64
printf '%s  %s\n' \
  ed4ce84f0d9caff66f50bcca6ff6f35aae54ce8135408b3fa33abfc3cb384eb0 "$stage/appimagetool.AppImage" \
  2fca8b443c92510f1483a883f60061ad09b46b978b2631c807cd873a47ec260d "$stage/runtime-x86_64" \
  | sha256sum --check --strict
chmod +x "$stage/appimagetool.AppImage"
# No FUSE daemon or mount privileges needed on the build runner.
ARCH=x86_64 "$stage/appimagetool.AppImage" --appimage-extract-and-run \
  --no-appstream --runtime-file "$stage/runtime-x86_64" "$appdir" "$stage/yun-linux-x64.AppImage"
chmod +x "$stage/yun-linux-x64.AppImage"
cp "$stage/yun-linux-x64.AppImage" "$stage/yun-linux-x64.deb" "$stage/yun-linux-x64.tar.gz" dist/
