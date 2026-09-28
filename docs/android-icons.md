# Android launcher icons

Android 8.0/API 26 and newer resolve `@mipmap/ic_launcher` to
`android/app/src/main/res/mipmap-anydpi-v26/ic_launcher.xml`. This adaptive icon
has an opaque, full-bleed `#121121` background and a transparent ribbon foreground.
The launcher supplies the circle, squircle, or other mask; there is no baked-in
rounded tile or white background. Pre-26 devices retain the existing legacy
`mipmap-*/ic_launcher.png` files. No manifest change is required.

The foreground is generated from `assets/icon.png` at all five standard launcher
densities. Its canvas is 108dp, with a centered 62dp-wide ribbon. The entire ribbon
fits inside Android's 66dp-diameter safe zone, while filling most of the nominal
72dp masked viewport. This keeps the mark prominent without clipping its ends.

The source includes a rounded dark tile and transparent corners. Simply resizing
that whole image into an adaptive foreground would preserve an unwanted inner
tile. The generator instead crops away the tile border and uses a soft
blue-channel color key to isolate the ribbon. The crop and thresholds are tuned
to the current 1024×1024 artwork; review them and the resulting masked icon if the
source design changes. The solid background matches the source's dark interior
rather than reproducing its subtle background gradient.

## Regenerate and validate

Only Python 3 and Pillow are needed (for example, `python3 -m pip install Pillow`
in a virtual environment). Generated Android resources are checked in; app builds
do not require Python or Pillow.

```sh
python3 scripts/generate-android-icons.py
python3 scripts/generate-android-icons.py --check
python3 scripts/test-android-icons.py
```

The generator does not touch legacy icons or other platforms. `--check` verifies
resource XML and decoded PNG pixels without writing. Tests also check density
sizes, artwork scale/centering, the circular safe zone, opaque dark edges under
circle/rounded-square/square masks, and availability of the legacy fallbacks.

For a device check, install on API 26+ and inspect multiple launcher mask shapes.
If an old icon persists, reinstall or clear the launcher's icon cache. Check an
older Android device/emulator separately for the unchanged legacy fallback.
