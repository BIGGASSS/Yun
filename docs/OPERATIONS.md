# Operating the Yun server

See [server/README.md](../server/README.md) for the actual CLI, data guarantees,
limits, and [API.md](API.md) for the protocol. These are deployment instructions,
not a claim that public HTTPS or recovery has been exercised on your host.

## Docker + Caddy HTTPS

Requirements: Linux Docker Engine and Compose v2 (`up --wait`, `config --format
json`), Bash, Python 3, gzip; a local disk with SQLite locks, hard links, and fsync;
DNS pointing your domain to this host; incoming TCP 80/443 (UDP 443 optional).
Do not use NFS, object storage, or a static web root for server data. Docker access
is effectively host-root access; restrict it to trusted operators.

From the repository root:

```sh
cp deploy/.env.example deploy/.env
# Edit YUN_DOMAIN, ACME_EMAIL, and the stable YUN_DATA_VOLUME name.
chmod 600 deploy/.env
# In this shell, a convenience function used by all examples below:
dc() { docker compose --env-file deploy/.env -f deploy/compose.yaml "$@"; }
dc config --quiet
dc build server
dc --profile tools run --rm init
# First account: prompt is hidden; passwords are at least 12 bytes.
dc run --rm --no-deps server create-user alice
dc up -d --wait server caddy
curl --fail https://music.example.com/health
```

The multi-stage image builds `server/Cargo.lock` with Rust **1.98.1**, the exact
installed/tested toolchain, on Debian bookworm. Runtime contains the server,
CA certificates, and curl (health checks), not a Rust toolchain or FFmpeg.
Both long-running services run as **10001:10001** with a read-only root filesystem,
no capabilities, and no privilege escalation. The explicit one-shot `init` helper
runs as root only to set volume-root ownership/mode; it is not a serving process.
New volumes must be initialized before Caddy starts. The server data root is 0700.

Caddy alone publishes 80/443. It listens internally on unprivileged 8080/8443.
The origin has **no published host port**, belongs only to the `internal: true`
`origin` network, and is reachable by the trusted Caddy service. Do not attach
untrusted containers to that network or publish server port 8080. `--behind-tls-proxy`
is an operator assertion, not origin TLS or forwarded-header authentication.
Caddy's separate edge network permits ACME issuance/renewal. Certificate/account
state is retained in named `caddy_data`/`caddy_config` volumes. Data is retained in
the named volume selected by `YUN_DATA_VOLUME` (default `yun_data`). Never run
`docker compose down -v` on a deployment you intend to keep.

The Caddyfile enables automatic public HTTPS/redirects, HSTS, a 12 MB body ceiling,
and header/body timeouts. It leaves Authorization, Range, If-Range, If-Match, and
Upload-Offset untouched and does not cache authenticated responses. Public DNS,
ACME issuance/renewal, redirects, certificate trust, and range uploads still need
an operator smoke test. Use a real hostname, not a URL or placeholder domain.

**Internet exposure gate:** stock Caddy here does not supply per-IP login rate
limiting or a global connection cap. The server has account/global admission
limits, but they are not equivalent. Add and test trusted edge/WAF per-IP
limits and connection limits, or restrict access with your VPN/firewall. Avoid
logging tokens or request bodies. This example is not a complete public-hosting
abuse defense. Server request timeouts also bound slow requests; tune proxy
limits against representative large audio transfers rather than disabling them.

## Administration, monitoring, upgrades

Administrative commands require the server to be stopped; the process lock
rejects simultaneous CLI access. Caddy may remain up and return 502 temporarily.

```sh
dc stop server
dc run --rm --no-deps server reset-password alice
# Or: dc run --rm --no-deps server create-user bob
dc start server
dc ps
dc logs --tail=100 server caddy
```

For automation use `--password-stdin` and `dc run --rm -T --no-deps ...` with a
secret supplied on stdin. Never put passwords/tokens in command arguments, shell
history, repository files, or logs. A password reset revokes that user's sessions.

Monitor disk space/inodes (including Docker, temporary snapshot volume, and backup
archive space), health, restarts, request errors/latency, and certificate renewal.
Account audio quotas do not include all database/history disk usage. Keep backups
and old images before upgrading. Stop, back up, rebuild, initialize any new volumes,
and `dc up -d --wait server caddy`. Migrations are forward-only: rollback requires
the matching old image **and** pre-upgrade backup, not just an older executable.
Do not run multiple origin replicas against the same data directory.

## Offline backup

```sh
mkdir -p "$HOME/yun-backups"
chmod 700 "$HOME/yun-backups"
bash scripts/server-backup.sh "$HOME/yun-backups/yun-2026-09-29.tar.gz"
sha256sum "$HOME/yun-backups/yun-2026-09-29.tar.gz"
```

The script stops the serving container, invokes the real CLI `backup` into a
previously absent snapshot directory on a temporary volume, and exports the
completed snapshot as a mode-0600 tar.gz owned by the invoking host user. It uses
UID/GID 10001 for the CLI and archive reader; a network-isolated root helper only
initializes the temporary volume. The CLI uses `VACUUM INTO` plus fsynced media
and pending-upload copies. The script removes incomplete output and restarts the
server on exit **only if it was running before**. Check `dc ps`/health afterward.
A SIGKILL/host outage cannot run cleanup traps: inspect stopped services and
orphan temporary volumes manually. Do not run concurrent backup/restore/admin
scripts. Keep enough free space for both the snapshot and compressed export.

Backups include password/token hashes, music, artwork, pending uploads, and
personal history. Encrypt off-machine copies and record checksums/retention.
Compression is not encryption. Caddy certificates, deployment `.env`, and the
exact server image/version are separate recovery assets. Never copy just the live
SQLite main file while ignoring WAL/media changes.

## Restore without deleting the old data

1. Verify/decrypt a **trusted** backup; use the server image compatible with it.
2. Record the old `YUN_DATA_VOLUME` value. Edit `deploy/.env` to a **new, unused**
   volume name, e.g. `yun_restored_20260929`. Keep that setting after recovery.
   Avoid shell-exported overrides of `.env` variables during this procedure.
3. Run:

   ```sh
   bash scripts/server-restore.sh "$HOME/yun-backups/yun-2026-09-29.tar.gz"
   dc ps
   curl --fail https://music.example.com/health
   ```

The script rejects unsafe archive paths/links and an existing target volume,
stops the old serving container, restores the whole snapshot, sets recursive
ownership to **10001:10001** and root mode 0700, then recreates/starts server and
Caddy with health waiting. It leaves the old data volume untouched. On failure
it attempts to stop the server and does not automatically start partial data.
Correct the fault and retry with another new volume; for rollback, restore the
old `.env` volume name and old image, then `dc up -d --wait server caddy`.

Log in and verify actual track audio/ranges, artwork, playlists, statistics,
pending-upload offset/resume, and account isolation before accepting recovery.
Expired sessions/uploads retain their timestamps and may be removed on startup.
Retain the old volume until recovery is accepted; remove it deliberately later.
Practice this on a separate host regularly. Neither successful archive creation
nor `/health` alone demonstrates a successful application-level restore.
