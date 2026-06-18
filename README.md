<div align="center">

# 🍶 PCK Bottle

**Native macOS editor for Godot `.pck` packages — browse, edit, repack and apply mods, no terminal required.**

**English** · [Русский](README.ru.md) · [中文](README.zh.md)

[![macOS](https://img.shields.io/badge/macOS-10.13%2B-000000?logo=apple&logoColor=white)](../../releases/latest)
[![Universal](https://img.shields.io/badge/Universal-Intel%20%2B%20Apple%20Silicon-555)](../../releases/latest)
[![License](https://img.shields.io/badge/license-Apache--2.0-blue.svg)](LICENSE)
[![Download](https://img.shields.io/badge/⬇%20Download-Releases-2ea44f)](../../releases/latest)

<!-- Add a screenshot here: docs/screenshot.png -->
<!-- ![PCK Bottle](docs/screenshot.png) -->

</div>

PCK Bottle opens a Godot game (an `.app` bundle or a standalone `.pck`), shows
its contents as a Finder‑like tree, and lets you drag files in to add or replace
them, preview exactly what will change, back up the original, and repack — or
pull files back out of a `.pck` onto your disk.

> Not just a translation installer: a general, Finder‑style modification manager
> for Godot PCKs — works with **Godot 3 and Godot 4** packages and any content
> (textures, scenes, scripts, `.import` data, locales, …).

## ⬇️ Download & install

1. Grab the latest **`PCK Bottle.dmg`** (or `.app.zip`) from the
   [**Releases**](../../releases/latest) page — no build step needed.
2. Open the `.dmg` and drag **PCK Bottle.app** into `/Applications`.

Builds are signed **ad‑hoc** (not notarized by Apple), so on first launch macOS
Gatekeeper may say the app is "damaged" or from an "unidentified developer".
Clear the download quarantine once:

```bash
xattr -dr com.apple.quarantine "/Applications/PCK Bottle.app"
```

…or right‑click the app → **Open** → **Open**. (A notarized release would open
with a plain double‑click.)

## ✨ Features

- Open a Godot **`.app`** (auto‑discovers the `.pck` inside) or a standalone **`.pck`**.
- Browse package contents as a tree of files and folders.
- **Drag & drop** files or whole folders to stage changes — folder nesting is
  preserved, and a distribution wrapper like `translation/` is unwrapped
  automatically so its contents land on the matching package paths.
- Review staged work in a grouped, collapsible **Changes** panel
  (replace / add / delete / duplicate) — nothing is written until you click **Pack**.
- **Delete / duplicate / copy / paste**, drag rows **out to Finder**, and
  **extract** selected files to a folder on disk.
- **Undo / redo** (⌘Z / ⇧⌘Z) for every staged change, with animated rows.
- **Back up** the original automatically and **restore from a backup** at any time
  (File → Restore from Backup).
- Correct Godot packing: faithful streaming repack, right path padding and data
  alignment per format (Godot 3 / Godot 4), and Godot's hidden `.import` /
  `.godot` folders (imported textures) are included.
- Localized UI — **English / Русский / 中文** — switchable from the menu bar.
- Native **universal** app (Intel + Apple Silicon), macOS 10.13+.

## 🚀 Usage

1. **Open** your game: drop the game's `.app` or `.pck` onto the window, or use
   **File → Open**.
2. **Stage** your mod: drag its folder onto the tree. For a translation pack,
   drop the **`translation/`** folder itself — its `scenarios/`, `UI/`,
   `.import/`, … land on the matching package paths.
3. **Review** the Changes panel, keep **Backup original** ticked, then press
   **Pack Changes**.
4. Launch the game. To revert, use **File → Restore from Backup**.

## 🔧 Build from source

Requirements: a recent Xcode (Swift) toolchain and Rust with both Apple targets.

```bash
rustup target add aarch64-apple-darwin x86_64-apple-darwin

# Universal .app (debug or release):
CONFIGURATION=release bash macos/PCKBottle/scripts/build-app.sh
# → macos/PCKBottle/build/PCK Bottle.app

# Optional disk image:
bash macos/PCKBottle/scripts/make-dmg.sh

# Run the Rust core tests:
cargo test --manifest-path crates/pck-core/Cargo.toml
```

Release builds remap local paths and strip the binaries, so a shipped `.app`
embeds no home directory or username.

## 🧩 How it works

| Path | What it is |
|------|------------|
| [`crates/pck-core`](crates/pck-core) | Shared **Rust** core: PCK scanning, reading, extraction and safe **atomic** repack. Ships as a tiny `pck-core-cli` bundled in the app. |
| [`macos/PCKBottle`](macos/PCKBottle) | The native macOS **AppKit** app — the maintained product. |
| [`legacy/`](legacy) | Deprecated Tauri/Vue UI + JS tests, kept for reference. Not shipped. |

The app is a thin AppKit shell that shells out to the bundled `pck-core-cli`, so
all security‑critical parse/repack logic lives in one audited Rust crate.

## 📄 License

[Apache License 2.0](LICENSE).
