# Android runner

`MainActivity` inherits `AudioServiceActivity` to reuse audio_service's Flutter
engine. The main manifest (including Release) declares INTERNET, WAKE_LOCK,
FOREGROUND_SERVICE and FOREGROUND_SERVICE_MEDIA_PLAYBACK, plus the exported media
browser service and media-button receiver documented by audio_service.
Media-session notifications are exempt from Android 13's notification permission;
no unrelated notification, microphone, or broad storage permission is requested.
Imports must use the system document picker and app-private copies.

The minimum SDK is at least 24: secure storage requires 23, and the network
security configuration requires 24. HTTPS is the default; only exact localhost,
127.0.0.1 and IPv6 loopback hosts have HTTP exceptions for local development.
Emulator host aliases and LAN HTTP are intentionally not allowed. Native network
settings are defense in depth; the Dart client must still enforce its URL policy
for requests/redirects and media URLs.

Backups are disabled and both legacy backup rules and Android 12+ cloud/device
transfer rules exclude all app data domains. This protects credentials, encrypted
preferences whose Keystore keys cannot be restored, and private imported files.
OEM backup/transfer behavior should still be checked on target devices.

Android 12+ restricts restarting foreground services from the background. The
Dart `AudioServiceConfig` must choose a deliberate pause/resume policy (see the
installed audio_service README's `androidStopForegroundOnPause` guidance); native
manifest configuration alone cannot guarantee background resume.

Audio focus is owned by the local `yun_android_audio_focus` Flutter plugin. Its
generated registration also covers the audio_service cold background engine.
Android 8+ can return a real delayed grant; Yun displays **Waiting for audio** and
starts only on a matching gain. Pause/Stop, replacement, permanent loss and
account teardown cancel waiting. Android 7 uses immediate grant/denial only.
The bridge never polls or attempts to bypass foreground eligibility rules.
The plugin also owns the headphone-unplug/noisy-output receiver for every
active registration. `audio_session` supplies configuration on Android, but does
not separately request focus or own the noisy receiver. Run `bash android/test-audio-focus.sh` for JVM
registration/cancellation tests; these are not device or Android-adapter tests.

Launcher density icons come from the unchanged `assets/icon.png`.
Build with `fvm flutter build apk --release --split-per-abi` or
`fvm flutter build appbundle --release`. Configure production signing before
distribution: the generated Gradle runner still uses its development signing
configuration. Background/lock-screen controls, focus interruptions, scoped
imports and secure storage require real-device tests; they are not validated
by compiling the runner.
