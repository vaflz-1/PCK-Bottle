# Legacy — Tauri / Vue / Quasar branch (deprecated)

This directory holds the original **Tauri + Vue + Quasar** desktop UI and its
JavaScript regression tests. It is **deprecated** and is no longer the shipped
product.

The maintained product is the native macOS AppKit app in
[`../macos/PCKBottle`](../macos/PCKBottle), which talks directly to the shared
Rust core in [`../crates/pck-core`](../crates/pck-core). Nothing in `macos/` or
`crates/` depends on anything in this folder.

It is kept here because the JS suite under `tests/` still encodes useful
security and workflow contracts (CSP, capability scoping, file-staging rules)
that informed the native app.

## Layout

- `src/` — Vue/Quasar front end (`app.js`, `i18n.js`, `core/file-workflow.js`, vendored Vue/Quasar bundles).
- `src-tauri/` — Tauri Rust shell (consumes `godot-pck-core` from `../../crates/pck-core`).
- `tests/` — Node `--test` regression suites (`core`, `i18n`, `security`).
- `package.json` — scripts for the legacy build/tests.

## Running the legacy suite

```bash
cd legacy
npm install        # restores node_modules
npm test           # runs the Node regression tests
npm run tauri:dev  # runs the deprecated Tauri UI (requires the Tauri CLI)
```

> These commands must be run from inside `legacy/`. The repository root no
> longer carries a `package.json`.
