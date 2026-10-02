#!/usr/bin/env python3
"""Host-only signing control-flow tests using fake Flutter/apksigner, NOT native evidence."""
import base64
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import textwrap
import unittest

SCRIPT = Path(__file__).resolve().with_name("build-android.sh")
SECRETS = {
    "ANDROID_KEYSTORE_BASE64": base64.b64encode(b"fixture keystore").decode(),
    "ANDROID_KEYSTORE_PASSWORD": "fixture store password",
    "ANDROID_KEY_ALIAS": "fixture alias",
    "ANDROID_KEY_PASSWORD": "fixture key password",
}


class AndroidSigningTests(unittest.TestCase):
    def test_workflow_signing_request_gate(self):
        workflow = SCRIPT.parents[2] / ".github/workflows/native-builds.yml"
        # Exercise the actual shell gate without requiring a YAML dependency.
        step = workflow.read_text().split("- name: Validate signing request\n", 1)[1]
        gate = textwrap.dedent(step.split("        run: |\n", 1)[1].split("      - uses:", 1)[0])
        cases = [
            ("debug-signed", "pull_request", "refs/pull/1/merge", True),
            ("release-signed", "workflow_dispatch", "refs/heads/main", True),
            ("release-signed", "workflow_dispatch", "refs/heads/feature", False),
            ("release-signed", "workflow_dispatch", "refs/tags/v1.0.0", False),
            ("release-signed", "workflow_call", "refs/heads/main", False),
            ("release-signed", "pull_request_target", "refs/heads/main", False),
            ("release-signed", "push", "refs/tags/v1.0.0", True),
            ("release-signed", "push", "refs/tags/v1.0.0-rc.1", True),
            ("release-signed", "push", "refs/heads/main", False),
            ("release-signed", "push", "refs/heads/v1.0.0", False),
            ("release-signed", "push", "refs/tags/other", False),
            ("release-signed", "pull_request", "refs/tags/v1.0.0", False),
            ("unknown", "push", "refs/tags/v1.0.0", False),
        ]
        for mode, event, ref, allowed in cases:
            with self.subTest(mode=mode, event=event, ref=ref):
                result = subprocess.run(
                    ["bash", "-e", "-c", gate],
                    env=dict(os.environ, MODE=mode, EVENT=event, REF=ref),
                    capture_output=True, text=True,
                )
                self.assertEqual(result.returncode == 0, allowed, result.stderr)

    def run_build(self, mode, secrets=None, fail_build=False, fail_verify=False, fail_resources=False):
        with tempfile.TemporaryDirectory(prefix="yun signing test ") as directory:
            root = Path(directory)
            (root / "bin").mkdir()
            (root / "tmp").mkdir()
            tools = root / "sdk/build-tools/36.0.0"
            tools.mkdir(parents=True)
            flutter = root / "bin/fvm"
            flutter.write_text("""#!/usr/bin/env python3
import os
from pathlib import Path
import sys
assert sys.argv[1:4] == ['flutter', 'build', 'apk']
assert sys.argv[5:] == ['--target-platform', 'android-arm64']
mode = sys.argv[4]
if mode == '--release' and os.environ.get('YUN_ANDROID_RELEASE_SIGNING') == 'true':
    key = Path(os.environ['YUN_ANDROID_KEYSTORE_PATH'])
    assert key.read_bytes() == b'fixture keystore'
    assert key.stat().st_mode & 0o777 == 0o600
    assert key.parent.stat().st_mode & 0o777 == 0o700
    assert os.environ['YUN_ANDROID_RELEASE_SIGNING'] == 'true'
    assert 'ANDROID_KEYSTORE_BASE64' not in os.environ
    assert all(os.environ.get(k) for k in ('ANDROID_KEYSTORE_PASSWORD', 'ANDROID_KEY_ALIAS', 'ANDROID_KEY_PASSWORD'))
else:
    assert mode in ('--debug', '--release')
    assert 'YUN_ANDROID_RELEASE_SIGNING' not in os.environ
    assert not any(k in os.environ for k in ('YUN_ANDROID_KEYSTORE_PATH', 'ANDROID_KEYSTORE_BASE64', 'ANDROID_KEYSTORE_PASSWORD', 'ANDROID_KEY_ALIAS', 'ANDROID_KEY_PASSWORD'))
Path('build-called').touch()
if os.environ.get('FAIL_BUILD') == 'true':
    sys.exit(1)
out = Path('build/app/outputs/flutter-apk')
out.mkdir(parents=True)
(out / ('app' + mode[1:] + '.apk')).write_bytes(b'fake apk')
""")
            flutter.chmod(0o755)
            # The resource checker has its own APK fixture tests. Here, double
            # only that subprocess to verify ordering and fail-closed packaging.
            python = root / "bin/python3"
            python.write_text(f"""#!{sys.executable}
import os
from pathlib import Path
import sys
if len(sys.argv) > 1 and Path(sys.argv[1]).name == 'verify-android-resources.py':
    assert sys.argv[2:] == ['build/app/outputs/flutter-apk/app-release.apk']
    assert Path(sys.argv[2]).read_bytes() == b'fake apk'
    assert not any(k in os.environ for k in ('YUN_ANDROID_KEYSTORE_PATH', 'YUN_ANDROID_RELEASE_SIGNING', 'ANDROID_KEYSTORE_PASSWORD', 'ANDROID_KEY_ALIAS', 'ANDROID_KEY_PASSWORD'))
    if os.environ.get('FAIL_RESOURCES') == 'true':
        sys.exit(1)
    Path('resources-verified').touch()
else:
    os.execv({sys.executable!r}, [{sys.executable!r}] + sys.argv[1:])
""")
            python.chmod(0o755)
            verifier = tools / "apksigner"
            verifier.write_text("#!/bin/sh\n[ -f resources-verified ] || exit 1\n[ \"${FAIL_VERIFY:-}\" != true ]\n")
            verifier.chmod(0o755)
            environment = {k: v for k, v in os.environ.items() if k not in SECRETS}
            environment.update(
                PATH=f"{root / 'bin'}:{os.environ['PATH']}",
                RUNNER_TEMP=str(root / "tmp"),
                ANDROID_SDK_ROOT=str(root / "sdk"),
                GITHUB_ACTIONS="false",
                FAIL_BUILD=str(fail_build).lower(),
                FAIL_VERIFY=str(fail_verify).lower(),
                FAIL_RESOURCES=str(fail_resources).lower(),
            )
            environment.update(secrets or {})
            result = subprocess.run(
                ["bash", str(SCRIPT), mode], cwd=root, env=environment,
                capture_output=True, text=True,
            )
            self.assertEqual(list((root / "tmp").iterdir()), [], "keystore leaked")
            for secret in SECRETS.values():
                self.assertNotIn(secret, result.stdout + result.stderr)
            return result, (root / "build-called").exists(), sorted(
                p.name for directory in (root / "dist", root / "build/release-validation")
                for p in directory.glob("*")
            )

    def test_explicit_debug_evaluation(self):
        result, called, files = self.run_build("debug-signed")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(called)
        self.assertEqual(files, ["yun-android-arm64-debug-signed.apk"])

    def test_release_control_flow_and_cleanup(self):
        result, called, files = self.run_build("release-signed", SECRETS)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(called)
        self.assertEqual(files, ["yun-android-arm64-release-signed.apk"])

    def test_release_validation_without_credentials(self):
        result, called, files = self.run_build("release-validation", SECRETS)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(called)
        self.assertEqual(files, ["yun-android-arm64-release-validation-unsigned.apk"])

    def test_failed_resource_audit_never_packages(self):
        for mode in ("release-validation", "release-signed"):
            with self.subTest(mode=mode):
                result, called, files = self.run_build(mode, SECRETS, fail_resources=True)
                self.assertNotEqual(result.returncode, 0)
                self.assertTrue(called)
                self.assertEqual(files, [])

    def test_missing_each_secret_fails_before_build(self):
        for missing in SECRETS:
            with self.subTest(missing=missing):
                secrets = {k: v for k, v in SECRETS.items() if k != missing}
                result, called, files = self.run_build("release-signed", secrets)
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse(called)
                self.assertEqual(files, [])

    def test_invalid_base64_fails_and_cleans_up(self):
        result, called, files = self.run_build(
            "release-signed", dict(SECRETS, ANDROID_KEYSTORE_BASE64="not base64!")
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(called)
        self.assertEqual(files, [])

    def test_build_or_verification_failure_never_packages(self):
        for failure in ("fail_build", "fail_verify"):
            with self.subTest(failure=failure):
                result, called, files = self.run_build("release-signed", SECRETS, **{failure: True})
                self.assertNotEqual(result.returncode, 0)
                self.assertTrue(called)
                self.assertEqual(files, [])

    def test_unknown_mode_fails(self):
        result, called, files = self.run_build("release")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(called)
        self.assertEqual(files, [])


if __name__ == "__main__":
    unittest.main()
