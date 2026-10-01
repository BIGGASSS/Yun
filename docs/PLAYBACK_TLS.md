# Playback TLS release blocker (not resolved)

`MediaKitEngine` now sets and reads back `tls-verify=yes` before opening media.
Keep that protection. **It is not a portable authenticated-HTTPS solution with
the currently pinned native libraries. Do not certify this diff for release on
the basis of the Linux native smoke test.**

## Exact pinned builds investigated

The package versions below come from `pubspec.lock`, not the dependency ranges.
The build recipes were inspected at their release tags, including their patches.

| Platform | Flutter package | Native release | Dependencies |
| --- | --- | --- | --- |
| Android | `media_kit_libs_android_audio` 1.3.8 | `libmpv-android-audio-build` v1.1.8, commit `87744be8b337c50ed54961249b7a97c5e8cc37c9` | mpv 0.35.1, FFmpeg 6.0, mbedTLS 3.6.1 |
| macOS | `media_kit_libs_macos_audio` 1.1.4 | `libmpv-darwin-build` v0.6.0, commit `4286f5557bdccc0747030e3c376ce5cd160a96a0` | mpv 0.36.0, FFmpeg 6.0, mbedTLS 3.4.1 |

Android's package `android/build.gradle` downloads the v1.1.8 JARs. macOS's
package `macos/Makefile` downloads the v0.6.0 audio-default xcframework archive
(SHA-256 `916220b7b4fe9209de41264382966ac90a2de2ac11956a4b6041cf66a8110732`).

Primary sources:

- [Android dependency pins](https://github.com/media-kit/libmpv-android-audio-build/blob/v1.1.8/buildscripts/include/depinfo.sh)
  and [FFmpeg build flags](https://github.com/media-kit/libmpv-android-audio-build/blob/v1.1.8/buildscripts/scripts/ffmpeg.sh).
- [Darwin dependency pins](https://github.com/media-kit/libmpv-darwin-build/blob/v0.6.0/downloads.lock)
  and [FFmpeg build flags](https://github.com/media-kit/libmpv-darwin-build/blob/v0.6.0/scripts/ffmpeg/meson.build).
- [FFmpeg 6.0 mbedTLS transport](https://github.com/FFmpeg/FFmpeg/blob/n6.0/libavformat/tls_mbedtls.c),
  [shared TLS connection setup](https://github.com/FFmpeg/FFmpeg/blob/n6.0/libavformat/tls.c),
  and [available TLS options](https://github.com/FFmpeg/FFmpeg/blob/n6.0/libavformat/tls.h).

Both builds enable `--enable-mbedtls`. Their FFmpeg patches do not fix this TLS
path. In `tls_open`:

1. Trusted roots are loaded **only** from `shr->ca_file`. There is no Android
   trust-store or macOS Keychain fallback. Without a CA file, enabling verification
   makes ordinary publicly trusted HTTPS playback fail.
2. `mbedtls_ssl_set_hostname` is called only when
   `!shr->listen && !shr->numerichost`. Numeric addresses bypass that call;
   `numerichost` is determined from the underlying URL host with `AI_NUMERICHOST`.
   The `verifyhost` option changes `shr->host`, not this condition.
3. With these mbedTLS versions, no hostname means no peer-name check. A valid
   chain alone does not prove the requested IP owns the certificate. Supplying
   public roots without fixing this can turn an availability failure into bearer
   disclosure to a server with an unrelated trusted certificate.

This missing-name behavior is covered by the upstream
[CVE-2025-27809 explanation](https://mbed-tls.readthedocs.io/en/latest/kb/attacks/ssl_set_hostname/).
mbedTLS 3.6.3 makes a missing hostname fail under required verification; that
alone does not implement working IP verification. Also, macOS's mbedTLS 3.4.1
[`x509_crt_check_san`](https://github.com/Mbed-TLS/mbedtls/blob/v3.4.1/library/x509_crt.c)
only matches DNS SANs. Simply removing FFmpeg's numeric-host guard is not a
complete IP-SAN fix for that build.

## Why no CA-only patch was added

A bundled Mozilla CA set could solve root discovery, with provenance, update
ownership, asset extraction, and checked `tls-ca-file` configuration. It cannot
fix the name-check defect. A successful unauthenticated Dart TLS preflight followed
by an authenticated native connection is also insufficient: the second connection
can reach a different peer, and seeks/reconnects/redirects make new connections.
Never set `tls-verify=no`, accept bad certificates, or treat a trusted chain as a
substitute for DNS/IP identity verification.

A complete fix needs one of these larger, independently validated changes:

- Rebuild/pin native dependencies with correct DNS **and IP SAN** verification
  before application data, plus production trust roots. Validate redirects and
  every reconnect too; do not rely solely on a property readback.
- Move all authenticated network I/O into Dart's validating `HttpClient` (default
  trust roots, no permissive `badCertificateCallback`), keeping upstream URLs and
  credentials out of mpv. A streaming loopback relay needs range/seek support,
  bounded buffering/backpressure, timeouts, cancellation on stop/dispose/account
  changes, unpredictable local capabilities, and an explicit safe redirect policy.
  `macos/Runner/Release.entitlements` currently lacks `network.server`, which a
  sandboxed loopback listener also needs. A full-file download instead avoids a
  relay but regresses startup latency/storage and is not equivalent to streaming.

The native-library rebuild or transport change was **not implemented** in this
investigation. Production trusted playback and fail-fast, token-safe DNS/IP
handling on the pinned targets remain release blockers.

## Tests and limits of evidence

`test/services/native_playback_test.dart` now independently checks untrusted DNS
and IP peers, trusted-but-wrong DNS and IP peers, a DNS-only SAN used as an IP
endpoint, and trusted matching DNS/IP peers. Negative cases check that **no HTTP
request**, not merely no audio, reaches the invalid peer; they fail immediately
if a request arrives. The positive fixture cases intentionally inject a private
CA to isolate identity verification. They do not test production trust discovery.

Run against the specific desktop library being evaluated:

```sh
RUN_NATIVE_PLAYBACK=1 LIBMPV_PATH=/absolute/path/to/libmpv.so \
  flutter test test/services/native_playback_test.dart
```

A separate opt-in production-roots test uses `NATIVE_TRUSTED_AUDIO_URL`, which must
be a non-authenticated, publicly trusted HTTPS audio fixture lasting more than
100 ms. It does not set `tls-ca-file` or override verification. It is intentionally
skipped when that URL is absent; a skipped case is **not** evidence of working
production roots. No real account tokens should be used in this test.

Local execution using Flutter 3.47.5 and the host Linux libmpv 0.41.0 / FFmpeg 9.x
passed all seven TLS fixture cases and both existing decode/timing smoke tests.
The public-root fixture test was not executed (no fixture URL supplied).
Android/macOS pinned binaries were source-audited, not executed. Android needs an
on-device/integration runner with packaged certificates rather than this desktop
`openssl` fixture generator. Final acceptance must include the shipped binaries,
IPv6 identity cases, production roots, and invalid redirected/reconnected peers.
