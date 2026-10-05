#!/usr/bin/env python3
"""Guard Linux's Dart-only tray plugin while preserving native macOS/Windows trays."""

import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parent.parent
NATIVE_REFS = re.compile(r"tray_manager|TrayManagerPlugin", re.IGNORECASE)
FORBIDDEN_DEPS = re.compile(r"tray_manager|ayatana|appindicator", re.IGNORECASE)


class VerificationError(Exception):
    pass


def require(condition, message):
    if not condition:
        raise VerificationError(message)


def verify_generated_files(root):
    metadata_path = root / ".flutter-plugins-dependencies"
    require(metadata_path.is_file(), f"Missing {metadata_path}; run fvm flutter pub get first")
    metadata = json.loads(metadata_path.read_text(encoding="utf-8"))
    require(isinstance(metadata, dict) and isinstance(metadata.get("plugins"), dict),
            f"{metadata_path}: expected a plugins object")
    for platform in ("linux", "macos", "windows"):
        entries = metadata["plugins"].get(platform)
        require(isinstance(entries, list) and all(isinstance(p, dict) for p in entries),
                f"{metadata_path}: expected plugins.{platform} to be a list of objects")
        if platform == "linux":
            require(not any(p.get("name") == "tray_manager" for p in entries),
                    "plugins.linux must omit upstream tray_manager")
        name = "yun_tray_manager_linux" if platform == "linux" else "tray_manager"
        matches = [p for p in entries if p.get("name") == name]
        require(len(matches) == 1, f"plugins.{platform} must include exactly one {name}")
        for field, expected in (("native_build", platform != "linux"), ("dev_dependency", False)):
            require(matches[0].get(field) is expected,
                    f"plugins.{platform}.{name}: {field} must be {str(expected).lower()}")

    for filename in ("generated_plugins.cmake", "generated_plugin_registrant.cc"):
        path = root / "linux/flutter" / filename
        require(path.is_file(), f"Missing {path}; run fvm flutter pub get first")
        require(not NATIVE_REFS.search(path.read_text(encoding="utf-8")),
                f"{path}: found native tray_manager / TrayManagerPlugin reference")


def is_elf(path):
    with path.open("rb") as stream:
        return stream.read(4) == b"\x7fELF"


def run_tool(command):
    result = subprocess.run(command, capture_output=True, text=True,
                            env=dict(os.environ, LC_ALL="C"))
    output = result.stdout + result.stderr
    require(result.returncode == 0,
            f"{command[0]} failed for {command[-1]} (exit {result.returncode}): {output.strip()}")
    return output


def verify_bundle(bundle):
    bundle = bundle.expanduser().resolve()
    executable = bundle / "yun"
    require(executable.is_file() and os.access(executable, os.X_OK),
            f"{bundle}: missing executable yun (or not executable)")
    require((bundle / "lib").is_dir(), f"{bundle}: missing lib directory")
    require(is_elf(executable), f"{executable}: expected a built ELF executable, not a script")

    # Inspect all ELF files, not just *.so: versioned/nested libraries and native assets count.
    elf_files = [executable]
    for path in sorted(bundle.rglob("*")):
        require(path.name.lower() != "libtray_manager_plugin.so",
                f"Forbidden bundled tray library: {path}")
        if path != executable and path.is_file() and is_elf(path):
            elf_files.append(path)
    for path in elf_files:
        dynamic = run_tool(["readelf", "-d", "-W", str(path)])
        for line in dynamic.splitlines():
            require(not ("(NEEDED)" in line and FORBIDDEN_DEPS.search(line)),
                    f"{path}: forbidden ELF dependency: {line.strip()}")

    # Never execute bundle files directly or run ldd on arbitrary libraries.
    # Only the executable checked above (including readelf) is passed to ldd.
    linkage = run_tool(["ldd", str(executable)])
    require(not re.search(r"\bnot found\b", linkage, re.IGNORECASE),
            f"{executable}: unresolved ldd dependency:\n{linkage.strip()}")
    for line in linkage.splitlines():
        words = line.split()
        if words:
            require(not FORBIDDEN_DEPS.search(Path(words[0]).name),
                    f"{executable}: forbidden ldd dependency: {line.strip()}")
    return len(elf_files)


def main():
    parser = argparse.ArgumentParser(
        description="Verify Linux native tray linkage is removed after fvm flutter pub get.",
        epilog="Example: %(prog)s --bundle build/linux/x64/release/bundle. "
               "Bundle checks require readelf (binutils) and ldd on Linux.")
    parser.add_argument("--bundle", type=Path, metavar="PATH",
                        help="also inspect a real built Linux bundle (yun and lib/)")
    args = parser.parse_args()
    try:
        verify_generated_files(ROOT)
        count = verify_bundle(args.bundle) if args.bundle is not None else None
    except (VerificationError, OSError, UnicodeError, json.JSONDecodeError) as error:
        print(f"Linux tray linkage verification failed: {error}", file=sys.stderr)
        return 1
    detail = f"; inspected {count} bundled ELF files" if count is not None else ""
    print(f"Linux tray linkage verified (metadata and generated files{detail}).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
