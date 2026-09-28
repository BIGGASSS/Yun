#!/usr/bin/env bash
# CI smoke test; does not validate public DNS/ACME or a real music device.
set -euo pipefail
image=${YUN_TEST_IMAGE:-yun-server:ci}
data=$(docker volume create)
backup=$(docker volume create)
container=""
cleanup() {
  if [[ -n "$container" ]]; then docker rm -f "$container" >/dev/null || true; fi
  docker volume rm "$data" "$backup" >/dev/null || true
}
trap cleanup EXIT
printf '%s\n' 'container-test-password-only' | docker run --rm -i --network none \
  -v "$data:/var/lib/yun" "$image" create-user smoke --password-stdin
container=$(docker run -d --network none -v "$data:/var/lib/yun" "$image")
ready=false
for _ in {1..30}; do
  if docker exec "$container" curl -fsS http://127.0.0.1:8080/health; then ready=true; break; fi
  sleep 1
done
[[ "$ready" == true ]]
[[ $(docker exec "$container" id -u) == 10001 ]]
if docker run --rm --network none -v "$data:/var/lib/yun" "$image" backup /tmp/must-fail; then
  echo 'Expected running-server lock to reject backup' >&2
  exit 1
fi
docker stop --time 90 "$container" >/dev/null
docker rm "$container" >/dev/null
container=""
docker run --rm --network none -v "$data:/source" -v "$backup:/var/lib/yun" \
  "$image" --data-dir /source backup /var/lib/yun/snapshot
container=$(docker run -d --network none -v "$backup:/var/lib/yun" \
  "$image" --data-dir /var/lib/yun/snapshot serve --insecure-loopback)
ready=false
for _ in {1..30}; do
  if docker exec "$container" curl -fsS http://127.0.0.1:8080/health; then ready=true; break; fi
  sleep 1
done
[[ "$ready" == true ]]
docker run --rm --entrypoint caddy \
  -e YUN_DOMAIN=music.example.com -e ACME_EMAIL=ci@example.com \
  -v "$PWD/deploy/Caddyfile:/etc/caddy/Caddyfile:ro" caddy:2.10.2-alpine \
  validate --config /etc/caddy/Caddyfile --adapter caddyfile
