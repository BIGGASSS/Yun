# Yun's local Linux secure-storage fork

## Provenance and attribution

Vendored from the installed `flutter_secure_storage_linux` **3.0.3** directory
at `~/.pub-cache/hosted/pub.dev/flutter_secure_storage_linux-3.0.3`, without
modifying that cache. Upstream: https://github.com/mogol/flutter_secure_storage.
The original `README.md` and BSD-3-Clause `LICENSE` (copyright 2017 German
Saprykin) are retained unchanged. `CHANGELOG.md` and the plugin implementation
are retained with trailing whitespace removed from one line each; there are no
functional plugin-dispatch changes. The vendored `json.hpp` retains its embedded license.

Pub's cached upstream archive SHA-256:

```
caa75bd78f017422912e3a904933113b2428eb79f981ac37acd2dd2a700458ea
```

`UPSTREAM_FILES.sha256` records each **installed source file before this
fork's changes**; it is not a claim that the cache was pristine upstream.
In particular, that installed baseline already included keyring warmup,
missing-default/locked guards, typed errors, and sandbox routing support.
SHA-256 of the baseline manifest:
`152afef42536f0af85131f3c6565b0244bafea812f33028935fbabee0ef0ab8d`.

## Local changes

- `linux/include/Secret.hpp`: discover a running **or activatable** standard
  `org.freedesktop.secrets` first. Only its confirmed absence permits selecting
  running/activatable `org.kde.secretservicecompat`. Discovery errors do not
  authorize fallback. D-Bus performs normal activation of the selected name.
- Open an explicit service and retain it for lookup, store, search, alias
  resolution, unlocking, and logical deletion. Never retry a failed operation
  on another provider; never retry an ambiguous write. Existing JSON blob,
  account attribute, default collection, and delete-as-JSON-update are unchanged.
- Stabilize schema-name ownership independently of the mutable display label;
  see the compatibility details below. Do not broaden lookups to other accounts
  or schemas, migrate entries automatically, or clear a failed read.
- Keep the existing Simple API path for sandbox portals/explicit file backend;
  do not discover KDE on that path. No new plaintext/file/session-only fallback,
  commands, daemon installs, or host configuration changes.
- Preserve `KeyringLocked`, `SecretNotFound`, and generic libsecret errors;
  propagate unlock errors instead of conflating access denial with a lock.
- `pubspec.yaml`: remove the published monorepo-only `resolution: workspace`
  field so the package can be consumed as a standalone path dependency.

### Registration and schema compatibility

The actual plugin default-constructs its static `SecretStorage`, then calls
`setLabel("app.yun.yun/FlutterSecureStorage")` and
`addAttribute("account", "app.yun.yun.secureStorage")`. Previously the schema
borrowed `label.c_str()` before registration. The longer label invalidated that
pointer (even the small-string-to-heap transition is unsafe). The new exact-order
private-bus test, run before the fix on this machine, completed CRUD but recorded
`xdg:schema = " "` rather than `"default"`. Other builds can produce different
invalid names or fail; this does not establish the cause of any particular
user's startup error. Tests that passed the long label directly to the
constructor missed the bug.

The minimal fix gives the constructor-selected schema name separate immutable
storage. `setLabel` changes only the human-readable item label. Copy/move are
disabled because the schema borrows its owner's string buffer. Registration now
reliably uses **`xdg:schema = "default"` plus the exact Yun account attribute**.
Direct construction with a custom name retains that schema, as before. This
preserves the baseline constructor's declared schema semantics rather than
introducing an app-named schema migration. The app-specific account, not the
shared `"default"` name alone, isolates credentials.

There is no reliable schema identity to preserve from undefined behavior.
Previously written entries with a corrupted or app-named schema are **not**
automatically discovered, rewritten, or deleted. They may remain inaccessible
through this fork; a new valid Yun entry can coexist with them. Recovery would
require a separate, explicit, validated migration, not an account-only search or
a schema-ignoring fallback. Other accounts and other schemas are never read or
replaced. Existing valid `default`/Yun JSON preserves sibling values; malformed
JSON fails a read-modify-write without writing anything. `deleteAll` remains an
explicit update of the exact scoped item to `{}`, not a wallet-wide clear. No
cleanup/migration is needed for a fresh KDE store after a failed startup.

### libsecret explicit-name compatibility

The installed libsecret **0.21.8.2**, and upstream **0.20.5** / **0.21.4** (the
release versions used by Ubuntu 22.04 / 24.04), ignore `service_bus_name` in
`secret_service_open_sync()` and unconditionally replace `g-name` in their
constructor. This is not specific to 0.21.8.2. Calling that API alone contacts
the standard name, not KDE; private-bus tests catch it.

`openNamedSecretService()` constructs an uninitialized proxy with an explicit
`g-name` and checks it without bus I/O. If overwritten, a tiny `SecretService`
subtype restores that name during construction and uses GInitable initialization.
Otherwise it initializes the very proxy whose name was checked: constructor
support for `g-name` does **not** imply that the wrapper forwards its argument.
This happens **before connecting**, without changing `SECRET_SERVICE_BUS_NAME`,
`SECRET_BACKEND`, or other process-global state. All operations use this one
service.

## Isolated native tests

From the repository root:

```sh
packages/flutter_secure_storage_linux/linux/test/run_private_bus_tests.sh
# One scenario:
packages/flutter_secure_storage_linux/linux/test/run_private_bus_tests.sh \
  -p /secret-service/kde-activation
```

Requires a C++14 compiler, `pkg-config`, libsecret/GIO development libraries,
and `dbus-daemon`; no Flutter SDK, root, GTest download, wallet, or desktop
required. The script compiles the modified headers and the GLib `g_test` suite
into a temporary directory and cleans the build afterwards.

Each case runs in a fresh subprocess with its own `GTestDBus`, whose config
has **no host service directories**. Mock services are subprocesses of this
same test executable, not KWallet/ksecretd. Activation tests install temporary
`.service` files pointing only to that executable. Dummy JSON is held in
memory; the mock accepts Secret Service's plain wire-session protocol for
testing only. The production client continues to use libsecret's session
negotiation and a persistent default collection.

27 cases cover:

- exact plugin registration order on KDE and standard services, checking the
  stored schema, account, and display label after CRUD/delete-all;
- registered-plugin reads of existing `default`/Yun JSON, preservation of other
  accounts and other schemas (sentinels reject even matching searches or
  replacements), and malformed JSON that must not be overwritten;
- KDE-only real-libsecret read/write/overwrite/delete/delete-all roundtrip;
- preexisting JSON, Unicode, preserved sibling values, and exact schema/account;
- standard-only and both-present standard preference;
- KDE autoactivation and activatable-standard preference over running KDE,
  including assertions that discovery itself does not activate anything;
- locked, denied, broken, timeout-error, and missing-object standard providers,
  plus unlock denial and broken standard activation: no KDE calls;
- committed-write/error-reply simulation: exactly one write, no fallback;
- selected-provider disappearance: no reselection;
- failed discovery, both providers missing, fresh missing-default collection,
  and orphaned matching data with missing default alias;
- sandbox/explicit backend decisions and an actual portal/file-backend request
  that fails at the absent private-bus portal without contacting KDE. Any
  file-backend data path in that test is redirected to a temporary directory.

Local validation: all 27 cases passed with installed libsecret 0.21.8.2 and
separately compiled upstream 0.20.5 and 0.21.4 (selected for the test process with
`PKG_CONFIG_PATH` and `LD_LIBRARY_PATH`). These are host builds of the older
releases, not claims of running Ubuntu itself; CI's Ubuntu 22.04/24.04 jobs test
the distribution packages. All 27 also passed with a test-only 0.20.5 build
whose constructor was changed to preserve explicit `g-name` while leaving the
wrapper's ignored argument unchanged, exercising the probe's other branch.
The native suite reproduces the plugin's exact storage registration sequence,
not Flutter engine/method-channel dispatch.

The timeout case returns the D-Bus timeout error, rather than waiting for a
real 25-second timeout. The suite does not implement an interactive unlock
prompt or a successful desktop portal backend. The inherited upstream
`flutter_secure_storage_linux_plugin_test.cc` accesses the current session
wallet: **do not run it on the user's desktop**. Use the isolated script above.
