#!/usr/bin/env python3
"""Offline workflow security regression tests (stdlib only; no GitHub API calls).

These deliberately check the checked-in YAML's text/indentation, not arbitrary YAML.
Security-sensitive restructuring must update these assertions explicitly. Remote
secret scope, environment protection and branch rules still need operator checks.
"""
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

    def test_no_secret_declarations_forwarding_or_other_consumers(self):
        signed = block(self.android, "      - name: Build and verify release-signed APK (no fallback)")
        self.assertIn("        if: inputs.android_signing == 'release-signed'\n", signed)
        self.assertIn("        run: bash scripts/release/build-android.sh release-signed\n", signed)
        for name in SIGNING_SECRETS:
            self.assertIn(f"          {name}: ${{{{ secrets.{name} }}}}\n", signed)
        for path, text in self.files.items():
            with self.subTest(path=path):
                self.assertNotRegex(text, r"(?m)^\s*(?:- )?secrets:")
                remainder = text.replace(signed, "") if path.endswith("/native-builds.yml") else text
                code = "\n".join(line for line in remainder.splitlines() if not line.lstrip().startswith("#"))
                self.assertNotRegex(code, r"\bsecrets\s*[.\[]")
                for name in SIGNING_SECRETS:
                    self.assertNotIn(name, remainder)
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
