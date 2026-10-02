#!/usr/bin/env python3
"""Offline workflow security regression tests (stdlib only; no GitHub API calls).

These deliberately check the checked-in YAML's text/indentation, not arbitrary YAML.
Security-sensitive restructuring must update these assertions explicitly. Remote
secret scope, environment protection and branch rules still need operator checks.
"""
import hashlib
import os
from pathlib import Path
import re
import subprocess
import tempfile
import textwrap
import unittest

ROOT = Path(__file__).resolve().parents[2]
GITHUB = ROOT / ".github"
WORKFLOWS = GITHUB / "workflows"
SIGNING_SECRETS = (
    "ANDROID_KEYSTORE_BASE64", "ANDROID_KEYSTORE_PASSWORD",
    "ANDROID_KEY_ALIAS", "ANDROID_KEY_PASSWORD",
)
SIGNING_GUARD = """
inputs.android_signing == 'debug-signed' ||
(inputs.android_signing == 'release-signed' &&
((github.event_name == 'workflow_dispatch' && github.ref == 'refs/heads/main') ||
(github.event_name == 'push' && startsWith(github.ref, 'refs/tags/v'))))
"""


def blocks(text, header):
    """Yield exact headers and their indented bodies."""
    lines = text.splitlines(keepends=True)
    indent = len(header) - len(header.lstrip())
    for start, line in enumerate(lines):
        if line.rstrip() != header:
            continue
        end = start + 1
        while end < len(lines):
            line = lines[end]
            if line.strip() and len(line) - len(line.lstrip()) <= indent:
                break
            end += 1
        yield "".join(lines[start:end])


def block(text, header):
    """Require a unique security-sensitive block."""
    matches = list(blocks(text, header))
    if len(matches) != 1:
        raise AssertionError(f"Expected one header: {header!r}; found {len(matches)}")
    return matches[0]


def shell(step):
    return textwrap.dedent(step.split("        run: |\n", 1)[1])


def compact(text):
    return " ".join(text.split())


class WorkflowPolicyTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.files = {
            path.relative_to(ROOT).as_posix(): path.read_text()
            for path in GITHUB.rglob("*") if path.suffix in (".yml", ".yaml")
        }
        cls.native = (WORKFLOWS / "native-builds.yml").read_text()
        cls.android = block(cls.native, "  android:")

    def test_pr_android_build_audits_optimized_release_resources(self):
        step = block(self.android, "      - name: Verify optimized release APK media resources without signing")
        self.assertIn("        if: inputs.android_signing == 'debug-signed'\n", step)
        self.assertIn("        run: bash scripts/release/build-android.sh release-validation\n", step)
        self.assertNotIn("secrets.", step)
        upload = block(self.android, "      - name: Preserve verified unsigned release APK for inspection")
        self.assertIn("        if: inputs.android_signing == 'debug-signed'\n", upload)
        self.assertIn("          name: yun-android-arm64-release-validation-unsigned\n", upload)
        self.assertIn("          path: build/release-validation/yun-android-arm64-release-validation-unsigned.apk\n", upload)
        self.assertLess(self.android.index(step), self.android.index(upload))
        sdk_tests = block(self.android, "      - name: Resource verifier regressions with installed Android SDK")
        self.assertIn("        run: python3 scripts/release/test-android-resources.py\n", sdk_tests)
        self.assertLess(self.android.index(step), self.android.index(sdk_tests))
        # Keep the actual release shrinker active; a debug build cannot catch
        # removal of icon names supplied only by Dart at runtime.
        gradle = (ROOT / "android/app/build.gradle.kts").read_text()
        release = block(gradle, "        release {")
        self.assertIn("            isMinifyEnabled = true\n", release)
        self.assertIn("            isShrinkResources = true\n", release)
        self.assertIn("python3 scripts/release/test-android-resources.py", self.files[".github/workflows/ci.yml"])

    def test_every_external_use_is_sha_pinned_with_ref_comment(self):
        count = 0
        for path, text in self.files.items():
            for match in re.finditer(r"(?m)^\s*(?:- )?uses:\s*([^\n]+)$", text):
                value = match[1].strip()
                with self.subTest(path=path, use=value):
                    if value.startswith("./"):
                        self.assertTrue((ROOT / value.split()[0]).exists())
                    else:
                        self.assertRegex(value, r"^[\w.-]+/[\w./-]+@[0-9a-f]{40} +# +\S.*$")
                        count += 1
        self.assertGreater(count, 0)

    def test_vendored_flutter_sdk_provenance_and_license(self):
        path = ".github/actions/flutter-sdk/action.yml"
        # Explicitly require the vendor to participate in the all-YAML pin scan.
        self.assertIn(path, self.files)
        action = self.files[path]
        vendor = ROOT / ".github/actions/flutter-sdk"
        provenance = (vendor / "UPSTREAM.md").read_text()
        commit = re.search(r"(?m)^Upstream commit: `([0-9a-f]{40})`", provenance)
        self.assertIsNotNone(commit)
        records = re.findall(
            r"(?m)^\| `([^`]+)` \| `([^`]+)` \| `([0-9a-f]{64})` \|$",
            provenance,
        )
        self.assertEqual([(source, local) for source, local, _ in records],
                         [("action.yaml", "action.yml"), ("setup.sh", "setup.sh"),
                          ("LICENSE", "LICENSE")])
        # Undo only the documented nested-pin patch. This permits Dependabot cache
        # updates while detecting any other upstream content changes offline.
        original_action, patches = re.subn(
            r"(?m)^(      uses: actions/cache)@[0-9a-f]{40} +# +\S[^\n]*$",
            r"\1@v5", action,
        )
        self.assertEqual(patches, 2)
        for source, local, digest in records:
            with self.subTest(file=local):
                self.assertIn(
                    f"https://github.com/subosito/flutter-action/blob/{commit[1]}/{source}",
                    provenance,
                )
                contents = original_action.encode() if local == "action.yml" else (vendor / local).read_bytes()
                self.assertEqual(hashlib.sha256(contents).hexdigest(), digest)
        license_text = (vendor / "LICENSE").read_text()
        self.assertIn("The MIT License (MIT)", license_text)
        self.assertIn("Copyright (c) 2019 Alif Rachmawadi", license_text)
        self.assertTrue(os.access(vendor / "setup.sh", os.X_OK))
        self.assertIn('$GITHUB_ACTION_PATH/setup.sh', action)

    def test_local_flutter_bootstrap_uses_vendored_sdk_before_fvm(self):
        bootstrap = self.files[".github/actions/flutter/action.yml"]
        sdk = block(bootstrap, "    - uses: ./.github/actions/flutter-sdk")
        self.assertIn('json.load(open(".fvmrc"))["flutter"]', bootstrap)
        self.assertIn("        flutter-version: ${{ steps.version.outputs.version }}\n", sdk)
        self.assertIn("        channel: stable\n", sdk)
        self.assertIn("        cache: true\n", sdk)
        self.assertLess(bootstrap.index(sdk), bootstrap.index("dart pub global activate fvm 4.3.1"))
        self.assertIn("dart pub global run fvm:main install --skip-pub-get", bootstrap)
        for path, text in self.files.items():
            self.assertNotRegex(text, r"uses:\s*subosito/flutter-action@", path)
            if path.startswith(".github/workflows/"):
                self.assertNotIn("uses: ./.github/actions/flutter-sdk", text, path)

    def test_every_checkout_disables_persisted_credentials(self):
        count = 0
        for path, text in self.files.items():
            for line in sorted(set(text.splitlines())):
                if re.search(r"uses:\s*actions/checkout@", line):
                    with self.subTest(path=path, checkout=line):
                        # Current checkouts are standalone steps, deliberately fail closed.
                        self.assertIn("- uses:", line)
                        for checkout in blocks(text, line):
                            self.assertRegex(checkout, r"(?m)^ +with:\n +persist-credentials: false$")
                            self.assertEqual(checkout.count("persist-credentials:"), 1)
                            count += 1
        self.assertGreater(count, 0)

    def test_only_explicit_signing_secret_contract_and_consumer(self):
        signed = block(self.android, "      - name: Build and verify release-signed APK (no fallback)")
        self.assertIn("        if: inputs.android_signing == 'release-signed'\n", signed)
        self.assertIn("        run: bash scripts/release/build-android.sh release-signed\n", signed)
        for name in SIGNING_SECRETS:
            self.assertIn(f"          {name}: ${{{{ secrets.{name} }}}}\n", signed)
        declaration = "    secrets:\n" + "".join(
            f"      {name}:\n        required: false\n" for name in SIGNING_SECRETS
        )
        call = block(self.native, "  workflow_call:")
        self.assertEqual(block(call, "    secrets:"), declaration)
        allowed = {".github/workflows/native-builds.yml": (declaration, signed)}
        for filename in ("tag-release.yml", "release.yml"):
            path = f".github/workflows/{filename}"
            clients = block(self.files[path], "  clients:")
            self.assertIn("    uses: ./.github/workflows/native-builds.yml\n", clients)
            mapping = "    secrets:\n"
            for name in SIGNING_SECRETS:
                expression = f"secrets.{name}" if filename == "tag-release.yml" else (
                    f"inputs.android_signing == 'release-signed' && secrets.{name} || ''"
                )
                mapping += f"      {name}: ${{{{ {expression} }}}}\n"
            self.assertEqual(block(clients, "    secrets:"), mapping)
            allowed[path] = (mapping,)
        for path, text in self.files.items():
            with self.subTest(path=path):
                remainder = text
                for permitted in allowed.get(path, ()):
                    self.assertEqual(remainder.count(permitted), 1)
                    remainder = remainder.replace(permitted, "", 1)
                code = "\n".join(line for line in remainder.splitlines()
                                 if not line.lstrip().startswith("#"))
                self.assertNotRegex(code, r"(?m)^\s*(?:- )?secrets:")
                self.assertNotRegex(code, r"\bsecrets\s*[.\[]")
                for name in SIGNING_SECRETS:
                    self.assertNotIn(name, code)
        self.assertEqual(len(re.findall(r"\bsecrets\.", signed)), len(SIGNING_SECRETS))

    def test_android_job_guards_environment_before_any_steps(self):
        guard = block(self.android, "    if: >-").split("\n", 1)[1]
        self.assertEqual(compact(guard), compact(SIGNING_GUARD))
        environment = (
            "    environment: ${{ inputs.android_signing == 'release-signed' "
            "&& 'release-signing' || 'native-evaluation' }}\n"
        )
        self.assertIn(environment, self.android)
        self.assertEqual(self.android.count("    environment:"), 1)
        self.assertLess(self.android.index("    if:"), self.android.index(environment))
        for path, text in self.files.items():
            remainder = text.replace(environment, "") if path.endswith("/native-builds.yml") else text
            self.assertNotRegex(remainder, r"(?m)^\s*environment:.*release-signing", path)

    def test_shell_request_guard_matches_policy(self):
        step = block(self.android, "      - name: Validate signing request")
        for name, expression in (("MODE", "inputs.android_signing"),
                                 ("EVENT", "github.event_name"), ("REF", "github.ref")):
            self.assertIn(f"          {name}: ${{{{ {expression} }}}}\n", step)
        gate = shell(step)
        # Include lookalikes and hostile event/ref combinations, without network calls.
        for mode in ("debug-signed", "release-signed", "unknown", ""):
            for event in ("workflow_dispatch", "push", "pull_request", "pull_request_target", "workflow_call"):
                for ref in ("refs/heads/main", "refs/heads/main-other", "refs/heads/v1",
                            "refs/tags/v1.2.3", "refs/tags/other", "refs/pull/1/merge", ""):
                    allowed = mode == "debug-signed" or (
                        mode == "release-signed" and (
                            (event == "workflow_dispatch" and ref == "refs/heads/main") or
                            (event == "push" and ref.startswith("refs/tags/v"))
                        )
                    )
                    with self.subTest(mode=mode, event=event, ref=ref):
                        result = subprocess.run(
                            ["bash", "-e", "-c", gate], capture_output=True, text=True,
                            env=dict(os.environ, MODE=mode, EVENT=event, REF=ref),
                        )
                        self.assertEqual(result.returncode == 0, allowed, result.stderr)

    def test_signed_source_checks_main_ancestry_before_build_tools(self):
        checkout_header = next(line for line in self.android.splitlines() if "- uses: actions/checkout@" in line)
        self.assertIn("          fetch-depth: 0\n", block(self.android, checkout_header))
        ancestry = block(self.android, "      - name: Verify signed source is on main")
        self.assertIn("        if: inputs.android_signing == 'release-signed'\n", ancestry)
        gate = shell(ancestry)
        self.assertIn("git fetch --no-tags origin main:refs/remotes/origin/main\n", gate)
        self.assertIn("git merge-base --is-ancestor HEAD refs/remotes/origin/main", gate)
        self.assertLess(self.android.index(checkout_header), self.android.index(ancestry))
        self.assertLess(self.android.index(ancestry), self.android.index("- uses: actions/setup-java@"))
        self.assertLess(self.android.index(ancestry), self.android.index("- uses: ./.github/actions/flutter"))
        self.assertLess(self.android.index(ancestry), self.android.index("secrets.ANDROID_"))
        # Execute the actual gate: fetch failures and divergent commits must fail closed.
        with tempfile.TemporaryDirectory(prefix="yun-policy-") as directory:
            root = Path(directory)
            git = root / "git"
            git.write_text("""#!/bin/sh
printf '%s\\n' "$*" >> "$GIT_LOG"
case "$1" in
  fetch) exit "$FETCH_STATUS" ;;
  merge-base) exit "$ANCESTOR_STATUS" ;;
  *) exit 99 ;;
esac
""")
            git.chmod(0o755)
            for fetch_status, ancestor_status in ((0, 0), (1, 0), (0, 1), (0, 128)):
                with self.subTest(fetch=fetch_status, ancestor=ancestor_status):
                    log = root / "git.log"
                    log.write_text("")
                    result = subprocess.run(
                        ["bash", "-e", "-c", gate], capture_output=True, text=True,
                        env=dict(os.environ, PATH=f"{root}:{os.environ['PATH']}",
                                 GIT_LOG=str(log), FETCH_STATUS=str(fetch_status),
                                 ANCESTOR_STATUS=str(ancestor_status)),
                    )
                    self.assertEqual(result.returncode == 0, fetch_status == ancestor_status == 0)
                    expected = ["fetch --no-tags origin main:refs/remotes/origin/main"]
                    if fetch_status == 0:
                        expected.append("merge-base --is-ancestor HEAD refs/remotes/origin/main")
                    self.assertEqual(log.read_text().splitlines(), expected)

    def test_policy_runs_in_ci_deployment_and_tag_validation(self):
        for filename, job in (("ci.yml", "deployment"), ("tag-release.yml", "validate")):
            text = (WORKFLOWS / filename).read_text()
            self.assertIn("      - run: python3 scripts/release/test-workflow-policy.py\n",
                          block(text, f"  {job}:"))

    def test_review_and_action_update_coverage(self):
        owners = (GITHUB / "CODEOWNERS").read_text().splitlines()
        for path in ("/.github/", "/scripts/release/", "/android/app/build.gradle.kts"):
            self.assertIn(f"{path} @BIGGASSS", owners)
        dependabot = (GITHUB / "dependabot.yml").read_text()
        self.assertIn("  - package-ecosystem: github-actions\n", dependabot)
        self.assertIn("    directory: /\n", dependabot)
        self.assertIn("      interval: weekly\n", dependabot)


if __name__ == "__main__":
    unittest.main()
