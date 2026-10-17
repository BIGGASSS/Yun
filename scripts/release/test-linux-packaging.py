#!/usr/bin/env python3
"""Inspect real Linux packages after building; no root, FUSE, or GUI required."""
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import tarfile
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
BUNDLE = ROOT / "build/linux/x64/release/bundle"
DIST = ROOT / "dist"


def run(*args, **kwargs):
    return subprocess.check_output(args, **kwargs)


class LinuxPackageTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temporary = tempfile.TemporaryDirectory(prefix="yun packages with spaces ")
        cls.addClassCleanup(cls.temporary.cleanup)
        cls.root = Path(cls.temporary.name)
        cls.deb = cls.root / "deb"
        run("dpkg-deb", "--extract", str(DIST / "yun-linux-x64.deb"), str(cls.deb))
        # This reads the embedded runtime without mounting or starting Yun.
        run(str(DIST / "yun-linux-x64.AppImage"), "--appimage-extract", cwd=cls.root)
        cls.appdir = cls.root / "squashfs-root"

    def assert_same_tree(self, source, destination):
        for path in source.rglob("*"):
            target = destination / path.relative_to(source)
            with self.subTest(path=path.relative_to(source)):
                if path.is_symlink():
                    self.assertTrue(target.is_symlink())
                    self.assertEqual(os.readlink(target), os.readlink(path))
                elif path.is_file():
                    self.assertEqual(target.read_bytes(), path.read_bytes())
                    self.assertEqual(target.stat().st_mode & 0o111, path.stat().st_mode & 0o111)
                else:
                    self.assertTrue(target.is_dir())

    def test_complete_bundles_and_inventory(self):
        for payload in (self.deb / "usr/lib/yun", self.appdir):
            self.assert_same_tree(BUNDLE, payload)
            for source in (ROOT / "LICENSE", ROOT / "docs/RELEASE.md", ROOT / "docs/VALIDATION.md",
                           ROOT / "scripts/release/NOTICES.txt", DIST / "BUILD.txt",
                           DIST / "flutter-dependencies.txt", DIST / "pubspec.lock"):
                self.assertEqual((payload / source.name).read_bytes(), source.read_bytes())

    def test_debian_metadata_and_desktop_integration(self):
        package = str(DIST / "yun-linux-x64.deb")
        self.assertEqual(run("dpkg-deb", "--field", package, "Package").decode().strip(), "yun")
        self.assertEqual(run("dpkg-deb", "--field", package, "Architecture").decode().strip(), "amd64")
        dependencies = run("dpkg-deb", "--field", package, "Depends").decode()
        for library in ("libc6", "libgtk-3-0t64", "libsecret-1-0", "libmpv2"):
            self.assertIn(library, dependencies)
        version = run("dpkg-deb", "--field", package, "Version").decode().strip()
        run("dpkg", "--validate-version", version)
        archive = run("dpkg-deb", "--fsys-tarfile", package)
        with tarfile.open(fileobj=io.BytesIO(archive)) as contents:
            for member in contents.getmembers():
                self.assertEqual((member.uid, member.gid), (0, 0), member.name)
        self.assertEqual(os.readlink(self.deb / "usr/bin/yun"), "/usr/lib/yun/yun")
        desktop = self.deb / "usr/share/applications/app.yun.yun.desktop"
        run("desktop-file-validate", str(desktop))
        self.assertEqual(desktop.read_bytes(), (ROOT / "linux/packaging/app.yun.yun.desktop").read_bytes())
        self.assertEqual(
            (self.deb / "usr/share/icons/hicolor/256x256/apps/app.yun.yun.png").read_bytes(),
            (ROOT / "linux/runner/resources/app.yun.yun.png").read_bytes(),
        )

    def test_appimage_entrypoint_forwards_arguments_from_other_directory(self):
        run("desktop-file-validate", str(self.appdir / "app.yun.yun.desktop"))
        # Work on a copy so the whole-bundle comparison remains independent.
        fixture = self.root / "launcher fixture"
        fixture.mkdir()
        shutil.copy2(self.appdir / "AppRun", fixture / "AppRun")
        executable = fixture / "yun"
        executable.write_text("#!/usr/bin/env python3\nimport json, sys\nprint(json.dumps(sys.argv[1:]))\n")
        executable.chmod(0o755)
        arguments = ["space in argument", "percent%", "韵", "--flag"]
        result = run(str(fixture / "AppRun"), *arguments, cwd=self.root)
        self.assertEqual(json.loads(result), arguments)


if __name__ == "__main__":
    unittest.main()
