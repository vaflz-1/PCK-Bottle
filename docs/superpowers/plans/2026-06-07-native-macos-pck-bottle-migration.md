# Native macOS PCK Bottle Migration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move Godot PCK Studio toward a lightweight native macOS Finder-like app without breaking the current Tauri baseline.

**Architecture:** Extract reusable PCK logic into `crates/pck-core` first, keep Tauri as a thin adapter, then add an AppKit shell that can call the same core. The current web UI remains buildable until the native app reaches feature parity.

**Tech Stack:** Rust 2021, Tauri 2 baseline, future Swift/AppKit shell, macOS universal release target, macOS 10.13+ compatibility.

---

## File Structure

- Create `crates/pck-core/Cargo.toml`: reusable Rust package metadata and dependencies.
- Create `crates/pck-core/src/lib.rs`: PCK archive reader/writer, safe package paths, workspace extraction, repack, backup, and scanning helpers.
- Modify `src-tauri/Cargo.toml`: depend on `godot-pck-core` and remove core-only dependencies from the Tauri adapter crate.
- Modify `src-tauri/src/lib.rs`: keep only Tauri commands, native macOS open panel, editor window creation, and app boot.
- Modify `tests/security.test.mjs`: add a guard that Tauri uses the shared PCK core instead of owning the archive implementation.
- Later create `macos/PCKBottle/`: native Swift/AppKit app shell after the core crate boundary is stable.

## Task 1: Shared Rust PCK Core Boundary

**Files:**
- Create: `crates/pck-core/Cargo.toml`
- Create: `crates/pck-core/src/lib.rs`
- Modify: `src-tauri/Cargo.toml`
- Modify: `src-tauri/src/lib.rs`
- Modify: `tests/security.test.mjs`

- [x] **Step 1: Write the failing architecture guard**

Add a Node test proving the Tauri backend no longer owns PCK archive internals:

```js
test("Tauri backend delegates reusable PCK behavior to the shared Rust core crate", () => {
  const cargoToml = readFileSync(new URL("../src-tauri/Cargo.toml", import.meta.url), "utf8");
  const tauriLib = readFileSync(new URL("../src-tauri/src/lib.rs", import.meta.url), "utf8");

  assert.match(cargoToml, /godot-pck-core\s*=\s*\{\s*path\s*=\s*"..\/crates\/pck-core"/);
  assert.match(tauriLib, /godot_pck_core::open_pck_workspace/);
  assert.match(tauriLib, /godot_pck_core::repack_pck/);
  assert.doesNotMatch(tauriLib, /const PCK_HEADER_MAGIC/);
});
```

- [x] **Step 2: Run the guard and verify it fails**

Run:

```bash
npm test -- tests/security.test.mjs
```

Expected: FAIL because `godot-pck-core` does not exist and `src-tauri/src/lib.rs` still owns `PCK_HEADER_MAGIC`.

- [x] **Step 3: Create `godot-pck-core`**

Create `crates/pck-core/Cargo.toml`:

```toml
[package]
name = "godot-pck-core"
version = "1.0.0"
edition = "2021"
description = "Reusable Godot PCK scanning, extraction, and repack core."

[dependencies]
md-5 = "0.10"
serde = { version = "1", features = ["derive"] }
```

Move pure Rust PCK/workspace code into `crates/pck-core/src/lib.rs`. Public adapter functions:

```rust
pub fn scan_paths(paths: Vec<String>) -> Result<Vec<FileEntry>, String>;
pub fn open_pck_workspace(pck_path: String) -> Result<PckWorkspace, String>;
pub fn repack_pck(
    pck_path: String,
    operations: Vec<PckOperation>,
    workspace_path: Option<String>,
    backup_original: bool,
) -> Result<String, String>;
pub fn cleanup_pck_workspace(workspace_path: String) -> Result<String, String>;
pub fn is_game_dialog_selection(path: &std::path::Path) -> bool;
pub fn sanitize_label(value: &str) -> String;
pub fn timestamp_millis() -> Result<u128, String>;
```

- [x] **Step 4: Thin the Tauri adapter**

Update `src-tauri/Cargo.toml`:

```toml
godot-pck-core = { path = "../crates/pck-core" }
```

Keep Tauri commands as one-line wrappers around `godot_pck_core`.

- [x] **Step 5: Run focused checks**

Run:

```bash
cargo test --manifest-path crates/pck-core/Cargo.toml
cargo test --manifest-path src-tauri/Cargo.toml
npm test -- tests/security.test.mjs
```

Expected: all tests pass.

- [x] **Step 6: Commit**

```bash
git add crates/pck-core src-tauri/Cargo.toml src-tauri/Cargo.lock src-tauri/src/lib.rs tests/security.test.mjs
git commit -m "refactor: extract shared pck core"
```

## Task 2: Native macOS Shell Scaffold

**Files:**
- Create: `macos/PCKBottle/README.md`
- Create: `macos/PCKBottle/Package.swift`
- Create: `macos/PCKBottle/Sources/PCKBottleApp/main.swift`

- [x] **Step 1: Add scaffold documentation**

Create a README that states the shell is AppKit-first, targets macOS 10.13+, and uses bundled template assets instead of novelty icons.

- [x] **Step 2: Add a minimal Swift package executable**

Use AppKit, `NSApplication`, `NSWindowController`, and `NSSplitViewController`. Avoid SwiftUI-only APIs so High Sierra remains possible.

- [x] **Step 3: Run Swift build**

Run:

```bash
swift build --package-path macos/PCKBottle
```

Expected: the shell compiles on the local macOS toolchain.

## Task 3: File Operation Contract

**Files:**
- Create: `crates/pck-core/src/operations.rs`
- Modify: `crates/pck-core/src/lib.rs`

- [ ] **Step 1: Add failing Rust tests for conflict planning**

Test add, replace, duplicate destination, path traversal rejection, and byte totals.

- [ ] **Step 2: Implement operation planning**

Expose an operation plan that both Tauri and AppKit can render before repack.

- [ ] **Step 3: Verify**

Run:

```bash
cargo test --manifest-path crates/pck-core/Cargo.toml
npm run check
```

Expected: all tests pass.

## Self-Review

- Spec coverage: Task 1 creates the shared core required by the architecture. Task 2 starts native AppKit without raising macOS minimum above 10.13. Task 3 creates the Finder-like add/replace contract.
- Placeholder scan: no task depends on an undefined "later" implementation.
- Risk: the first refactor is intentionally limited to Rust boundaries; UI migration starts only after core tests are green.
