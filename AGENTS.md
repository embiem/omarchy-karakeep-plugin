# Repository Guidelines

Guidelines for AI assistants working in this repository.

## Project Overview

An [Omarchy](https://omarchy.org) bar-widget plugin (`embiem.karakeep`) that quick-saves a link or a note to [Karakeep](https://karakeep.app). Flat repo, no build system — files ship exactly as committed. Three code layers: QML UI running inside Omarchy's Quickshell, a Qt-free JS model, and a stdlib-only Python helper that owns all HTTP and keyring access.

## Architecture & Data Flow

```
manifest.json ──▶ BarWidget.qml ──Loader──▶ Panel.qml ──▶ Model.js (pure logic)
                      │ IPC + shortcut        │ 4× Quickshell Process
                      │                       ▼
                      └────────────── karakeep-api <action> (stdin JSON ─▶ stdout JSON line)
                                                  │ secret-tool (keyring) + HTTPS API
```

- **`BarWidget.qml`** is the manifest entry point but deliberately thin: it owns only the widget-level contract the bar routes to (`IpcHandler target: "embiem.karakeep"` with `open/close/show/hide/toggle`, `GlobalShortcut name: "toggle"`). Left click toggles the panel; right click opens the server URL in a browser. `Panel.qml` is loaded via `Loader` and wired by `injectPanel()`, which duck-types properties (`"bar" in target`) instead of casting.
- **`Panel.qml`** owns all state (`connectionState: checking|disconnected|connected`, `serverUrl`, `session`). One `Process` per action (`statusProc`, `loginProc`, `addProc`, `clearProc`) runs `karakeep-api status|login|add|clear`; every result is routed through `Model.parseResult`. Connection settings persist via `persistConnection()` → `bar.shell.updateEntryInline()` — only the server URL and a `karakeepCredentialStored` marker go there, never the key.
- **`Model.js`** is pure classification/parsing (`looksLikeUrl`, `bookmarkPayload`, `previewUrl`, `apiKeysUrl`, `parseResult`) so it runs under node without a shell.
- **`karakeep-api`** is the security boundary. It validates and canonicalizes the server origin (HTTPS required, HTTP only for `localhost`/loopback IPs), validates the API key (printable ASCII only), and speaks to the Karakeep `/api/v1` API.

### Patterns you must preserve

- **Session stamps kill stale replies.** Each `Process` carries `property int session`; `open()`/`close()` increment `root.session`, and a reply whose session doesn't match is dropped. An `applied` flag plus an `onExited` fallback ensures a run that produced no output still resolves the UI state.
- **One result channel.** Operational and API failures are JSON results on stdout with exit 0; only a malformed invocation exits nonzero (2) with empty stdout. The helper never writes to stderr — `assert_result_contract` in the tests enforces all of this.
- **Secrets travel via stdin, never argv or env.** `loginProc`/`addProc` write their payload in `onStarted` and clear the QML-side copy before the write. The API key must never appear in a command line, a log, or an error message.
- **Fail closed on hostile input.** The helper rejects undecodable keyring bytes, non-ASCII keys, oversized responses (>1 MiB), and keyring JSON that isn't exactly `{serverUrl, apiKey}`. `Model.parseResult` coerces every field to a fixed type set so bad output can only reach the panel as a failure.
- **Fixed error strings.** Server-controlled text (403 bodies, TLS internals, tracebacks) never reaches the UI; the one exception is the scope name extracted by the `MISSING_SCOPE` regex. These exact strings are asserted by the tests — changing one is a two-file change.
- **No redirects, no proxies.** The opener uses `NoRedirect` (urllib would forward `Authorization`) and `ProxyHandler({})` so an env proxy can never receive the bearer token.

## Key Directories

- `/` — all source: `manifest.json`, `BarWidget.qml`, `Panel.qml`, `Model.js`, `karakeep-api`, `README.md`, `LICENSE`, `preview.png`.
- `tests/` — `karakeep-test.sh`, the full behavioral suite (model + helper against fakes).

## Development Commands

```bash
tests/karakeep-test.sh          # the entire test suite; prints "karakeep tests passed" on success
omarchy plugin validate          # manifest check (from a checkout with the omarchy CLI)
```

No linter, formatter, or build step exists. Verification is the test script; run it after any change to `Model.js` or `karakeep-api`.

## Code Conventions & Common Patterns

- **QML**: 2-space indent, camelCase ids/properties/functions. Root object gets `id: root`. UI components come from Omarchy's shell modules (`qs.Ui`, `qs.Commons`): `BarWidget`, `Panel`, `KeyboardPanel`, `BarIconButton`, `PanelActionButton`, `Style`, `Color`. Comments explain *why* (invariants and edge cases), not *what* — keep that style.
- **JS (`Model.js`)**: ES5 `var`, Qt-free, null-safe coercion (`String(value == null ? "" : value).trim()`) on every entry point, CommonJS export guarded by `typeof module !== "undefined"` so the same file imports in QML.
- **Python (`karakeep-api`)**: stdlib only, no third-party imports. Module-level constants upper-case (`SECRET_ATTRIBUTES`, `MAX_RESPONSE_BYTES`). Every action function returns an exit code and emits exactly one JSON line. Exceptions are caught at the action boundary and converted to fixed `ValueError` messages — nothing may escape as a traceback.
- **Error handling contract**: user-visible strings are part of the test contract; if you reword one, update `tests/karakeep-test.sh` in the same change.

## Important Files

| File | Role |
|---|---|
| `manifest.json` | Omarchy plugin manifest: `id`, `entryPoints.barWidget → BarWidget.qml`, `barWidget` metadata. `schemaVersion: 1`. |
| `BarWidget.qml` | Bar icon + IPC/shortcut surface; panel host. |
| `Panel.qml` | All state, four helper processes, full UI. |
| `Model.js` | Pure input classification and result parsing. |
| `karakeep-api` | Python helper: keyring via `secret-tool`, HTTP, validation, JSON results. |
| `tests/karakeep-test.sh` | Behavioral suite with fakes; the definition of done. |

## Runtime/Tooling Preferences

- `karakeep-api` shebang is `#!/usr/bin/python3` — **absolute on purpose**, so PATH shims can't substitute a different interpreter in a real session. Don't "fix" it to `env python3`; `run_no_secret_tool` guards it.
- Python: any python3 with stdlib (`urllib`, `ssl`, `ipaddress`, `subprocess`).
- Tests require `bash`, `python3`, and `node` (node runs the generated `model-test.js` against `Model.js`).
- `karakeep-api` must stay executable (`chmod 755`); the suite checks this first.
- The plugin lives at `~/.config/omarchy/plugins/embiem.karakeep/` when installed.

## Testing & QA

`tests/karakeep-test.sh` is a single self-contained bash script (`set -euo pipefail`): it builds a temp dir, writes a fake `secret-tool` (first in PATH, backed by a file, asserting the exact attribute set), starts a Python HTTP stub on `127.0.0.1`, runs the node model assertions, then exercises every helper action. It never touches the real keyring or network.

- **`run_helper <action> [json]`** is the harness; `assert_result_contract` runs on every call: exit 0, empty stderr, and no API key or `Bearer` leak on either stream.
- **`run_no_secret_tool`** uses `env -i` with an empty PATH — the shebang/no-plaintext-fallback regression guard.
- **`expect_error "<exact string>"`, `expect_no_request <before>`, `field <name>`** are the assertion helpers; `ok`/`fail` report. First failure exits 1.
- New tests follow the section layout (`---- fakes ----`, `---- helpers ----`, `---- model ----`, `---- helper ----`) and use the existing helpers rather than raw invocations. Cover observable contract only: result JSON, request counts/wire bodies, keyring store contents — not implementation detail.
