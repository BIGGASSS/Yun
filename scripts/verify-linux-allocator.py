#!/usr/bin/env python3
"""Check the built runner's allocator exports/dependencies (requires binutils).

This checks executable linkage, not process-wide allocator use by every library.
For --expect mimalloc, require the core allocation overrides exported by the
supported static bundle. Its mi_* symbols may be hidden. Generic overrides alone
cannot establish mimalloc identity; that must come from trusted build inputs.
"""
import argparse
from pathlib import Path
import subprocess
import sys


CORE_OVERRIDES = {"malloc", "calloc", "realloc", "free"}
SYSTEM_OVERRIDES = {"malloc", "calloc", "realloc", "free", "aligned_alloc",
                    "posix_memalign", "memalign", "valloc", "pvalloc",
                    "malloc_usable_size"}


def verify(binary, expected):
    output = subprocess.check_output(
        ["nm", "--dynamic", "--defined-only", str(binary)], text=True,
    )
    symbols = {line.split()[-1].split("@")[0] for line in output.splitlines() if line.split()}
    dependencies = subprocess.check_output(["readelf", "--dynamic", str(binary)], text=True)
    overrides = symbols & SYSTEM_OVERRIDES
    mimalloc = {symbol for symbol in symbols if symbol.startswith("mi_")}
    if expected == "system":
        if overrides or mimalloc or "mimalloc" in dependencies.lower():
            raise ValueError("system allocator expected, but runner defines allocator overrides "
                             "or links mimalloc")
    else:
        missing = CORE_OVERRIDES - symbols
        if missing:
            raise ValueError("static allocator overrides expected, but exports are missing: "
                             + ", ".join(sorted(missing)))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", required=True, type=Path)
    parser.add_argument("--expect", required=True, choices=("system", "mimalloc"))
    args = parser.parse_args()
    try:
        verify(args.binary, args.expect)
    except (OSError, subprocess.CalledProcessError, ValueError) as error:
        print(f"Linux allocator verification failed: {error}", file=sys.stderr)
        return 1
    if args.expect == "mimalloc":
        print("Linux runner core allocator overrides verified; "
              "mimalloc identity depends on trusted build inputs (mi_* may be hidden)")
    else:
        print("Linux runner system allocator linkage check passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
