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
