#!/usr/bin/env python3
"""Offline allocator integration fixtures: real project CMake, no Flutter/network.

Requires CMake, Ninja, a C++ compiler, nm and readelf. Only temporary directories
are built. The plugin fixture models media_kit_libs_linux's allocator export/target
contract, including a static object with hidden mi_* symbols.
"""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class LinuxAllocatorTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="yun allocator ")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.source = self.root / "linux"
        self.build = self.root / "build"
        self.source.mkdir()
        shutil.copy2(ROOT / "linux/CMakeLists.txt", self.source / "CMakeLists.txt")
        self.environment = dict(os.environ)
        self.environment.pop("YUN_USE_MIMALLOC", None)
        self.write("modules/FindPkgConfig.cmake", "function(pkg_check_modules)\nendfunction()\n")
        self.write("flutter/CMakeLists.txt", """
add_custom_target(flutter_assemble)
set(PROJECT_BUILD_DIR "${CMAKE_BINARY_DIR}/" PARENT_SCOPE)
set(FLUTTER_ICU_DATA_FILE "${CMAKE_BINARY_DIR}/icudtl.dat" PARENT_SCOPE)
set(FLUTTER_LIBRARY "${CMAKE_BINARY_DIR}/libflutter.so" PARENT_SCOPE)
set(AOT_LIBRARY "${CMAKE_BINARY_DIR}/libapp.so" PARENT_SCOPE)
""")
        self.write("runner/CMakeLists.txt", "add_executable(${BINARY_NAME} main.cc)\n")
        self.write("runner/main.cc", "int main() { return 0; }\n")
        self.write("flutter/mimalloc.cc", 'extern "C" int mi_yun_fixture() { return 42; }\n')
        self.write("flutter/generated_plugins.cmake", """
# A static output does not exist at configure time: the target produces it.
if(NOT FIXTURE_MISSING_MIMALLOC)
  if(MIMALLOC_USE_STATIC_LIBS)
    set(MIMALLOC_LIB "${CMAKE_BINARY_DIR}/mimalloc.o" CACHE INTERNAL "")
    add_custom_command(OUTPUT "${MIMALLOC_LIB}"
      COMMAND "${CMAKE_CXX_COMPILER}" -c
        "${CMAKE_CURRENT_SOURCE_DIR}/flutter/mimalloc.cc" -o "${MIMALLOC_LIB}")
    add_custom_target(MIMALLOC_TARGET ALL DEPENDS "${MIMALLOC_LIB}")
  else()
    # Installed shared mimalloc must not override the OFF selection.
    set(MIMALLOC_LIB "/fixture/system/libmimalloc.so" CACHE INTERNAL "")
  endif()
endif()
unset(MIMALLOC_USE_STATIC_LIBS CACHE)
""")

    def write(self, name, text):
        path = self.source / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)

    def configure(self, *options, env=None, success=True):
        environment = dict(self.environment)
        if env is not None:
            environment["YUN_USE_MIMALLOC"] = env
        result = subprocess.run([
            "cmake", "-S", str(self.source), "-B", str(self.build), "-G", "Ninja",
            f"-DCMAKE_MODULE_PATH={self.source / 'modules'}", *options,
        ], env=environment, text=True, capture_output=True)
        self.assertEqual(result.returncode == 0, success, result.stdout + result.stderr)
        return result.stdout + result.stderr

    def assert_linkage(self, mimalloc):
        result = subprocess.run(["cmake", "--build", str(self.build), "--target", "yun"],
                                text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        binary = self.build / "intermediates_do_not_run/yun"
        symbols = subprocess.check_output(["nm", "--defined-only", str(binary)], text=True)
        self.assertEqual("mi_yun_fixture" in symbols, mimalloc)
        ninja = (self.build / "build.ninja").read_text()
        self.assertEqual("build MIMALLOC_TARGET:" in ninja, mimalloc)
        cache = (self.build / "CMakeCache.txt").read_text()
        self.assertIn(f"YUN_USE_MIMALLOC:BOOL={'ON' if mimalloc else 'OFF'}", cache)

    def test_default_uses_system_even_when_plugin_discovers_shared_mimalloc(self):
        self.assertIn("Yun allocator: system", self.configure())
        self.assert_linkage(False)
        self.assertFalse((self.build / "mimalloc.o").exists())

    def test_environment_opt_in_links_generated_object_and_dependency(self):
        self.assertIn("Yun allocator: media_kit mimalloc", self.configure(env="ON"))
        self.assert_linkage(True)

    def test_cmake_option_overrides_environment_default(self):
        self.configure("-DYUN_USE_MIMALLOC=ON", env="OFF")
        self.assert_linkage(True)

    def test_cache_wins_until_explicitly_reset_in_both_directions(self):
        self.configure(env="ON")
        self.assert_linkage(True)
        self.configure(env="OFF")
        self.assert_linkage(True)
        self.configure("-DYUN_USE_MIMALLOC=OFF")
        self.assert_linkage(False)
        self.configure(env="ON")
        self.assert_linkage(False)
        self.configure("-UYUN_USE_MIMALLOC", env="ON")
        self.assert_linkage(True)

    def test_invalid_environment_fails_even_with_cached_option(self):
        self.configure()
        for value in ("", "yes", "on", "1", "OFF;ON", "typo"):
            with self.subTest(value=value):
                output = self.configure(env=value, success=False)
                self.assertIn("environment variable must be ON or OFF", output)

    def test_explicit_opt_in_without_plugin_export_fails_not_stale_cache(self):
        stale = self.root / "stale-mimalloc.o"
        stale.touch()
        output = self.configure("-DYUN_USE_MIMALLOC=ON", "-DFIXTURE_MISSING_MIMALLOC=ON",
                                f"-DMIMALLOC_LIB={stale}", success=False)
        self.assertIn("requires media_kit_libs_linux to provide mimalloc", output)

    def test_explicit_opt_in_with_missing_artifact_and_no_target_fails(self):
        self.write("flutter/generated_plugins.cmake",
                   'set(MIMALLOC_LIB "/missing/mimalloc.o" CACHE INTERNAL "")\n')
        output = self.configure(env="ON", success=False)
        self.assertIn("requires media_kit_libs_linux to provide mimalloc", output)

    def test_default_does_not_require_mimalloc(self):
        self.configure("-DFIXTURE_MISSING_MIMALLOC=ON")
        self.assert_linkage(False)

    def verify_binary(self, binary, expected, success):
        result = subprocess.run([
            "python3", str(ROOT / "scripts/verify-linux-allocator.py"),
            "--binary", str(binary), "--expect", expected,
        ], text=True, capture_output=True)
        self.assertEqual(result.returncode == 0, success, result.stdout + result.stderr)
        return result.stdout + result.stderr

    def test_binary_verifier_accepts_static_overrides_with_hidden_mi_symbols(self):
        self.configure()
        self.assert_linkage(False)
        binary = self.build / "intermediates_do_not_run/yun"
        self.verify_binary(binary, "system", True)
        self.verify_binary(binary, "mimalloc", False)
        # Fixture exports only: this executable is inspected, never run.
        self.write("flutter/mimalloc.cc", '''
#include <cstddef>
extern "C" __attribute__((visibility("hidden")))
int mi_yun_fixture() { return 42; }
extern "C" __attribute__((visibility("hidden")))
void* mi_malloc(std::size_t) { return nullptr; }
extern "C" void* malloc(std::size_t size) { return mi_malloc(size); }
extern "C" void* calloc(std::size_t, std::size_t) { return nullptr; }
extern "C" void* realloc(void*, std::size_t) { return nullptr; }
extern "C" void free(void*) {}
''')
        self.write("runner/CMakeLists.txt", '''
add_executable(${BINARY_NAME} main.cc)
target_link_options(${BINARY_NAME} PRIVATE -rdynamic)
''')
        self.configure("-DYUN_USE_MIMALLOC=ON")
        self.assert_linkage(True)
        symbols = subprocess.check_output(["nm", "--defined-only", str(binary)], text=True)
        exports = subprocess.check_output(
            ["nm", "--dynamic", "--defined-only", str(binary)], text=True)
        self.assertIn(" mi_malloc\n", symbols)
        self.assertNotIn(" mi_", exports)
        for name in ("malloc", "calloc", "realloc", "free"):
            self.assertIn(f" {name}\n", exports)
        self.verify_binary(binary, "system", False)
        output = self.verify_binary(binary, "mimalloc", True)
        self.assertIn("mimalloc identity depends on trusted build inputs", output)
        self.verify_binary(self.root / "nonexistent", "system", False)

    def test_binary_verifier_requires_all_core_overrides_not_allocator_identity(self):
        # These generic stubs are NOT mimalloc. The verifier can establish only
        # the override contract, not the implementation's identity.
        overrides = {
            "malloc": 'extern "C" void* malloc(std::size_t) { return nullptr; }',
            "calloc": 'extern "C" void* calloc(std::size_t, std::size_t) { return nullptr; }',
            "realloc": 'extern "C" void* realloc(void*, std::size_t) { return nullptr; }',
            "free": 'extern "C" void free(void*) {}',
        }
        self.write("runner/CMakeLists.txt", '''
add_executable(${BINARY_NAME} main.cc)
target_link_options(${BINARY_NAME} PRIVATE -rdynamic)
''')
        self.configure()
        binary = self.build / "intermediates_do_not_run/yun"
        for missing in (None, *overrides):
            with self.subTest(missing=missing):
                self.write("runner/main.cc", "#include <cstddef>\n" + "\n".join(
                    code for name, code in overrides.items() if name != missing
                ) + "\nint main() { return 0; }\n")
                self.assert_linkage(False)
                self.verify_binary(binary, "system", False)
                output = self.verify_binary(binary, "mimalloc", missing is None)
                if missing is None:
                    self.assertIn("mimalloc identity depends on trusted build inputs", output)
                else:
                    self.assertIn(f"exports are missing: {missing}", output)

    def test_binary_verifier_rejects_shared_mimalloc_dependency(self):
        self.write("runner/CMakeLists.txt", '''
add_library(mimalloc SHARED ../flutter/mimalloc.cc)
add_executable(${BINARY_NAME} main.cc)
target_link_libraries(${BINARY_NAME} PRIVATE mimalloc)
''')
        self.write("runner/main.cc", '''
extern "C" int mi_yun_fixture();
int main() { return mi_yun_fixture(); }
''')
        self.configure()
        subprocess.run(["cmake", "--build", str(self.build), "--target", "yun"],
                       check=True, capture_output=True)
        self.verify_binary(self.build / "intermediates_do_not_run/yun", "system", False)


if __name__ == "__main__":
    unittest.main()
