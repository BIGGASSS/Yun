# Authenticated playback transport

## Decision: Dart-owned streaming

All HTTP/HTTPS playback now goes through `PlaybackRelay`. Dart's `HttpClient`
validates the upstream certificate chain and DNS/IP identity using its default
trust roots. The native player receives only a random, session-scoped loopback
URL: **never the remote URL or account authorization headers**. Local files still
open directly. Native `tls-verify=yes` remains enabled as defense in depth, but
native TLS is no longer the security boundary for authenticated streaming.

This resolves review Finding 1 without maintaining a private mpv/FFmpeg fork or
adding a CA bundle to a backend with incomplete identity verification.

## Why not upgrade the native libraries?

The published packages already match the lockfile: `media_kit` 1.2.6,
`media_kit_libs_audio` 1.0.7, Android audio 1.3.8 and macOS audio 1.1.4. We also
inspected the newer official native Android audio v1.1.9 and Darwin v0.7.3 builds.
Neither fixes both TLS defects:

- Android v1.1.9 still uses FFmpeg 6.0 with mbedTLS 3.6.1.
- Darwin v0.7.3 still uses FFmpeg 6.0 with mbedTLS 3.4.1.
- FFmpeg's mbedTLS transport loads roots only from `ca_file` and skips its
  hostname-setting call for numeric hosts. Adding roots alone leaves IP identity
  verification incomplete. Their shipped patches do not repair that path.

Primary sources:

- [Android dependency pins](https://github.com/media-kit/libmpv-android-audio-build/blob/v1.1.9/buildscripts/include/depinfo.sh),
  [build flags](https://github.com/media-kit/libmpv-android-audio-build/blob/v1.1.9/buildscripts/scripts/ffmpeg.sh),
  [patches](https://github.com/media-kit/libmpv-android-audio-build/tree/v1.1.9/buildscripts/patches/ffmpeg).
- [Darwin dependency pins](https://github.com/media-kit/libmpv-darwin-build/blob/v0.7.3/packages.lock.nix),
  [patch application](https://github.com/media-kit/libmpv-darwin-build/blob/v0.7.3/nix/packages/mk-pkg-ffmpeg/default.nix).
- [FFmpeg 6.0 mbedTLS transport](https://github.com/FFmpeg/FFmpeg/blob/n6.0/libavformat/tls_mbedtls.c).

## Relay contract and resource limits

`lib/services/playback_relay.dart` implements a fixed-source, non-caching relay:

- It binds only IPv4 loopback on an ephemeral port. Each source gets a random
  256-bit capability path. Exact Host/path validation and rejection of browser
  Origin/Referer/Fetch-Metadata headers prevent a general-purpose local proxy.
  It accepts only bodyless GET and HEAD requests.
- Upstream credentials belong to that fixed source. Only Range and If-Range
  from the player are forwarded, so seeking remains supported. Reconnects use
  the same verifying Dart transport. **All redirects, even same-origin, fail**;
  configure Yun with the final server origin rather than an audio redirector.
- Response headers are allowlisted; cookies, redirect locations and upstream
  error bodies are not exposed. Network/TLS failures yield a sanitized 502
  before headers, or terminate an already-started response and report a
  sanitized playback error. Unexpected programming errors propagate.
- Four upstream exchanges and sixteen accepted player-side sockets are allowed
  per source, including idle or incomplete-header connections. Each operation
  has a 15-second deadline (connect, headers, idle read, downstream write/drain).
  The deadline does not limit the total duration of a playing track.
- Streaming is backpressured, without whole-track buffering or disk spooling.
  Source replacement, stop, disposal and downstream disconnect cancel their
  transports. Established pause keeps the source available for resume/seek.
  Cancellation during open cleans up the pending source.
- Closing or timing out a stalled TLS handshake must release its socket. Dart
  3.13's `HttpClient.close(force: true)` alone does not do so. An internal,
  bounded loopback CONNECT bridge retains an independently cancellable TCP
  endpoint while `HttpClient` performs TLS with the original hostname and
  SecurityContext. The bridge only forwards encrypted TLS records; it does not
  inspect certificates or decrypt data. Only connection factories registered
  to an admitted exchange can use it, and its destination is fixed.
- Normal EOF drains buffered data before closing; it is not treated as forced
  cancellation. DNS/connect subscriptions are canceled, though a resolver call
  already executing inside the operating system cannot itself be interrupted.

No certificate preflight, permissive `badCertificateCallback`, or verification
fallback is used. Test-only clients inject an explicit private CA SecurityContext.
A loopback capability does not protect against malware running as the same user
and inspecting process memory; no account token is exposed through the local
HTTP interface.

## Platform configuration

macOS Release now grants `com.apple.security.network.server`, matching Debug/
Profile, so sandboxed apps can bind the loopback relay. The listener code still
restricts binding to loopback. Android already permits loopback HTTP in its
network-security configuration; no general cleartext exception was added.

## Verification and remaining acceptance checks

`test/services/playback_relay_test.dart` exercises real Dart TLS, DNS/IPv4/IPv6
identity checks, invalid/untrusted peers receiving no HTTP, range/HEAD and
credential isolation, denied redirects, capability/Host/browser checks,
admission limits, slow consumers/backpressure, upstream EOF framing, handshake
and connect cancellation, and fail-fast diagnostic boundaries. TLS fixtures are
generated with OpenSSL and never use a permissive certificate callback.

`test/services/playback_engine_test.dart` verifies that only credential-free
loopback sources reach mpv and checks source replacement, focus/open races,
stop/disposal, scoped errors and unchanged local-file behavior.

`test/services/native_playback_test.dart` runs the production engine and relay
against real Linux libmpv with null audio output, validating certificate failures
before HTTP, trusted DNS/IP playback and authenticated seeking. Run it with:

```sh
RUN_NATIVE_PLAYBACK=1 flutter test test/services/native_playback_test.dart
```

Local validation with Flutter 3.47.5 passed all **728 Flutter tests** and all
**10 real Linux libmpv tests**, including the public-root fixture
`https://www.w3schools.com/html/horse.ogg` without an injected CA. Formatting and
full analysis passed. These are Linux runtime results, not device certification.

An optional `NATIVE_TRUSTED_AUDIO_URL` enables a public-root smoke test without
injecting a CA. It must be a non-authenticated HTTPS audio fixture lasting over
100 ms. A skipped public-root test is not evidence of platform trust-store
integration. Cross-platform package builds are CI checks, not real-device audio
certification: retain the signed/sandboxed macOS and Android runtime acceptance
checks in [VALIDATION.md](VALIDATION.md), including background playback,
seeking/reconnecting and invalid certificates. No native-library TLS correctness
claim is required for the authenticated relay path.
