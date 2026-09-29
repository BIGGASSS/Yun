# Vendored Flutter SDK action

Upstream: [subosito/flutter-action](https://github.com/subosito/flutter-action)
Upstream commit: `1a449444c387b1966244ae4d4f8c696479add0b2` (the previously pinned v2 revision).
License: [MIT, copyright 2019 Alif Rachmawadi](LICENSE), retained verbatim.
This third-party code is not covered by Yun's root license grant.

## Why this local fork exists

The pinned upstream composite action invokes `actions/cache@v5` twice. GitHub's
SHA-only Actions policy rejects those mutable nested references even though the
outer `subosito/flutter-action` reference is pinned. Disabling caching does not
remove those references. Vendoring the complete runtime action lets us pin them
without relaxing repository settings or reimplementing SDK bootstrap behavior.

## Original sources and SHA-256

Retrieved through the GitHub contents API with `gh api` at the exact commit above:

- [action.yaml](https://github.com/subosito/flutter-action/blob/1a449444c387b1966244ae4d4f8c696479add0b2/action.yaml)
- [setup.sh](https://github.com/subosito/flutter-action/blob/1a449444c387b1966244ae4d4f8c696479add0b2/setup.sh)
- [LICENSE](https://github.com/subosito/flutter-action/blob/1a449444c387b1966244ae4d4f8c696479add0b2/LICENSE)

Hashes below are of the **original bytes**, before local patches:

| Upstream file | Local file | Original SHA-256 |
| --- | --- | --- |
| `action.yaml` | `action.yml` | `5c0e5a243d010be58a41bded0cbca71687317b712d6876ebf6ab434494adcb75` |
| `setup.sh` | `setup.sh` | `35f0cd9e9c1d7a643448223573b4a03879e63676fdc27872de3d0104d5bf89f9` |
| `LICENSE` | `LICENSE` | `329009b59300a124af69c29c9ad19d38079207d9098c76fe0b51dc79a76a2e9a` |

## Exact local changes

1. Rename upstream `action.yaml` to `action.yml`.
2. In both `Cache Flutter` and `Cache pub dependencies`, replace
   `uses: actions/cache@v5` with
   `uses: actions/cache@caa296126883cff596d87d8935842f9db880ef25 # v5`.
   The initial cache pin was resolved using
   `gh api repos/actions/cache/commits/v5 --jq .sha`.
   Subsequent reviewed Dependabot updates may advance these pins; `action.yml`
   is authoritative for the current cache revisions.
3. Add this provenance document. No other upstream content changes.

`setup.sh` (including its executable mode) and `LICENSE` are unchanged. The caller
`../flutter/action.yml` now uses `./.github/actions/flutter-sdk`; its exact FVM
bootstrap version, inputs, and commands remain unchanged.

Runtime inspection: `action.yml` executes only the adjacent `setup.sh`. The script
uses runner tools and downloads Flutter release manifests/SDK archives (or clones
Flutter for main/master); it sources no other upstream runtime files. Its only
repository-relative data dependency is `test/releases_<os>.json` behind the `-t`
test-only flag, which the composite never passes. Upstream test fixtures, README,
and workflows are therefore not vendored; standalone `setup.sh -t` is not provided.
Caller-supplied version files are inputs, not missing vendored files.

Inherited lint note: ShellCheck 0.10.0 reports SC2086 on the two unquoted
`$GITHUB_ACTION_PATH/setup.sh` invocations in upstream `action.yaml` (the
`Set action inputs` and `Run setup script` steps). They are preserved, not locally
fixed or suppressed. The unchanged `setup.sh` passes ShellCheck and `bash -n`.

## Updates and verification

Dependabot's weekly `github-actions` scan handles nested `actions/cache` pins in
this local action. It does **not** update the vendored Flutter action itself;
upstream vendor updates require manual review:

1. Select and review a new full upstream commit SHA (including license changes).
   Download each source into a temporary directory, for example:

   ```sh
   commit=1a449444c387b1966244ae4d4f8c696479add0b2 # replace with reviewed commit
   destination=$(mktemp -d)
   for file in action.yaml setup.sh LICENSE; do
     gh api "repos/subosito/flutter-action/contents/$file?ref=$commit" \
       -H 'Accept: application/vnd.github.raw+json' > "$destination/$file"
   done
   sha256sum "$destination"/*
   ```

2. Inspect the upstream tree and all script/file references for new runtime
   dependencies. Copy all required files, preserving license and executable mode;
   rename `action.yaml` to `action.yml`. Do not copy unrelated upstream workflows.
3. Resolve/review cache commits with `gh api repos/actions/cache/commits/v5 --jq .sha`
   (or the upstream major then in use). Apply only full-SHA nested action pins
   with readable version comments. Review every nested `uses:` reference.
4. Update this document's commit, source links, original hashes, and patch list.
   Update the provenance regression test if the upstream file set or original
   cache reference changes. Do not change original hashes for cache-only updates.
5. Run `python3 scripts/release/test-workflow-policy.py`, the release-tooling and
   Android-signing tests, `actionlint` on workflows, `bash -n` and `shellcheck` on
   scripts (including `setup.sh`), and `git diff --check`. Inspect composite inline
   shell separately: actionlint validates workflows, not action metadata.
   Keep unrelated upstream lint fixes out of this minimal fork; document inherited
   warnings rather than silently altering upstream code. Validate hosted builds on
   Linux, macOS, Windows, and Android after review; offline checks do not execute
   GitHub's runner or verify repository settings.
