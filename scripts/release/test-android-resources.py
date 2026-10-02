#!/usr/bin/env python3
"""Resource-gate regressions; real APK integration tests run when aapt2 is present.

python3 scripts/release/test-android-resources.py
AAPT2=/path/to/aapt2 python3 scripts/release/test-android-resources.py

No committed APKs or SDK downloads are needed. Unit cases pair representative
AAPT2 2.19-12782657 dump output with ZIP fixtures. Integration cases use the real
SDK tool to compile and link minimal APKs, not mocked resource-table bytes.
"""

import importlib.util
import os
from pathlib import Path
import re
import struct
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
import warnings
import zipfile
import zlib

SCRIPT = Path(__file__).with_name("verify-android-resources.py")
SPEC = importlib.util.spec_from_file_location("android_resources", SCRIPT)
verifier = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = verifier
SPEC.loader.exec_module(verifier)
NAMES = verifier.REQUIRED_DRAWABLES


def png():
    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", 1, 1, 8, 6, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(b"\0\xff\xff\xff\xff")) + chunk(b"IEND", b""))


def dump_fixture(names=NAMES, resource_type="drawable", package=verifier.PACKAGE, config="mdpi-v4"):
    lines = ["Binary APK", f"Package name={package} id=7f", f"  type {resource_type} id=07 entryCount={len(names)}"]
    assets = {"resources.arsc": b"mocked table; parsed by fake aapt2 only"}
    for index, name in enumerate(names):
        path = f"res/obfuscated_{index}.png"
        assets[path] = png()
        lines.extend([
            f"    resource 0x7f07{index:04x} {resource_type}/{name}",
            f"      ({config}) (file) {path} type=PNG", "      Flag disabled values:",
        ])
    return "\n".join(lines) + "\n", assets


class ResourceGateTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="yun resource test ")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.apk = self.root / "final release.apk"
        self.dump, self.assets = dump_fixture()

    def write_apk(self, assets=None):
        with zipfile.ZipFile(self.apk, "w") as archive:
            for name, data in (self.assets if assets is None else assets).items():
                archive.writestr(name, data)

    def verify(self, dump=None, assets=None):
        self.write_apk(assets)
        with patch.object(verifier, "dump_resources", return_value=self.dump if dump is None else dump):
            return verifier.verify_apk(self.apk, "fake-aapt2")

    def assert_rejected(self, message, dump=None, assets=None):
        with self.assertRaisesRegex(verifier.VerificationError, message):
            self.verify(dump, assets)

    def test_required_names_match_vendored_media_controls(self):
        source = SCRIPT.parents[2] / "packages/audio_service/lib/audio_service.dart"
        controls = source.read_text().split("class MediaControl {", 1)[1].split("\n}", 1)[0]
        icons = set(re.findall(r"androidIcon:\s*['\"]([^'\"]+)['\"]", controls))
        self.assertEqual(icons, {"drawable/" + name for name in NAMES})

    def test_obfuscated_assets_keep_runtime_names_and_ids(self):
        resources, count = self.verify()
        self.assertEqual(count, 7)
        self.assertEqual([r.name for r in resources], ["drawable/" + name for name in NAMES])
        self.assertEqual(resources[0].resource_id, 0x7f070000)

    def test_every_required_name_is_checked(self):
        for name in NAMES:
            with self.subTest(name=name):
                dump, assets = dump_fixture(tuple(n for n in NAMES if n != name))
                self.assert_rejected(name, dump, assets)

    def test_string_pool_or_filename_is_not_a_resource_name(self):
        dump, assets = dump_fixture(())
        for name in NAMES:
            assets[f"res/drawable/{name}.png"] = png()
            assets[f"assets/{name}.txt"] = name.encode()
        self.assert_rejected("missing runtime drawable", dump, assets)

    def test_wrong_resource_type_does_not_satisfy_lookup(self):
        dump, assets = dump_fixture(resource_type="mipmap")
        self.assert_rejected("missing runtime drawable", dump, assets)

    def test_wrong_package_does_not_satisfy_lookup(self):
        dump, assets = dump_fixture(package="other.package")
        self.assert_rejected("missing resource package", dump, assets)

    def test_zero_or_inconsistent_id(self):
        for bad_id in ("0x00000000", "0x7f000001", "0x01070000", "0x7f080000"):
            with self.subTest(resource_id=bad_id):
                self.assert_rejected("invalid resource ID/type", self.dump.replace("0x7f070000", bad_id))

    def test_malformed_id(self):
        self.assert_rejected("invalid resource entry", self.dump.replace("0x7f070000", "0x7f07"))

    def test_inconsistent_type_heading(self):
        self.assert_rejected("invalid resource ID/type", self.dump.replace("type drawable", "type mipmap"))

    def test_duplicate_id(self):
        self.assert_rejected("duplicate resource", self.dump.replace("0x7f070001", "0x7f070000"))

    def test_duplicate_name(self):
        self.assert_rejected("duplicate resource", self.dump.replace(NAMES[1], NAMES[0]))

    def test_truncated_listing(self):
        self.assert_rejected("entryCount mismatch", self.dump.replace("entryCount=7", "entryCount=8"))

    def test_missing_values(self):
        self.assert_rejected("no file-backed", self.dump.replace("      (mdpi-v4) (file) res/obfuscated_0.png type=PNG\n", ""))

    def test_invalid_or_unsupported_values_and_aliases(self):
        for value in ("@0x00000000", "@0x7f070000", "@drawable/audio_service_pause",
                      "@drawable/missing", "@android:drawable/ic_media_play", "@null",
                      "#00000000", "(file) res/obfuscated_0.png type=UNKNOWN", "(file) res/obfuscated_0.png"):
            with self.subTest(value=value):
                self.assert_rejected("unsupported value/alias/flag", self.dump.replace("(file) res/obfuscated_0.png type=PNG", value))

    def test_missing_referenced_asset_even_with_source_named_png(self):
        self.assets[f"res/drawable/{NAMES[0]}.png"] = self.assets.pop("res/obfuscated_0.png")
        self.assert_rejected("missing or duplicate APK asset")

    def test_empty_referenced_asset(self):
        self.assets["res/obfuscated_0.png"] = b""
        self.assert_rejected("empty APK asset")

    def test_duplicate_asset(self):
        self.write_apk()
        with warnings.catch_warnings():
            warnings.simplefilter("ignore", UserWarning)
            with zipfile.ZipFile(self.apk, "a") as archive:
                archive.writestr("res/obfuscated_0.png", png())
        with patch.object(verifier, "dump_resources", return_value=self.dump):
            with self.assertRaisesRegex(verifier.VerificationError, "duplicate APK asset"):
                verifier.verify_apk(self.apk, "fake-aapt2")

    def test_corrupt_asset_crc(self):
        self.write_apk()
        with zipfile.ZipFile(self.apk) as archive:
            offset = archive.getinfo("res/obfuscated_0.png").header_offset
        data = bytearray(self.apk.read_bytes())
        name_length, extra_length = struct.unpack_from("<HH", data, offset + 26)
        data[offset + 30 + name_length + extra_length] ^= 0xff
        self.apk.write_bytes(data)
        with patch.object(verifier, "dump_resources", return_value=self.dump):
            with self.assertRaisesRegex(verifier.VerificationError, "cannot read APK.*CRC"):
                verifier.verify_apk(self.apk, "fake-aapt2")

    def test_all_density_variants_are_checked(self):
        dump = self.dump.replace("      Flag disabled values:", "      (xxxhdpi) (file) res/absent.png type=PNG\n      Flag disabled values:", 1)
        self.assert_rejected("missing or duplicate APK asset", dump)

    def test_shared_asset_paths_are_valid(self):
        dump = self.dump
        for index in range(1, 7):
            dump = dump.replace(f"res/obfuscated_{index}.png", "res/obfuscated_0.png")
        self.assertEqual(self.verify(dump)[1], 1)

    def test_old_dump_without_flag_sections(self):
        self.assertEqual(self.verify(self.dump.replace("      Flag disabled values:\n", ""))[1], 7)

    def test_nonempty_flag_disabled_values_rejected(self):
        dump = self.dump.replace("      Flag disabled values:", "      Flag disabled values:\n      () (file) res/obfuscated_0.png type=PNG", 1)
        self.assert_rejected("unsupported value/alias/flag", dump)

    def test_conditional_only_values_have_no_fallback(self):
        for config in ("en", "night", "land", "mdpi-v25", "v33", "en-mdpi-v4"):
            with self.subTest(config=config):
                self.assert_rejected("no universal fallback", dump_fixture(config=config)[0])

    def test_generic_or_density_fallbacks(self):
        for config in ("", "mdpi", "anydpi-v21", "nodpi", "320dpi-v24", "v24"):
            with self.subTest(config=config):
                self.assertEqual(self.verify(dump_fixture(config=config)[0])[1], 7)

    def test_duplicate_config(self):
        value = "      (mdpi-v4) (file) res/obfuscated_0.png type=PNG\n"
        self.assert_rejected("duplicate configuration", self.dump.replace(value, value * 2))

    def test_unsafe_paths(self):
        for path in ("../icon.png", "/res/icon.png", "res/../icon.png", "res//icon.png", "res/./icon.png", "res\\icon.png", "assets/icon.png", "res/folder/"):
            with self.subTest(path=path):
                self.assert_rejected("unsafe asset path", self.dump.replace("res/obfuscated_0.png", path))

    def test_empty_missing_duplicate_table(self):
        for data in (None, b""):
            with self.subTest(table=data):
                if data is None:
                    self.assets.pop("resources.arsc", None)
                else:
                    self.assets["resources.arsc"] = data
                self.assert_rejected("exactly one nonempty resources.arsc")
        self.assets["resources.arsc"] = b"table"
        self.write_apk()
        with warnings.catch_warnings():
            warnings.simplefilter("ignore", UserWarning)
            with zipfile.ZipFile(self.apk, "a") as archive:
                archive.writestr("resources.arsc", b"second table")
        with self.assertRaisesRegex(verifier.VerificationError, "exactly one"):
            verifier.verify_apk(self.apk, "fake-aapt2")

    def test_bad_zip_or_missing_apk(self):
        with self.assertRaisesRegex(verifier.VerificationError, "does not exist"):
            verifier.verify_apk(self.apk, "fake-aapt2")
        self.apk.write_bytes(b"not an APK")
        with self.assertRaisesRegex(verifier.VerificationError, "cannot read APK"):
            verifier.verify_apk(self.apk, "fake-aapt2")

    def test_unrecognized_dump_format(self):
        for dump in ("", "Proto APK\n" + self.dump, self.dump.replace("Binary APK\n", "")):
            with self.subTest(dump=dump[:20]):
                self.assert_rejected("unexpected aapt2 dump", dump)

    def test_aapt2_failure_or_diagnostics(self):
        for returncode, stderr in ((1, "corrupt table"), (0, "warning: corrupt table")):
            with self.subTest(returncode=returncode):
                result = subprocess.CompletedProcess([], returncode, self.dump, stderr)
                with patch.object(verifier.subprocess, "run", return_value=result):
                    with self.assertRaisesRegex(verifier.VerificationError, "aapt2"):
                        verifier.dump_resources(self.apk, "fake-aapt2")

    def test_aapt2_timeout(self):
        with patch.object(verifier.subprocess, "run", side_effect=subprocess.TimeoutExpired("aapt2", 120)):
            with self.assertRaisesRegex(verifier.VerificationError, "unable to inspect"):
                verifier.dump_resources(self.apk, "fake-aapt2")

    def test_cli_checks_exact_apk_and_fails_closed(self):
        self.write_apk()
        fake = self.root / "aapt2"
        fake.write_text(f"#!{sys.executable}\nimport sys\nassert sys.argv[1:] == {['dump', 'resources', str(self.apk)]!r}\nprint({self.dump!r}, end='')\n")
        fake.chmod(0o755)
        command = [sys.executable, str(SCRIPT), str(self.apk), "--aapt2", str(fake)]
        result = subprocess.run(command, text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Verified 7 runtime media drawables", result.stdout)
        self.assets.pop("res/obfuscated_0.png")
        self.write_apk()
        result = subprocess.run(command, text=True, capture_output=True)
        self.assertEqual(result.returncode, 1)
        self.assertIn("missing or duplicate APK asset", result.stderr)

    def test_tool_discovery_and_missing_tool(self):
        with patch.dict(os.environ, {}, clear=True), patch.object(verifier.shutil, "which", return_value=None):
            with self.assertRaisesRegex(verifier.VerificationError, "aapt2 missing"):
                verifier.find_aapt2()
        with patch.dict(os.environ, {"AAPT2": "/missing/aapt2"}), patch.object(verifier.shutil, "which", return_value=None):
            with self.assertRaisesRegex(verifier.VerificationError, "not executable"):
                verifier.find_aapt2()
        for version in ("9.0.0", "36.0.0-rc1", "36.0.0"):
            candidate = self.root / "build-tools" / version / "aapt2"
            candidate.parent.mkdir(parents=True)
            candidate.write_text("#!/bin/sh\n")
            candidate.chmod(0o755)
        with patch.dict(os.environ, {"ANDROID_SDK_ROOT": str(self.root)}, clear=True):
            self.assertEqual(verifier.find_aapt2(), str(self.root / "build-tools/36.0.0/aapt2"))


try:
    AAPT2 = verifier.find_aapt2()
except verifier.VerificationError:
    AAPT2 = None


@unittest.skipUnless(AAPT2, "real Android SDK aapt2 unavailable; unit coverage still runs")
class RealAapt2Tests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="yun actual APK ")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)

    def build(self, missing=None, alias=False):
        drawable = self.root / "res/drawable-mdpi"
        drawable.mkdir(parents=True)
        for name in NAMES:
            if name != missing and not (alias and name == NAMES[0]):
                (drawable / f"{name}.png").write_bytes(png())
        if alias:
            values = self.root / "res/values"
            values.mkdir()
            (values / "aliases.xml").write_text(f'<resources><drawable name="{NAMES[0]}">@drawable/{NAMES[1]}</drawable></resources>')
        manifest = self.root / "AndroidManifest.xml"
        manifest.write_text(f'<manifest package="{verifier.PACKAGE}"><application /></manifest>')
        compiled = self.root / "compiled.zip"
        apk = self.root / "fixture.apk"
        for args in (("compile", "--dir", str(self.root / "res"), "-o", str(compiled)),
                     ("link", "--manifest", str(manifest), "-o", str(apk), str(compiled))):
            result = subprocess.run([AAPT2, *args], text=True, capture_output=True)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return apk

    def test_actual_compiled_resource_table_and_assets(self):
        resources, count = verifier.verify_apk(self.build(), AAPT2)
        self.assertEqual(len(resources), 7)
        self.assertEqual(count, 7)

    def test_actual_missing_name(self):
        with self.assertRaisesRegex(verifier.VerificationError, NAMES[0]):
            verifier.verify_apk(self.build(missing=NAMES[0]), AAPT2)

    def test_actual_alias_is_rejected(self):
        with self.assertRaisesRegex(verifier.VerificationError, "unsupported value/alias/flag"):
            verifier.verify_apk(self.build(alias=True), AAPT2)

    def test_actual_malformed_table_is_rejected(self):
        apk = self.build()
        with zipfile.ZipFile(apk) as archive:
            entries = {name: archive.read(name) for name in archive.namelist()}
        entries["resources.arsc"] = b"malformed resource table"
        with zipfile.ZipFile(apk, "w") as archive:
            for name, data in entries.items():
                archive.writestr(name, data)
        with self.assertRaisesRegex(verifier.VerificationError, "aapt2 rejected APK"):
            verifier.verify_apk(apk, AAPT2)


if __name__ == "__main__":
    unittest.main()
