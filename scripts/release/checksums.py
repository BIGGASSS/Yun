#!/usr/bin/env python3
"""Hash final release packages, not mutable inventory files, on every runner OS."""
from hashlib import sha256
from pathlib import Path

root = Path("dist")
archives = sorted(p for p in root.iterdir() if p.is_file() and p.name.endswith(
    (".tar.gz", ".dmg", ".zip", ".apk", ".exe", ".AppImage", ".deb")
))
if not archives:
    raise SystemExit("No release archives found")
lines = []
for path in archives:
    digest = sha256()
    with path.open("rb") as archive:
        for chunk in iter(lambda: archive.read(1024 * 1024), b""):
            digest.update(chunk)
    lines.append(f"{digest.hexdigest()}  {path.name}\n")
(root / "SHA256SUMS").write_text("".join(lines), encoding="utf-8")
