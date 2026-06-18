<div align="center">

# 🍶 PCK Bottle

Edit Godot `.pck` packages on macOS without the command line.

**English** · [Русский](README.ru.md) · [中文](README.zh.md)

[![macOS](https://img.shields.io/badge/macOS-10.13%2B-000000?logo=apple&logoColor=white)](../../releases/latest)
[![Universal](https://img.shields.io/badge/Universal-Intel%20%2B%20Apple%20Silicon-555)](../../releases/latest)
[![License](https://img.shields.io/badge/license-Apache--2.0-blue.svg)](LICENSE)
[![Download](https://img.shields.io/badge/⬇%20Download-Releases-2ea44f)](../../releases/latest)

![PCK Bottle editing a Godot .pck](docs/screenshot-editor.png)

</div>

PCK Bottle opens a Godot game (an `.app` bundle or a loose `.pck`) and shows it
as a file tree. Drag files in to add or replace them, see what changed, and
pack. You can also pull files back out onto your disk. It handles Godot 3 and
Godot 4 packages and any content inside: textures, scenes, scripts, `.import`
data, locale files.

## ⬇️ Download

1. Open the [Releases](../../releases/latest) page and download `PCK Bottle.dmg`.
2. Open the `.dmg` and drag **PCK Bottle.app** into your `Applications` folder.

Apple has not notarized this build (it is signed ad-hoc), so the first launch
shows a Gatekeeper warning that the app is "damaged" or from an "unidentified
developer". Clear the download quarantine once and the warning is gone for good.

**Open Terminal:** press `⌘ Space`, type `Terminal`, press `Return`. In the
window that opens, paste this line and press `Return`:

```bash
xattr -dr com.apple.quarantine "/Applications/PCK Bottle.app"
```

After that the app launches from Finder or Launchpad like any other. (Right
click the app and choose **Open** also works; the Terminal command is the one
that always does.)

## ✨ Features

- Open a Godot **`.app`** (it finds the `.pck` inside) or a loose **`.pck`**.
- Browse package contents as a file tree.
- Drag files or folders in to stage changes. Folder nesting stays intact, and a
  wrapper folder such as `translation/` unwraps onto the matching package paths.
- Review staged work in a grouped Changes panel (replace, add, delete,
  duplicate). Nothing touches disk until you press **Pack**.
- Delete, duplicate, copy, paste, drag rows out to Finder, extract files to disk.
- Undo and redo (⌘Z / ⇧⌘Z) on every change, with animated rows.
- Back up the original on each pack and restore it whenever you want.
- Pack the way Godot does: correct path padding and per-format data alignment
  (16 bytes on Godot 3, 32 on Godot 4), including the hidden `.import` and
  `.godot` folders that hold imported textures.
- Interface in English, Русский, 中文, switchable from the menu bar.
- Universal build for Intel and Apple Silicon, macOS 10.13 and up.

## 🚀 Usage

1. Open your game: drop its `.app` or `.pck` on the window, or use **File → Open**.
2. Drag your mod folder onto the tree. For a translation pack, drop the
   **`translation`** folder; its `scenarios/`, `UI/`, `.import/` land on the
   matching package paths.
3. Check the Changes panel, keep **Backup original** on, press **Pack Changes**.
4. Launch the game.

### ↩️ Restore the original

With **Backup original** on, each pack first writes a timestamped
`<name>.pck.<timestamp>.bak` next to the package. To roll back:

- In the app, choose **File → Restore from Backup…** (⇧⌘R). It restores the
  newest backup and reloads the package.
- By hand, delete the modified `.pck` and rename the newest `.bak` to the
  original name (`Game.pck.1700000000000.bak` becomes `Game.pck`).

### 🌐 Switch language

Use the **Language** menu in the menu bar and pick English, Русский, or 中文. The
app remembers your choice and otherwise follows the system language.

## 🔧 Build from source

You need a recent Xcode (Swift) toolchain and Rust with both Apple targets.

```bash
rustup target add aarch64-apple-darwin x86_64-apple-darwin

# Universal .app (debug or release):
CONFIGURATION=release bash macos/PCKBottle/scripts/build-app.sh
# → macos/PCKBottle/build/PCK Bottle.app

# Optional disk image:
bash macos/PCKBottle/scripts/make-dmg.sh

# Rust core tests:
cargo test --manifest-path crates/pck-core/Cargo.toml
```

The build remaps local paths and strips the binaries, so a shipped `.app` carries
no home directory or username.

## 🧩 How it works

| Path | What it is |
|------|------------|
| [`crates/pck-core`](crates/pck-core) | Shared **Rust** core: PCK scanning, reading, extraction, and atomic repack. Ships as a small `pck-core-cli` inside the app. |
| [`macos/PCKBottle`](macos/PCKBottle) | The native macOS **AppKit** app, and the maintained product. |
| [`legacy/`](legacy) | The old Tauri/Vue UI, kept for reference. Not shipped. |

The app is a thin AppKit shell over the bundled `pck-core-cli`, so the parsing
and repack code stays in one Rust crate.

## 📄 License

[Apache License 2.0](LICENSE).
