# Yun Android audio focus

A local Flutter plugin registered by `GeneratedPluginRegistrant` in every Flutter
engine. `AudioServiceActivity` reuses audio_service's cached engine, while a cold
media-service start can create an engine before any Activity exists. Both paths
get this plugin; no Activity attachment, recreation or cleanup owns focus.

The Dart facade is `lib/services/android_audio_focus.dart` in the app. Only it owns
Android focus and becoming-noisy events. `audio_session` must not separately call
`setActive` or supply Android interruption/noisy events: its noisy receiver exists
only when that package itself owns focus. Apple behavior remains separate.

- API 26+: permanent gain, media/music attributes, delayed gain accepted,
  pause-on-duck, main-thread listener, explicit granted/delayed/failed reply
- API 24–25: legacy music-stream request, granted/failed only
- One active native registration. Replacement, abandonment, permanent loss and
  engine destruction invalidate its listener identity before cleanup, so queued
  callbacks cannot resurrect playback
- Dart request IDs also filter native events already in transit. A current grant
  is reused; transient loss changes it to delayed. Resuming after gain never
  issues a second OS focus request, including in the background
- The application-context noisy receiver is registered only for granted/delayed
  requests. Unplug cancels the registration and waiting intent permanently;
  transient loss keeps unplug monitoring active. Cancellation, permanent loss,
  failed acquisition and engine detach clean it up without Activity ownership.
  The sole protected system broadcast uses Android 14's documented system-only
  registration exception (no export flag). Both focus and receiver cleanup retry
  independently if either fails.
- No timers or polling. Android 15+ foreground eligibility denials remain failures

Run `bash android/test-audio-focus.sh` from the repository root for deterministic
JVM lifetime/race tests. Run `flutter test test/services/android_audio_focus_test.dart`
for channel/token/state tests. The Android native-artifact CI job runs JVM tests
before building the app, which compiles the framework adapter and generated
plugin registration. These tests do not certify device audio policy; real-device
locked-focus, screen-off controls, Activity recreation and cold-service checks
remain necessary.

API references:
- https://developer.android.com/media/optimize/audio-focus
- https://developer.android.com/reference/android/media/AudioFocusRequest.Builder
- https://developer.android.com/about/versions/14/behavior-changes-14#runtime-registered-broadcast-receivers

## Privacy-safe focus diagnostics

Release builds write native records under the `YunAudioFocus` logcat tag and
forward a structured `diagnostic` channel event. The Dart facade also logs its
channel outcomes with the `YunAudioFocus` prefix; tests or an in-app collector can
use the optional `onDiagnostic` callback. These records do not alter focus state,
turn a denial into a delayed request, or add automatic retries. Request replies
remain exactly `granted`, `delayed`, or `failed`; abandonment remains boolean.

Each record has a fixed `category`, numeric `requestId`, fixed `result`, and an
optional `exceptionClass`. Request IDs are local correlation counters, not media
or account IDs; zero means no active request is known on that side. Cleanup can
refer to a retired request after a newer request is attempted. Exception
messages, codes, details, causes, stack traces, media URLs, and account data are
never logged. Dart allowlists incoming fields and rejects unknown categories or
results. Diagnostic callbacks are isolated from focus ownership and results.

Read these categories together for the same request ID:

- `native_request`: the actual AudioManager outcome. `failed` is an OS refusal;
  `error` plus an exception class is a thrown native request failure. A refusal
  does not reveal its policy cause, so it must not be labeled an Android 15/16
  foreground restriction without additional evidence
- `bridge_prepare` / `bridge_channel`: native bridge construction or messaging
  failure, distinct from an AudioManager refusal
- `noisy_register` / `noisy_unregister`: route-receiver setup or cleanup. A
  `granted` native request followed by a `noisy_register` error fails acquisition
  and releases both resources. `success` with `IllegalArgumentException` on
  unregister means Android reported the receiver was already absent
- `native_abandon`: AudioManager cleanup result, independent of receiver cleanup
- `request` / `abandon`: aggregate coordinator outcomes. `cleanup_blocked` means
  an earlier registration could not be released; `cancelled` means acquisition
  lost its active identity before completion
- `channel_request`, `channel_abandon`, `channel_dispose`: Dart bridge outcomes.
  `error` retains only the Dart exception class. `invalid_response` rejects an
  unknown native reply without logging its contents

For a focused device reproduction, start this before playback and retain only
these lines (the filter includes Dart channel errors without saving unrelated
Flutter output):

```sh
adb logcat -v threadtime YunAudioFocus:I flutter:I '*:S' | grep 'YunAudioFocus'
```

Record whether playback was foregrounded, backgrounded, or screen-locked and
whether the failure followed a track transition. The diagnostic JVM/channel
coverage is deterministic; it does not replace an Android 16 / OPPO device
reproduction or prove why the OS denied focus.
