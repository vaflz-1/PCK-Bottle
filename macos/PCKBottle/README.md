# PCK Bottle Native macOS Shell

PCK Bottle is the native macOS shell for the next Godot PCK Studio app. It is AppKit-first, lightweight, and Finder-like: a main browser window opens a Godot `.app` or loose `.pck`, then package editor windows provide a two-pane file workflow for adding and replacing package files.

## Platform

- Target: macOS 10.13+ while the project still needs High Sierra support.
- Build shape: universal `x86_64` and `arm64`.
- UI framework: AppKit, not SwiftUI, so old macOS releases remain viable.

## Visual Direction

Use native macOS materials, source lists, split views, sheets, and progress indicators. Icons should be SF Symbols when the runtime supports them, with bundled monochrome template assets as the compatibility fallback. Avoid novelty icon sets; tree and toolbar icons must stay quiet, readable, and file-manager-native.

## Initial Scope

This package is a compileable shell scaffold. The next slices connect it to the shared Rust `godot-pck-core` library through a small bridge, then replace the current Tauri windowing layer once feature parity is real.
