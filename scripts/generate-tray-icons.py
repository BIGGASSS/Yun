#!/usr/bin/env python3
"""Generate full-color desktop tray icons from assets/icon.png (requires Pillow).

Run from the repository root (resource paths are independent of the CWD):
    python3 scripts/generate-tray-icons.py
    python3 scripts/generate-tray-icons.py --check
    python3 scripts/test-tray-icons.py

The original artwork is read-only. Each PNG and ICO frame is resized directly
from it with Lanczos, preserving color and alpha (not a macOS template mask).
macOS uses a 36px image at 18 points / 2x; Linux uses 64px. Windows receives all
nine native/DPI sizes below. --check compares every decoded frame, so equivalent
PNG compression is accepted but a stale small ICO frame is not.
"""

import argparse
from io import BytesIO
from pathlib import Path

from PIL import Image

ROOT = Path(__file__).resolve().parents[1]
DESTINATION = ROOT / "assets/tray_icons"
PNG_SIZES = {"yun_linux.png": 64, "yun_macos.png": 36}
ICO_SIZES = (16, 20, 24, 32, 40, 48, 64, 128, 256)


def generate_resources():
    with Image.open(ROOT / "assets/icon.png") as image:
        source = image.convert("RGBA")
    if source.width != source.height:
        raise ValueError("Tray artwork must be square; review the source before resizing")

    resources = {}
    for name, size in PNG_SIZES.items():
        output = BytesIO()
        source.resize((size, size), Image.Resampling.LANCZOS).save(
            output, format="PNG", optimize=True
        )
        resources[name] = output.getvalue()

    # Render every frame directly from the original, rather than repeatedly
    # reducing a small image. Windows selects the frame for its tray/DPI size.
    frames = [source.resize((size, size), Image.Resampling.LANCZOS) for size in ICO_SIZES]
    output = BytesIO()
    frames[-1].save(
        output,
        format="ICO",
        sizes=[(size, size) for size in ICO_SIZES],
        append_images=frames[:-1],
    )
    resources["yun.ico"] = output.getvalue()
    return resources


def pixels(image):
    return image.size, image.convert("RGBA").tobytes()


def matches(path, expected):
    if not path.exists():
        return False
    try:
        with Image.open(path) as actual, Image.open(BytesIO(expected)) as wanted:
            # Compare decoded pixels, not compressor-dependent binary output.
            if actual.format != wanted.format:
                return False
            if wanted.format == "ICO":
                sizes = wanted.ico.sizes()
                return actual.ico.sizes() == sizes and all(
                    pixels(actual.ico.getimage(size)) == pixels(wanted.ico.getimage(size))
                    for size in sizes
                )
            return pixels(actual) == pixels(wanted)
    except (OSError, ValueError):
        return False


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="Check assets without writing")
    args = parser.parse_args()
    stale = []
    for name, content in generate_resources().items():
        path = DESTINATION / name
        if args.check:
            if not matches(path, content):
                stale.append(str(path.relative_to(ROOT)))
        else:
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(content)
            print(path.relative_to(ROOT))
    if stale:
        parser.exit(1, "Outdated or missing tray icons:\n" + "\n".join(stale) + "\n")
    if args.check:
        print("Tray icons match assets/icon.png.")


if __name__ == "__main__":
    main()
