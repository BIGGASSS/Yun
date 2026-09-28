#!/usr/bin/env python3
"""Host-only adaptive icon checks; requires Pillow, not an Android SDK."""

import importlib.util
import unittest
import xml.etree.ElementTree as ET
from pathlib import Path

from PIL import Image, ImageColor, ImageDraw

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location(
    "android_icons", ROOT / "scripts/generate-android-icons.py"
)
ICONS = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(ICONS)
ANDROID_DRAWABLE = "{http://schemas.android.com/apk/res/android}drawable"


class AndroidIconTests(unittest.TestCase):
    def test_generated_resources_are_current(self):
        for relative, content in ICONS.generate_resources().items():
            with self.subTest(resource=relative):
                self.assertTrue(ICONS.matches(ICONS.RES / relative, content), relative)

    def test_adaptive_resource_uses_full_bleed_background(self):
        root = ET.parse(ICONS.RES / "mipmap-anydpi-v26/ic_launcher.xml").getroot()
        self.assertEqual(root.tag, "adaptive-icon")
        self.assertEqual([child.tag for child in root], ["background", "foreground"])
        self.assertEqual(root.find("background").get(ANDROID_DRAWABLE), "@color/ic_launcher_background")
        self.assertEqual(root.find("foreground").get(ANDROID_DRAWABLE), "@drawable/ic_launcher_foreground")
        colors = ET.parse(ICONS.RES / "values/ic_launcher_colors.xml").getroot()
        color = colors.find("color[@name='ic_launcher_background']").text
        self.assertEqual(ImageColor.getcolor(color, "RGBA"), (18, 17, 33, 255))

    def test_artwork_scale_transparency_and_safe_zone(self):
        for density, scale in ICONS.DENSITIES.items():
            with self.subTest(density=density):
                with Image.open(ICONS.RES / f"drawable-{density}/ic_launcher_foreground.png") as foreground:
                    size = round(108 * scale)
                    self.assertEqual(foreground.mode, "RGBA")
                    self.assertEqual(foreground.size, (size, size))
                    alpha = foreground.getchannel("A")
                    left, top, right, bottom = alpha.getbbox()
                    self.assertAlmostEqual((right - left) / scale, 62, delta=1)
                    self.assertAlmostEqual((bottom - top) / scale, 42.3, delta=1)
                    self.assertAlmostEqual((left + right) / 2, size / 2, delta=1)
                    self.assertAlmostEqual((top + bottom) / 2, size / 2, delta=1)
                    # The 66dp safe-zone circle must contain the ribbon, including
                    # its transparent antialiased edge: no clipped ends on masks.
                    for y in range(size):
                        for x in range(size):
                            if alpha.getpixel((x, y)):
                                radius_squared = (x + 0.5 - size / 2) ** 2 + (y + 0.5 - size / 2) ** 2
                                self.assertLessEqual(radius_squared, (33 * scale) ** 2)

    def test_masked_icons_have_dark_edges_not_a_white_tile(self):
        with Image.open(ICONS.RES / "drawable-xxxhdpi/ic_launcher_foreground.png") as foreground:
            composite = Image.new("RGBA", foreground.size, ICONS.BACKGROUND)
            composite.alpha_composite(foreground)
        # Android masks the center 72dp of the 108dp layer.
        visible = composite.crop((72, 72, 360, 360))
        self.assertEqual(visible.getchannel("A").getextrema(), (255, 255))
        for shape in ("circle", "rounded-square", "square"):
            with self.subTest(shape=shape):
                outer = Image.new("L", visible.size)
                inner = Image.new("L", visible.size)
                for image, inset in ((outer, 0), (inner, 4)):
                    draw = ImageDraw.Draw(image)
                    bounds = (inset, inset, 287 - inset, 287 - inset)
                    if shape == "circle":
                        draw.ellipse(bounds, fill=255)
                    elif shape == "rounded-square":
                        draw.rounded_rectangle(bounds, radius=64 - inset, fill=255)
                    else:
                        draw.rectangle(bounds, fill=255)
                for y in range(288):
                    for x in range(288):
                        if outer.getpixel((x, y)) and not inner.getpixel((x, y)):
                            self.assertEqual(visible.getpixel((x, y)), (18, 17, 33, 255))

    def test_legacy_fallbacks_remain_available(self):
        for density, scale in ICONS.DENSITIES.items():
            with self.subTest(density=density):
                with Image.open(ICONS.RES / f"mipmap-{density}/ic_launcher.png") as icon:
                    self.assertEqual(icon.size, (round(48 * scale), round(48 * scale)))


if __name__ == "__main__":
    unittest.main()
