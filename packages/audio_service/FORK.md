# Yun audio_service initialization fix

This is a minimal runtime fork of **audio_service 0.18.19**, published by Ryan
Heise under the MIT license in `LICENSE`.

- Release: https://pub.dev/packages/audio_service/versions/0.18.19
- Upstream repository: https://github.com/ryanheise/audio_service
- Published archive: https://pub.dev/api/archives/audio_service-0.18.19.tar.gz
- Archive SHA-256 from Pub's verified package cache:
  `95f3267f3449eb5cf71c8fcf1d556f57af1e898e2dc5815fb168d1843653edb7`
- `UPSTREAM_SHA256SUMS` records the original bytes of every vendored upstream
  file, including `lib/audio_service.dart` before this patch.

The Dart library, original pubspec and license, Android library build file,
Android runtime Java/resources/manifest, and shared Darwin CocoaPods/Swift
Package runtime are included. Web remains the upstream `audio_service_web`
dependency. Linux's MPRIS implementation and Windows integration are separate
dependencies in Yun. Examples, upstream tests, generated output, and standalone
Android Gradle wrapper/settings files are omitted.

## Local changes

`lib/audio_service.dart` and Android's `AudioServicePlugin.java` are patched.
All other vendored upstream files are unchanged. The Android connection
coordinator and regression tests are new fork-owned files.

Upstream Dart sets `_cacheManager` before
awaiting platform configuration. If configuration fails, the next debug init
asserts, so an app-level retry cannot recover.

The fork keeps one initialization future. Concurrent calls share the first
call's builder, configuration, and cache; successful calls keep returning that
handler without registering global observers again. Callers must use a handler
type compatible with the first builder's result.

If setup/configuration fails **before the handler builder runs**, the attempt
releases only the cache reference and future it owns. A subsequent explicit
call can start a fresh attempt with fresh platform callbacks. No retry occurs
automatically, and no caller-owned cache or default cache singleton is disposed.
Failure after configuration is intentionally retained: a builder could already
have created app-owned resources, and it is unsafe to repeat partial handler or
observer setup. No reset/dispose/reconfigure API is added.

Android also kept a disconnected browser and an already-failed configure result
(or a permanent failure flag), preventing a real rebind on retry. The plugin now
uses `AudioServiceConnection` to own one browser generation and pending configure
result. An explicit configure can make one new connection when the old one has
failed; there is no retry timer. Failure or pre-configuration suspension retires
the generation, clears the result before delivery, and disconnects native
resources. Old callbacks cannot complete a newer request. Explicit configuration
from a different engine rebuilds the browser once with the new engine's callback
and context ownership, matching the native audio-handler takeover. Detaching the
old engine cannot retire the new engine's connection. Engine detach retires the
owned connection. Existing activity/configuration-change detach behavior is preserved,
with pending initialization retired on final activity detach. Wrong-engine
checks and OS policy are unchanged. Suspension after successful initialization
keeps upstream behavior rather than recreating a handler.

The root regression test `test/services/audio_service_initialization_test.dart`
calls the real vendored `AudioService.init` with assertions enabled and one
controlled `AudioServicePlatform` installed before the library's cached platform
is first used. It covers early failure, repeated configure failures, concurrent
calls, recovery, and one-time observer registration.

Run from the repository root:

```sh
flutter test test/services/audio_service_initialization_test.dart
bash packages/audio_service/android/test-connection.sh
```

The JVM tests exercise the production coordinator without Android dependencies:
failure before/during configure, explicit retry, callback generations, duplicate
results, engine detach/takeover, suspension, synchronous callback/connect errors,
reentrant retry, and a throwing disconnect cleanup. They do not replace an
Android plugin build or device-level service-binding test.

Root override:

```yaml
dependency_overrides:
  audio_service:
    path: packages/audio_service
```

Remove this fork and override when an upstream release provides equivalent
retry/coalescing behavior, retaining the regression test to check the migration.

## Non-functional vendoring cleanup

The podspec’s extra final blank line and one whitespace-only Objective-C line
were trimmed for repository whitespace checks. No Darwin behavior changed;
`UPSTREAM_SHA256SUMS` retains their original published-byte hashes.
