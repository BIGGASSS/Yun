# Yun's Linux tray plugin selection

This app-specific, Dart-only plugin implements `tray_manager` for Flutter's
platform selection. Yun already creates and manages its Linux StatusNotifierItem
and DBusMenu in `lib/services/linux_status_notifier_tray.dart`. There is nothing
to register here, and no native method-channel tray API is provided.

Keep this package as a **direct production dependency** of Yun. Flutter selects
it instead of `tray_manager`'s inline native Linux implementation, excluding that
unused plugin from native registration, CMake, and the bundle. A dev dependency
would be filtered out of release builds. The upstream Dart API and Windows/macOS
native implementations remain unchanged; no upstream files are forked.

Do not edit generated plugin lists to remove Linux linkage: `flutter pub get`
regenerates them from these declarations. Check the selection and built bundle:

```sh
fvm flutter pub get
python3 scripts/verify-linux-tray-linkage.py
fvm flutter build linux --release
python3 scripts/verify-linux-tray-linkage.py --bundle build/linux/x64/release/bundle
```

The verifier also requires the upstream Windows/macOS native plugins to remain
selected. Desktop adapter and Linux SNI tests remain in `test/services/`.
