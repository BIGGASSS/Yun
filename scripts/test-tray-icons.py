#!/usr/bin/env python3
"""Host-only tray artwork and stale-resource checks (requires Pillow).

Run: python3 scripts/test-tray-icons.py
No desktop session, native plugin, or Flutter SDK is used.
"""

import contextlib
import importlib.util
from io import BytesIO, StringIO
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from PIL import Image

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location(
    "tray_icons", ROOT / "scripts/generate-tray-icons.py"
)
ICONS = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(ICONS)
PNG_SIZES = {"yun_linux.png": 64, "yun_macos.png": 36}
ICO_SIZES = (16, 20, 24, 32, 40, 48, 64, 128, 256)


class TrayIconTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        with Image.open(ROOT / "assets/icon.png") as source:
            cls.source = source.convert("RGBA")
        cls.resources = ICONS.generate_resources()

    def assert_direct_resize(self, image, size):
        self.assertEqual(image.size, (size, size))
        self.assertEqual(image.mode, "RGBA")
        expected = self.source.resize((size, size), Image.Resampling.LANCZOS)
        self.assertEqual(image.tobytes(), expected.tobytes())
        for corner in ((0, 0), (0, size - 1), (size - 1, 0), (size - 1, size - 1)):
            # Direct Lanczos filtering leaves alpha 1–3 at some 20/24px
            # corners. Preserve those source-derived antialiasing pixels rather
            # than postprocessing the image into a different rendering.
            self.assertLessEqual(image.getpixel(corner)[3], 3)
        # A monochrome/template silhouette would discard the branded colors.
        colors = {
            (r, g, b) for _, (r, g, b, a) in image.getcolors(size * size)
            if a > 128 and max(r, g, b) - min(r, g, b) > 30
        }
        self.assertGreater(len(colors), 10)

    def test_bundled_pngs_are_direct_full_color_source_resizes(self):
        for name, size in PNG_SIZES.items():
            with self.subTest(resource=name):
                with Image.open(ICONS.DESTINATION / name) as image:
                    self.assertEqual(image.format, "PNG")
                    self.assert_direct_resize(image, size)

    def test_every_bundled_ico_frame_is_a_direct_source_resize(self):
        with Image.open(ICONS.DESTINATION / "yun.ico") as image:
            self.assertEqual(image.format, "ICO")
            self.assertEqual(image.ico.sizes(), {(size, size) for size in ICO_SIZES})
            for size in ICO_SIZES:
                with self.subTest(size=size):
                    self.assert_direct_resize(image.ico.getimage((size, size)), size)

    def test_generated_resources_are_current(self):
        self.assertEqual(set(self.resources), {*PNG_SIZES, "yun.ico"})
        for name, content in self.resources.items():
            with self.subTest(resource=name):
                self.assertTrue(ICONS.matches(ICONS.DESTINATION / name, content))

    def test_check_accepts_different_png_compression(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "yun_macos.png"
            with Image.open(BytesIO(self.resources[path.name])) as image:
                image.save(path, compress_level=0)
            self.assertNotEqual(path.read_bytes(), self.resources[path.name])
            self.assertTrue(ICONS.matches(path, self.resources[path.name]))

    def test_check_rejects_stale_png_and_individual_ico_frame_without_writing(self):
        for name in ("yun_macos.png", "yun_linux.png", "yun.ico"):
            with self.subTest(resource=name), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                destination = root / "assets/tray_icons"
                destination.mkdir(parents=True)
                for resource, content in self.resources.items():
                    (destination / resource).write_bytes(content)
                path = destination / name
                with Image.open(path) as image:
                    if name.endswith(".ico"):
                        frames = [image.ico.getimage((size, size)) for size in ICO_SIZES]
                        # Leave the default/largest frame untouched: checking only
                        # Image.open(...).tobytes() would miss this corruption.
                        frames[0].putpixel((8, 8), (255, 0, 0, 255))
                        frames[-1].save(
                            path, format="ICO", sizes=[(size, size) for size in ICO_SIZES],
                            append_images=frames[:-1],
                        )
                    else:
                        image.load()
                        image.putpixel((8, 8), (255, 0, 0, 255))
                        image.save(path)
                before = {item.name: item.read_bytes() for item in destination.iterdir()}
                stderr = StringIO()
                with (
                    patch.object(ICONS, "ROOT", root),
                    patch.object(ICONS, "DESTINATION", destination),
                    patch.object(ICONS, "generate_resources", return_value=self.resources),
                    patch("sys.argv", ["generate-tray-icons.py", "--check"]),
                    contextlib.redirect_stderr(stderr),
                    self.assertRaises(SystemExit) as error,
                ):
                    ICONS.main()
                self.assertEqual(error.exception.code, 1)
                self.assertIn(f"assets/tray_icons/{name}", stderr.getvalue())
                self.assertEqual(
                    before, {item.name: item.read_bytes() for item in destination.iterdir()}
                )

    def test_check_rejects_missing_and_invalid_files(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "yun.ico"
            self.assertFalse(ICONS.matches(path, self.resources[path.name]))
            path.write_bytes(b"not an icon")
            self.assertFalse(ICONS.matches(path, self.resources[path.name]))


if __name__ == "__main__":
    unittest.main()
