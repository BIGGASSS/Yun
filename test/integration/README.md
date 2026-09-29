# Real TCP integration and contract regressions

These tests start the actual Rust executable with disposable data directories,
create accounts through its CLI, and use real HTTP requests. Flutter tests use
production `ApiClient`, `TransferService`, SQLite cache, models and controllers;
only credential storage and the native audio engine are replaced. No existing
server data is accessed. Requires Python 3 and a locally built Rust executable.

```sh
cargo build --locked --manifest-path server/Cargo.toml
python3 scripts/api_smoke.py --no-build
.fvm/flutter_sdk/bin/flutter test test/integration --reporter expanded
# All Flutter unit, widget, and real-server regression tests:
.fvm/flutter_sdk/bin/flutter test --reporter expanded
```

`YUN_SERVER_BINARY` can specify an absolute executable path. Contract regressions
are enabled automatically when that executable exists (default:
`server/target/debug/yun-server`). No `RUN_CONTRACT_REGRESSIONS` flag is needed.
If the binary is absent, the contract group reports an explicit build-prerequisite
skip. Build it before running the complete integration suite; an existing binary
that cannot start or fails health checks is a failure, never a silent skip.
Tests do not need native audio libraries.

CI uses the **release** server artifact. For CI-equivalent local validation,
rebuild it and explicitly select it rather than relying on an existing debug
binary (HTTP connection timing can differ between profiles):

```sh
cargo build --release --locked --manifest-path server/Cargo.toml
YUN_SERVER_BINARY="$PWD/server/target/release/yun-server" fvm flutter test
```

## Fixed contracts and coverage

The independent review originally reproduced four failing regressions. All four
are now covered by **15 passing real-server regression cases** in
`contract_regressions_test.dart`:

1. **Nullable track/disc numbers:** untagged WAV metadata stays null through
   `Track`, SQLite cache, and title-only PATCH. Setting the valid boundaries
   (1 and 1,000,000) and clearing numbers to null both succeed. The metadata
   dialog displays null as blank, submits blank as null, and validates the same
   range as the server. Separate widget tests exercise untouched fields,
   clearing, whitespace, invalid numbers, and valid boundaries.
2. **Online logout after access expiry:** both locally known expiry and real
   server-side expiry refresh access and revoke the current refresh credential.
   Tests verify that **both original and rotated refresh tokens are rejected**;
   checking only the original token would hide a missing logout after rotation.
   Secure credential writes/deletes and login/refresh/logout are serialized.
   Unit tests cover in-flight writes, overlapping login/logout, failed rotation,
   bounded 401 retry, and best-effort offline local logout. The server consumes
   bounded logout JSON before returning an auth rejection, so an unread request
   body cannot hide the 401 behind a closed connection. Deterministic Rust
   streamed-body tests cover consumption, refresh/revocation, malformed JSON,
   and size limits. TCP failures report sanitized paths/statuses/error types,
   never credentials.
3. **Expired upload reservations/receipts:** a status 404 durably clears the old
   remote ID and offset. The worker validates the source before reserving again,
   uploads from zero, and completes. Tests exercise both partial reservations
   and expired completed receipts, including content-hash deduplication. Missing,
   resized, or modified sources fail without creating a replacement. Unit tests
   ensure 403/500 never trigger recreation and failed replacement creation can
   safely retry from the persisted reset.
4. **Lost completion/final-chunk acknowledgements:** the remote durable offset
   is queried before local source validation. If all bytes arrived, completion
   (including receipt replay) requires no original file. Real-server tests cover
   missing and changed sources, stale local offsets, and uploads both before and
   after server completion. Incomplete uploads still require an unchanged source;
   a locally complete offset does not override remote status. Invalid remote
   offsets are rejected in unit tests.

The existing **4 passing** `server_client_test.dart` tests additionally cover
real Flutter upload/download, Range/If-Range and checksums, listening events and
stats, persisted 401 token rotation, and offline restoration/signout/account
isolation. The earlier Python smoke review passed **65 real TCP requests** across
authentication, uploads, audio ranges, metadata, playlists, cursors/tombstones,
listening events, statistics, and cross-user isolation.

## Scope and limitations

Native OS playback/notification behavior and TLS deployment are not tested here.
Reservation/receipt expiry is simulated through API deletion with the same
observable 404 as server GC. Access-token expiry is accelerated in the disposable
SQLite database, not by changing server configuration or production source.
