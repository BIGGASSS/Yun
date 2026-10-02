#!/usr/bin/env python3
"""Fail closed unless a final Yun APK contains all runtime-looked-up media icons.

Usage: python3 scripts/release/verify-android-resources.py FINAL.apk [--aapt2 PATH]
Requires Python 3 and Android SDK build-tools' aapt2 (or the official Google Maven
binary). Discovery: --aapt2, AAPT2, SDK build-tools, then PATH. Nothing is installed
or downloaded by this script. Run on the exact APK that will be distributed,
after shrinking/optimization/signing, not on merged resources or a debug build.

AAPT2 is the authoritative resources.arsc decoder. Its dump provides resource
names, types, IDs and file references; ZIP reads verify the referenced assets.
This deliberately supports direct file drawables only. Resource aliases, flags,
unknown value formats and configurations without a universal API-24 fallback
fail closed rather than attempting to emulate Android's resource resolution.
It verifies packaging, not successful playback or rendering on a device.
"""

import argparse
from collections import Counter
from dataclasses import dataclass, field
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import subprocess
import sys
import zipfile

PACKAGE = "app.yun.yun"
MIN_SDK = 24
REQUIRED_DRAWABLES = tuple("audio_service_" + name for name in (
    "stop", "pause", "play_arrow", "skip_next", "skip_previous",
    "fast_forward", "fast_rewind",
))
PACKAGE_LINE = re.compile(r"Package name=(\S+) id=([0-9a-fA-F]{2})")
TYPE_LINE = re.compile(r"  type (\S+) id=([0-9a-fA-F]{2}) entryCount=(\d+)")
RESOURCE_LINE = re.compile(
    r"    resource (0x[0-9a-fA-F]{8}) (\S+)/(\S+)"
    r"(?: (?:PUBLIC|_PRIVATE_|STAGED|OVERLAYABLE|STAGED_ID=0x[0-9a-fA-F]{8}))*"
)
FILE_VALUE = re.compile(r"      \(([^()]*)\) \(file\) (\S+) type=(PNG|XML)")
# Density selection always provides a fallback; other device/locale qualifiers
# do not. A version-only fallback is safe only when it covers our minimum SDK.
FALLBACK_CONFIG = re.compile(
    r"(?:(?:ldpi|mdpi|tvdpi|hdpi|xhdpi|xxhdpi|xxxhdpi|nodpi|anydpi|\d+dpi)(?:-v(\d+))?|v(\d+))?"
)


class VerificationError(Exception):
    """An APK cannot be proven to contain usable runtime media icon resources."""


@dataclass
class Resource:
    name: str
    resource_id: int
    lines: list = field(default_factory=list)


def find_aapt2(explicit=None):
    """Select a configured tool, or the newest installed SDK build-tools."""
    configured = explicit or os.environ.get("AAPT2")
    if configured:
        candidate = shutil.which(str(configured))
        if not candidate:
            raise VerificationError(f"aapt2 is not executable: {configured}")
        return candidate
    candidates = []
    for variable in ("ANDROID_SDK_ROOT", "ANDROID_HOME"):
        root = os.environ.get(variable)
        if not root:
            continue
        for candidate in (Path(root) / "build-tools").glob("*/aapt2*"):
            if candidate.name not in ("aapt2", "aapt2.exe"):
                continue
            match = re.fullmatch(r"(\d+)\.(\d+)\.(\d+)(?:-(.+))?", candidate.parent.name)
            if match and candidate.is_file() and os.access(candidate, os.X_OK):
                version = tuple(int(part) for part in match.groups()[:3])
                candidates.append((version + (match[4] is None,), str(candidate)))
    if candidates:
        return max(candidates)[1]
    candidate = shutil.which("aapt2")
    if candidate:
        return candidate
    raise VerificationError(
        "aapt2 missing: install Android SDK build-tools and set ANDROID_SDK_ROOT "
        "or pass --aapt2 /path/to/aapt2"
    )


def dump_resources(apk, aapt2):
    try:
        result = subprocess.run(
            [aapt2, "dump", "resources", str(apk)], check=False,
            capture_output=True, text=True, encoding="utf-8", errors="strict",
            env=dict(os.environ, LC_ALL="C", LANG="C"), timeout=120,
        )
    except (OSError, UnicodeError, subprocess.TimeoutExpired) as error:
        raise VerificationError(f"unable to inspect APK with aapt2: {error}") from error
    if result.returncode:
        raise VerificationError(f"aapt2 rejected APK: {result.stderr.strip() or result.returncode}")
    # aapt2 can report parsing problems even if a later operation succeeds.
    if result.stderr.strip():
        raise VerificationError(f"aapt2 reported diagnostics: {result.stderr.strip()}")
    return result.stdout


def parse_resources(dump):
    """Parse AAPT2's package/type/resource headings, never string-pool matches."""
    if not dump.startswith("Binary APK\n"):
        raise VerificationError("unexpected aapt2 dump format (expected Binary APK)")
    resources = {}
    ids = set()
    packages = set()
    current_package = None
    current_type = None
    current_resource = None
    type_count = 0
    expected_count = 0

    def check_type_count():
        if current_type is not None and type_count != expected_count:
            raise VerificationError("incomplete aapt2 resource listing (entryCount mismatch)")

    for line in dump.splitlines()[1:]:
        if line.startswith("Package "):
            check_type_count()
            match = PACKAGE_LINE.fullmatch(line)
            if not match or match[1] in packages or int(match[2], 16) == 0:
                raise VerificationError(f"invalid or duplicate resource package: {line}")
            packages.add(match[1])
            current_package = (match[1], int(match[2], 16))
            current_type = current_resource = None
        elif line.startswith("  type "):
            check_type_count()
            match = TYPE_LINE.fullmatch(line)
            if not match or current_package is None or int(match[2], 16) == 0:
                raise VerificationError(f"invalid resource type: {line}")
            current_type = (match[1], int(match[2], 16))
            current_resource = None
            type_count, expected_count = 0, int(match[3])
        elif line.startswith("    resource "):
            match = RESOURCE_LINE.fullmatch(line)
            if not match or current_package is None or current_type is None:
                raise VerificationError(f"invalid resource entry: {line}")
            resource_id = int(match[1], 16)
            if (resource_id == 0 or resource_id >> 24 != current_package[1]
                    or (resource_id >> 16) & 0xff != current_type[1]
                    or match[2] != current_type[0]):
                raise VerificationError(f"invalid resource ID/type: {line}")
            key = (current_package[0], match[2] + "/" + match[3])
            if key in resources or resource_id in ids:
                raise VerificationError(f"duplicate resource name or ID: {line}")
            ids.add(resource_id)
            current_resource = Resource(key[1], resource_id)
            resources[key] = current_resource
            type_count += 1
        elif current_resource is not None:
            current_resource.lines.append(line)
        elif line.strip():
            raise VerificationError(f"unsupported aapt2 table structure: {line}")
    check_type_count()
    if PACKAGE not in packages:
        raise VerificationError(f"missing resource package {PACKAGE}")
    missing = [name for name in REQUIRED_DRAWABLES if (PACKAGE, "drawable/" + name) not in resources]
    if missing:
        raise VerificationError("missing runtime drawable resources: " + ", ".join(missing))
    return [resources[(PACKAGE, "drawable/" + name)] for name in REQUIRED_DRAWABLES]


def has_fallback(config):
    match = FALLBACK_CONFIG.fullmatch(config)
    return match is not None and all(int(version) <= MIN_SDK for version in match.groups() if version)


def file_references(resource):
    files = []
    configs = set()
    fallback = False
    disabled = False
    for line in resource.lines:
        if not line.strip():
            continue
        if line == "      Flag disabled values:" and not disabled:
            disabled = True
            continue
        match = FILE_VALUE.fullmatch(line)
        if disabled or not match:
            raise VerificationError(f"{resource.name}: unsupported value/alias/flag: {line.strip()}")
        config, path = match[1], match[2]
        if config in configs:
            raise VerificationError(f"{resource.name}: duplicate configuration {config!r}")
        configs.add(config)
        fallback = fallback or has_fallback(config)
        parts = PurePosixPath(path).parts
        if (not path.startswith("res/") or "\\" in path or ".." in parts
                or "." in path.split("/") or "//" in path or path.endswith("/")):
            raise VerificationError(f"{resource.name}: unsafe asset path {path!r}")
        files.append(path)
    if not files:
        raise VerificationError(f"{resource.name}: no file-backed drawable values")
    if not fallback:
        raise VerificationError(f"{resource.name}: no universal fallback for API {MIN_SDK}")
    return files


def verify_apk(apk, aapt2):
    apk = Path(apk).resolve()
    if not apk.is_file():
        raise VerificationError(f"APK does not exist: {apk}")
    try:
        with zipfile.ZipFile(apk) as archive:
            counts = Counter(info.filename for info in archive.infolist())
            if counts["resources.arsc"] != 1 or archive.getinfo("resources.arsc").file_size == 0:
                raise VerificationError("APK must contain exactly one nonempty resources.arsc")
            # Reading validates the ZIP entry CRC as well as the table aapt2 parses.
            archive.read("resources.arsc")
            resources = parse_resources(dump_resources(apk, aapt2))
            checked = set()
            for resource in resources:
                for path in file_references(resource):
                    if counts[path] != 1:
                        raise VerificationError(f"{resource.name}: missing or duplicate APK asset {path}")
                    if path not in checked:
                        if not archive.read(path):
                            raise VerificationError(f"{resource.name}: empty APK asset {path}")
                        checked.add(path)
            return resources, len(checked)
    except (OSError, zipfile.BadZipFile, RuntimeError, NotImplementedError) as error:
        raise VerificationError(f"cannot read APK: {error}") from error


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("apk", type=Path)
    parser.add_argument("--aapt2", help="Android SDK aapt2 binary (overrides auto-discovery)")
    args = parser.parse_args(argv)
    try:
        resources, asset_count = verify_apk(args.apk, find_aapt2(args.aapt2))
    except VerificationError as error:
        print(f"Android media resource verification FAILED: {error}", file=sys.stderr)
        return 1
    print(f"Verified {len(resources)} runtime media drawables and {asset_count} APK assets in {args.apk}")
    for resource in resources:
        print(f"  0x{resource.resource_id:08x} {resource.name}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
