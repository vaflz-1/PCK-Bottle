#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PACKAGE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$PACKAGE_DIR/../.." && pwd)"
CONFIGURATION="${CONFIGURATION:-debug}"

case "$CONFIGURATION" in
  debug)
    PRODUCT_DIR_NAME="Debug"
    CARGO_PROFILE="debug"
    ;;
  release)
    PRODUCT_DIR_NAME="Release"
    CARGO_PROFILE="release"
    ;;
  *)
    echo "CONFIGURATION must be debug or release, got: $CONFIGURATION" >&2
    exit 2
    ;;
esac

# Single source of truth for the version: repo-root VERSION file, overridable
# from the environment (CI derives APP_VERSION/APP_BUILD from the git tag).
APP_VERSION="${APP_VERSION:-$(tr -d '[:space:]' < "$REPO_ROOT/VERSION" 2>/dev/null || true)}"
APP_VERSION="${APP_VERSION:-1.0.0}"
APP_BUILD="${APP_BUILD:-$APP_VERSION}"
COPYRIGHT="${COPYRIGHT:-© $(date +%Y) PCK Bottle contributors}"

# Privacy: remap the local build paths so the shipped binaries never embed the
# builder's home directory / username (Rust bakes file!() paths from panics, and
# Swift bakes #file/debug paths). Without this a published .app leaks e.g.
# /Users/<name>/… — a deanonymization vector. Mappings are best-effort and only
# affect emitted path strings, not behaviour.
REMAP_RUSTFLAGS="--remap-path-prefix=$REPO_ROOT=. --remap-path-prefix=$HOME=~"
SWIFT_REMAP=(
  -Xswiftc -debug-prefix-map -Xswiftc "$REPO_ROOT=."
  -Xswiftc -file-prefix-map -Xswiftc "$REPO_ROOT=."
  -Xcc -fdebug-prefix-map="$REPO_ROOT=."
)

build_core_cli() {
  local target="$1"
  local extra=()
  [[ "$CONFIGURATION" == "release" ]] && extra+=(--release)
  RUSTFLAGS="${RUSTFLAGS:-} $REMAP_RUSTFLAGS" \
    cargo build --manifest-path "$REPO_ROOT/crates/pck-core/Cargo.toml" --bin pck-core-cli --target "$target" "${extra[@]}"
}

swift build --package-path "$PACKAGE_DIR" --configuration "$CONFIGURATION" --arch arm64 --arch x86_64 "${SWIFT_REMAP[@]}"
build_core_cli aarch64-apple-darwin
build_core_cli x86_64-apple-darwin

BINARY_PATH="$PACKAGE_DIR/.build/apple/Products/$PRODUCT_DIR_NAME/PCKBottle"
ARM64_CORE_CLI_PATH="$REPO_ROOT/crates/pck-core/target/aarch64-apple-darwin/$CARGO_PROFILE/pck-core-cli"
X86_64_CORE_CLI_PATH="$REPO_ROOT/crates/pck-core/target/x86_64-apple-darwin/$CARGO_PROFILE/pck-core-cli"
CORE_CLI_PATH="$REPO_ROOT/crates/pck-core/target/pck-bottle-universal/$CARGO_PROFILE/pck-core-cli"
ICON_FILE="$PACKAGE_DIR/Assets/PCKBottle.icns"
APP_DIR="$PACKAGE_DIR/build/PCK Bottle.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
LIB_DIR="$CONTENTS_DIR/lib"

if [[ ! -f "$BINARY_PATH" ]]; then
  echo "Built binary not found: $BINARY_PATH" >&2
  exit 1
fi

if [[ ! -f "$ARM64_CORE_CLI_PATH" ]]; then
  echo "Built arm64 PCK core helper not found: $ARM64_CORE_CLI_PATH" >&2
  exit 1
fi

if [[ ! -f "$X86_64_CORE_CLI_PATH" ]]; then
  echo "Built x86_64 PCK core helper not found: $X86_64_CORE_CLI_PATH" >&2
  exit 1
fi

mkdir -p "$(dirname "$CORE_CLI_PATH")"
lipo -create "$ARM64_CORE_CLI_PATH" "$X86_64_CORE_CLI_PATH" -output "$CORE_CLI_PATH"

if [[ ! -f "$CORE_CLI_PATH" ]]; then
  echo "Built PCK core helper not found: $CORE_CLI_PATH" >&2
  exit 1
fi

if [[ ! -f "$ICON_FILE" ]]; then
  echo "App icon not found: $ICON_FILE" >&2
  exit 1
fi

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR" "$LIB_DIR"
cp "$BINARY_PATH" "$MACOS_DIR/PCKBottle"
chmod 755 "$MACOS_DIR/PCKBottle"
cp "$CORE_CLI_PATH" "$RESOURCES_DIR/pck-core-cli"
chmod 755 "$RESOURCES_DIR/pck-core-cli"
cp "$ICON_FILE" "$RESOURCES_DIR/PCKBottle.icns"

SWIFT_STDLIB_TOOL="$(xcrun --find swift-stdlib-tool 2>/dev/null || true)"
if [[ -z "$SWIFT_STDLIB_TOOL" ]]; then
  echo "swift-stdlib-tool not found; cannot package Swift runtime for macOS 10.13." >&2
  exit 1
fi

"$SWIFT_STDLIB_TOOL" \
  --copy \
  --platform macosx \
  --scan-executable "$MACOS_DIR/PCKBottle" \
  --destination "$LIB_DIR" >/dev/null

cat > "$CONTENTS_DIR/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleDisplayName</key>
  <string>PCK Bottle</string>
  <key>CFBundleExecutable</key>
  <string>PCKBottle</string>
  <key>CFBundleIconFile</key>
  <string>PCKBottle.icns</string>
  <key>CFBundleIdentifier</key>
  <string>com.godotpckstudio.pckbottle</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>PCK Bottle</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>${APP_VERSION}</string>
  <key>CFBundleVersion</key>
  <string>${APP_BUILD}</string>
  <key>NSHumanReadableCopyright</key>
  <string>${COPYRIGHT}</string>
  <key>LSApplicationCategoryType</key>
  <string>public.app-category.developer-tools</string>
  <key>LSMinimumSystemVersion</key>
  <string>10.13</string>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSSupportsAutomaticGraphicsSwitching</key>
  <true/>
  <key>CFBundleDocumentTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeName</key>
      <string>Godot PCK Package</string>
      <key>CFBundleTypeRole</key>
      <string>Editor</string>
      <key>LSHandlerRank</key>
      <string>Owner</string>
      <key>LSItemContentTypes</key>
      <array>
        <string>com.godotengine.pck</string>
      </array>
    </dict>
  </array>
  <key>UTImportedTypeDeclarations</key>
  <array>
    <dict>
      <key>UTTypeIdentifier</key>
      <string>com.godotengine.pck</string>
      <key>UTTypeDescription</key>
      <string>Godot PCK Package</string>
      <key>UTTypeConformsTo</key>
      <array>
        <string>public.data</string>
        <string>public.archive</string>
      </array>
      <key>UTTypeTagSpecification</key>
      <dict>
        <key>public.filename-extension</key>
        <array>
          <string>pck</string>
        </array>
      </dict>
    </dict>
  </array>
</dict>
</plist>
PLIST

printf 'APPL????' > "$CONTENTS_DIR/PkgInfo"

# Privacy/size: strip local & debug symbols from the shipped binaries (-x keeps
# only external symbols needed at runtime). Combined with the path remapping
# above this removes residual builder-identifying strings. Must run BEFORE
# signing so the signature covers the stripped binary.
strip -x "$MACOS_DIR/PCKBottle" 2>/dev/null || true
strip -x "$RESOURCES_DIR/pck-core-cli" 2>/dev/null || true

# Ensure the executable can find the bundled Swift runtime in Contents/lib.
# SwiftPM does not always emit this rpath, which would crash the app on Macs
# that don't ship the Swift libraries in the OS (10.13 / 10.14.x).
if ! otool -l "$MACOS_DIR/PCKBottle" | grep -q "@executable_path/../lib"; then
  install_name_tool -add_rpath "@executable_path/../lib" "$MACOS_DIR/PCKBottle" 2>/dev/null || true
fi

# Code signing, inside-out (Apple deprecated --deep for signing). With a real
# Developer ID identity we also enable the hardened runtime + secure timestamp
# that notarization requires; ad-hoc ("-") signing is only for local runs.
CODESIGN_IDENTITY="${CODESIGN_IDENTITY:--}"
if command -v codesign >/dev/null 2>&1; then
  SIGN_FLAGS=(--force --sign "$CODESIGN_IDENTITY")
  if [[ "$CODESIGN_IDENTITY" != "-" ]]; then
    SIGN_FLAGS+=(--options runtime --timestamp)
  fi
  for dylib in "$LIB_DIR"/*.dylib; do
    [[ -e "$dylib" ]] && codesign "${SIGN_FLAGS[@]}" "$dylib" >/dev/null
  done
  codesign "${SIGN_FLAGS[@]}" "$RESOURCES_DIR/pck-core-cli" >/dev/null
  codesign "${SIGN_FLAGS[@]}" "$APP_DIR" >/dev/null
fi

echo "$APP_DIR"
