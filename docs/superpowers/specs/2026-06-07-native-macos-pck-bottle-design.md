# Native macOS PCK Bottle Design

## Goal

Build the next version as a lightweight native macOS app for editing Godot `.pck` packages with a Finder-like file workflow: open a game `.app` or loose `.pck`, inspect package contents, drag files in, review add/replace conflicts, create a backup, repack, verify, and atomically replace the package.

## Product Shape

The app has two window types:

- Main browser window: accepts `.app` and `.pck` drops, scans a selected `.app`, and shows a searchable game tree with clear `.pck` rows. Double-click or Open opens a package editor. The browser stays open behind editor windows.
- PCK bottle window: a two-pane file manager. Left pane is "Files to add"; right pane is "Package contents". Dragging from left to right shows the exact destination and operation: add, replace, or conflict.

The target feel is native Finder utility, not a web demo. Keep visual density high, use calm macOS materials, and avoid decorative or cartoonish icons. Icons should be SF Symbols or bundled monochrome template PDF assets with graceful fallback for older macOS releases.

## Platform Constraints

- Universal build: `x86_64` and `arm64`.
- Minimum macOS target remains `10.13` unless a tested dependency forces a higher floor.
- Do not require macOS 26-only Liquid Glass APIs. Use AppKit `NSVisualEffectView`, source-list/table styles, sheets, and progress indicators so the UI degrades cleanly on old systems.
- Keep the current Tauri baseline working while migration proceeds.

## Architecture

Target architecture:

```text
native AppKit app
  -> Rust FFI bridge or helper command layer
  -> godot-pck-core Rust crate
      -> safe scanning
      -> temp workspace extraction
      -> add/replace operation planning
      -> backup
      -> temp write + verification + atomic replace
```

The first migration slice extracts reusable Rust PCK behavior out of `src-tauri/src/lib.rs` into `crates/pck-core`. The existing Tauri commands become thin adapters around that crate. This creates a stable core for the future native app without breaking the current app.

## File Workflow

1. Open `.app` or `.pck`.
2. If `.app`, scan inside the app bundle and show only useful game tree structure with `.pck` packages made visually explicit.
3. Opening a `.pck` creates a temp workspace and extracts package contents.
4. Left pane accepts files/folders by native drop or Open button.
5. Dragging selected source items onto a package folder creates staged operations.
6. The app runs a conflict pass before write.
7. The confirmation sheet shows add count, replace count, bytes, and backup path policy.
8. Repack writes a sibling temp file, verifies it can be loaded and contains expected paths, then replaces the original.
9. Original backup is on by default for user-driven replacement.

## Security And Safety

- Reject path traversal, NUL bytes, absolute package targets, symlinks during scans, and cleanup outside the temp workspace root.
- Do not invoke arbitrary shell scripts.
- Keep quarantine clearing scoped to selected source files only.
- Never replace a `.pck` without a finished temp write.
- Keep bundle permissions minimal.

## Acceptance Criteria

- Existing Tauri baseline still passes `npm run check`.
- Rust core tests pass independently through `cargo test --manifest-path crates/pck-core/Cargo.toml`.
- Universal macOS build remains possible through `npm run tauri:build:universal` until the native shell replaces Tauri.
- Native migration has no Jenkins-like or cartoon app/tree icons; icons are template-style, macOS-native, and readable at 16-32 px.
