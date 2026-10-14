#!/usr/bin/env bash
# Yun-owned download integrity check; works on Linux, macOS and Git Bash.
set -euo pipefail
[[ $# == 2 && "$2" =~ ^[[:xdigit:]]{64}$ ]] || {
  echo 'Missing or malformed Flutter archive SHA-256' >&2
  exit 1
}
if command -v sha256sum >/dev/null 2>&1; then
  actual=$(sha256sum < "$1")
else
  actual=$(shasum -a 256 < "$1")
fi
actual=${actual%% *}
# Bash 3.2 (macOS) has no ${value,,} expansion.
expected=$(printf '%s' "$2" | tr 'A-F' 'a-f')
[[ "$actual" == "$expected" ]] || {
  echo 'Flutter archive SHA-256 mismatch; refusing extraction' >&2
  exit 1
}
