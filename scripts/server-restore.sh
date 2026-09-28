#!/usr/bin/env bash
# Restores into the NEW volume selected in deploy/.env; never erases the old volume.
set -euo pipefail
umask 077
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
[[ $# == 1 && -f "$1" ]] || { echo "Usage: $0 /safe/path/backup.tar.gz" >&2; exit 2; }
archive=$(python3 -c 'import os,sys; print(os.path.abspath(sys.argv[1]))' "$1")
cd "$root"
compose=(docker compose --env-file deploy/.env -f deploy/compose.yaml)
# Backups are sensitive and must be trusted. Refuse path traversal, links, and devices.
python3 - "$archive" <<'PY'
import pathlib, sys, tarfile
with tarfile.open(sys.argv[1], 'r:gz') as archive:
    has_database = False
    for entry in archive:
        path = pathlib.PurePosixPath(entry.name)
        if path.is_absolute() or '..' in path.parts or not (entry.isfile() or entry.isdir()):
            raise SystemExit('Unsafe archive member: ' + entry.name)
        has_database |= str(path) == 'yun.sqlite3' and entry.isfile()
    if not has_database:
        raise SystemExit('Not a Yun snapshot: yun.sqlite3 missing')
PY
volume=$("${compose[@]}" config --format json | python3 -c 'import json,sys; print(json.load(sys.stdin)["volumes"]["yun_data"]["name"])')
if docker volume inspect "$volume" >/dev/null 2>&1; then
  echo "Refusing existing volume $volume. Set YUN_DATA_VOLUME in deploy/.env to a NEW name." >&2
  exit 1
fi
"${compose[@]}" stop server
# On error do NOT restart into partial data. The old volume remains untouched.
restore_failed() {
  "${compose[@]}" stop server || true
  echo "Restore failed: server stopped. Keep the old volume; see docs/OPERATIONS.md." >&2
}
trap restore_failed ERR
trap 'restore_failed; exit 130' INT
trap 'restore_failed; exit 143' TERM
docker volume create "$volume" >/dev/null
gzip -dc "$archive" | docker run --rm -i --network none --user 0:0 \
  --entrypoint /bin/sh -v "$volume:/restore" yun-server:local \
  -ec 'tar --no-same-owner -xpf - -C /restore; chown -R 10001:10001 /restore; chmod 700 /restore; sync -f /restore'
"${compose[@]}" up -d --wait server caddy
printf 'Restored to %s; old data volume has not been deleted.\n' "$volume"
