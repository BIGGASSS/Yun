#!/usr/bin/env bash
# Consistent offline CLI backup, exported as a private tar.gz. Docker Compose v2 required.
set -euo pipefail
umask 077
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
[[ $# == 1 ]] || { echo "Usage: $0 /safe/path/new-backup.tar.gz" >&2; exit 2; }
archive=$(python3 -c 'import os,sys; print(os.path.abspath(sys.argv[1]))' "$1")
cd "$root"
compose=(docker compose --env-file deploy/.env -f deploy/compose.yaml)
[[ ! -e "$archive" ]] || { echo "Destination already exists" >&2; exit 1; }
[[ -d $(dirname "$archive") ]] || { echo "Create the backup parent directory first" >&2; exit 1; }
# Reserve destination atomically, refusing symlinks/existing files.
(set -o noclobber; : > "$archive")
scratch=""
restart=false
complete=false
cleanup() {
  status=$?
  trap - EXIT
  if [[ -n "$scratch" ]]; then docker volume rm "$scratch" >/dev/null || true; fi
  if [[ "$restart" == true ]]; then "${compose[@]}" start server || status=1; fi
  if [[ "$complete" != true ]]; then
    rm -f "$archive"
    echo "Backup failed; incomplete archive removed" >&2
  fi
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
if "${compose[@]}" ps --status running --services | grep -qx server; then restart=true; fi
"${compose[@]}" stop server
scratch=$(docker volume create)
docker run --rm --network none --user 0:0 --entrypoint /bin/sh \
  -v "$scratch:/backup" yun-server:local -ec 'chown 10001:10001 /backup; chmod 700 /backup'
"${compose[@]}" run --rm -T --no-deps -v "$scratch:/backup" server backup /backup/snapshot
# CLI has closed SQLite and fsynced this snapshot. Archive only the completed snapshot.
docker run --rm --network none --user 10001:10001 --entrypoint tar \
  -v "$scratch:/backup:ro" yun-server:local -C /backup/snapshot -cpf - . | gzip > "$archive"
gzip -t "$archive"
python3 - "$archive" <<'PY'
import os, sys
with open(sys.argv[1], 'rb') as archive:
    os.fsync(archive.fileno())
parent = os.open(os.path.dirname(sys.argv[1]), os.O_RDONLY)
try:
    os.fsync(parent)
finally:
    os.close(parent)
PY
complete=true
printf 'Backup complete: %s\n' "$archive"
