# macOS runner

Build on macOS with Xcode and CocoaPods installed:

```sh
fvm flutter pub get
fvm flutter build macos --release
```

`Podfile` is the pinned Flutter SDK's macOS template. Its macOS 12.0 minimum
matches `Runner.xcodeproj` and exceeds the installed audio_service (10.12.2)
and media_kit requirements. Keep Flutter's Swift Package Manager integration;
CocoaPods handles plugins such as `media_kit_libs_macos_audio` that do not yet
provide Swift packages. Do not hand-edit generated plugin registrants.

Both entitlement files retain the sandbox and grant:

- Outbound network access for the HTTPS API/audio client.
- Read-only access to files explicitly selected by the user. Imports must copy
  selected content into the app container while picker access is available;
  arbitrary external paths or persisted picker paths are not authorized.
- Keychain access groups as instructed by flutter_secure_storage. Configure the
  signing team/certificate in Xcode for distribution and verify Keychain access
  with the signed app.

Debug/Profile additionally retains Flutter's JIT and network-server permissions;
Release does not grant those. Playback does not need microphone/audio-input
permission or the iOS-only `UIBackgroundModes` key. Although media_kit's generic
README suggests disabling sandboxing for unrestricted file paths, Yun uses the
scoped picker and app container instead; no blanket filesystem access is granted.

The app and window display name is 韵; executable/bundle product paths remain
`yun` to preserve the generated Xcode scheme. AppIcon images are generated from
the unchanged `assets/icon.png`. Playback, system controls, picker import and
Keychain access still require on-device smoke tests.
