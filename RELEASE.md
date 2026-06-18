# Releasing PCK Bottle

This document covers how a macOS `.dmg` of PCK Bottle is built, signed, and
published.

## TL;DR

```bash
# 1. Bump the version
echo "1.1.0" > VERSION

# 2. Build the universal .app
CONFIGURATION=release bash macos/PCKBottle/scripts/build-app.sh

# 3. Package a .dmg (app + drag-to-install /Applications symlink)
bash macos/PCKBottle/scripts/make-dmg.sh

# 4. Tag to trigger the GitHub Actions release
git tag v1.1.0 && git push origin v1.1.0
```

The version lives in a single place — the repo-root [`VERSION`](VERSION) file.
`build-app.sh` reads it into `CFBundleShortVersionString`; CI derives it from
the pushed `vX.Y.Z` tag and passes a timestamp as `CFBundleVersion`.

## Signing & notarization

There are two distribution modes.

### A. Unsigned (no Apple Developer account) — the default

The build ad-hoc signs the app (`codesign --sign -`), which is enough to run
locally but **not** for distribution. When another user downloads the `.dmg`,
Gatekeeper will block it ("damaged" / "unidentified developer"). They clear the
download quarantine once:

```bash
xattr -dr com.apple.quarantine "/Applications/PCK Bottle.app"
```

This is documented for users in [README.md](README.md). It is the zero-cost
open-source path.

### B. Signed + notarized (Developer ID) — no scary prompts

Requires a paid Apple Developer Program membership and a **Developer ID
Application** certificate. The `.dmg` then opens with a normal double-click.

`build-app.sh` already signs **inside-out** (each `Contents/lib/*.dylib`, then
the bundled `pck-core-cli` helper, then the app bundle) and — when given a real
identity via `CODESIGN_IDENTITY` — adds the hardened runtime (`--options
runtime`) and a secure timestamp, both of which notarization requires.

Local signed build:

```bash
CODESIGN_IDENTITY="Developer ID Application: NAME (TEAMID)" \
  CONFIGURATION=release bash macos/PCKBottle/scripts/build-app.sh

APP="macos/PCKBottle/build/PCK Bottle.app"
ditto -c -k --keepParent "$APP" notarize.zip
xcrun notarytool submit notarize.zip \
  --apple-id "you@example.com" --team-id "TEAMID" \
  --password "app-specific-password" --wait
xcrun stapler staple "$APP"
bash macos/PCKBottle/scripts/make-dmg.sh   # re-package the stapled app
```

## CI (GitHub Actions)

[`.github/workflows/release.yml`](.github/workflows/release.yml) builds the
universal app, packages the `.dmg`, and attaches it to a GitHub Release on every
`v*` tag. Signing and notarization run **only if** the matching secrets are set,
so the workflow works out of the box for unsigned releases.

To enable mode B, add these repository secrets:

| Secret | Purpose |
|--------|---------|
| `MACOS_CERT_P12_BASE64` | base64 of your Developer ID `.p12` |
| `MACOS_CERT_PASSWORD` | password for the `.p12` |
| `KEYCHAIN_PASSWORD` | any password for the temporary CI keychain |
| `MACOS_SIGN_IDENTITY` | e.g. `Developer ID Application: NAME (TEAMID)` |
| `APPLE_ID` | Apple ID email for notarytool |
| `APPLE_TEAM_ID` | your 10-char team id |
| `APPLE_APP_SPECIFIC_PASSWORD` | app-specific password for notarytool |

## Known limitation: bundled Swift runtime architecture

`build-app.sh` uses `swift-stdlib-tool` to copy the Swift runtime into
`Contents/lib` so the app can run on macOS 10.13–10.14.x (where Swift is not in
the OS). On current toolchains these bundled dylibs are **x86_64-only**.

This is safe in practice:

- Apple Silicon Macs only run macOS 11+, where the Swift runtime ships in the OS
  (`/usr/lib/swift`) and the bundled libs are never consulted.
- Intel Macs on 10.13/10.14 get the x86_64 libs they need.

So the only theoretical gap — an arm64 Mac on macOS < 10.15 — does not exist.
The main executable and the `pck-core-cli` helper are both universal
(x86_64 + arm64). If a future toolchain ships universal back-deployment libs,
no change is needed.
