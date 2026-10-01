#!/usr/bin/env bash
# User-local install. Close Yun first. No sudo; keeps the immediately previous bundle.
set -euo pipefail
source_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
target="$HOME/.local/opt/yun"
applications="${XDG_DATA_HOME:-$HOME/.local/share}/applications"
[[ -x "$source_dir/yun" ]] || { echo 'Run this from the extracted complete archive' >&2; exit 1; }
[[ "$source_dir" != "$target" ]] || { echo 'Extract a new archive outside the install directory' >&2; exit 1; }
[[ ! -L "$target" && ! -L "$target.previous" ]] || { echo 'Refusing symlink install directory' >&2; exit 1; }
mkdir -p "$(dirname "$target")" "$applications"
stage=$(mktemp -d "$(dirname "$target")/.yun-install.XXXXXX")
trap 'rm -rf "$stage"' EXIT
cp -a "$source_dir/." "$stage/"
if [[ -e "$target" ]]; then
  rm -rf "$target.previous"
  mv "$target" "$target.previous"
fi
mv "$stage" "$target"
python3 - "$target" "$applications/yun.desktop" <<'PY'
import pathlib, sys
target, destination = sys.argv[1:]
# Desktop Entry Exec has its own quoting rules (not a shell command).
def quoted(value):
    if any(c in value for c in '\n\r'):
        raise SystemExit('Newlines in install paths are not supported')
    # Percent field codes are expanded even inside quotes; %% is literal %.
    value = value.replace('%', '%%')
    return '"' + value.replace('\\', '\\\\\\\\').replace('"', '\\\\"').replace('`', '\\\\`').replace('$', '\\\\$') + '"'
text = pathlib.Path(target, 'yun.desktop').read_text()
text = text.replace('Exec=yun', 'Exec=' + quoted(target + '/yun'))
text = text.replace('Icon=yun', 'Icon=' + (target + '/yun.png').replace('\\', '\\\\'))
pathlib.Path(destination).write_text(text)
PY
if command -v update-desktop-database >/dev/null; then update-desktop-database "$applications"; fi
printf 'Installed to %s\nDesktop entry: %s/yun.desktop\n' "$target" "$applications"
