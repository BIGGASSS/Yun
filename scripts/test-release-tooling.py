#!/usr/bin/env python3
"""Host-only tooling tests; no build artifacts, Docker daemon, or real installation."""
import hashlib
import io
import os
from pathlib import Path
import shutil
import subprocess
import tarfile
import tempfile
import unittest

ROOT = Path(__file__).resolve().parent.parent


class ReleaseToolingTests(unittest.TestCase):
    def test_linux_install_and_upgrade_with_spaces_and_percent(self):
        with tempfile.TemporaryDirectory(prefix="yun installer test ") as directory:
            root = Path(directory)
            bundle = root / "bundle"
            bundle.mkdir()
            home = root / "home with spaces %f %U %%"
            home.mkdir()
            for name in ("install-linux.sh", "yun.desktop"):
                shutil.copy2(ROOT / "scripts/release" / name, bundle / name)
            (bundle / "yun").write_text("#!/bin/sh\necho test-fixture\n")
            (bundle / "yun").chmod(0o755)
            (bundle / "yun.png").write_bytes(b"fixture")
            (bundle / "data").mkdir()
            (bundle / "data/asset").write_text("preserved")
            environment = dict(os.environ, HOME=str(home), XDG_DATA_HOME=str(home / "data"))
            for _ in range(2):
                subprocess.run(["bash", str(bundle / "install-linux.sh")], env=environment, check=True)
            self.assertEqual((home / ".local/opt/yun/data/asset").read_text(), "preserved")
            self.assertEqual((home / ".local/opt/yun.previous/data/asset").read_text(), "preserved")
            entry = home / "data/applications/yun.desktop"
            escaped_home = str(home).replace('%', '%%')
            self.assertIn(f'Exec="{escaped_home}/.local/opt/yun/yun"', entry.read_text())
            # Icon is not an Exec command: percent signs there stay literal.
            self.assertIn(f'Icon={home}/.local/opt/yun/yun.png', entry.read_text())
            if shutil.which("desktop-file-validate"):
                subprocess.run(["desktop-file-validate", str(entry)], check=True)

    def test_archive_checksums(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "dist").mkdir()
            (root / "dist/candidate.zip").write_bytes(b"fixture")
            subprocess.run(["python3", str(ROOT / "scripts/release/checksums.py")], cwd=root, check=True)
            self.assertEqual(
                (root / "dist/SHA256SUMS").read_text(),
                hashlib.sha256(b"fixture").hexdigest() + "  candidate.zip\n",
            )

    def test_restore_rejects_unsafe_or_nonbackup_archives_before_docker(self):
        for name, symbolic in (("../escape", False), ("/absolute", False), ("link", True), ("not-a-backup", False)):
            with self.subTest(name=name), tempfile.TemporaryDirectory() as directory:
                path = Path(directory) / "bad.tar.gz"
                with tarfile.open(path, "w:gz") as archive:
                    info = tarfile.TarInfo(name)
                    if symbolic:
                        info.type = tarfile.SYMTYPE
                        info.linkname = "/tmp/escape"
                    archive.addfile(info, io.BytesIO(b""))
                result = subprocess.run(
                    ["bash", str(ROOT / "scripts/server-restore.sh"), str(path)],
                    text=True, capture_output=True,
                )
                self.assertNotEqual(result.returncode, 0)
                self.assertTrue("Unsafe archive member" in result.stderr or "yun.sqlite3 missing" in result.stderr)


if __name__ == "__main__":
    unittest.main()
