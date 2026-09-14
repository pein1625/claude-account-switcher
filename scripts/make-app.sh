#!/usr/bin/env bash
# Assemble build/ClaudeSwitcher.app from the SwiftPM release binary (no Xcode needed) and ad-hoc sign it.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="${BIN:-$ROOT/.build/release/ClaudeSwitcher}"   # override with the universal binary from `make dist`
APP="$ROOT/build/ClaudeSwitcher.app"
[ -x "$BIN" ] || { echo "make-app: build first (swift build -c release)" >&2; exit 1; }

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/ClaudeSwitcher"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
[ -f "$ROOT/build/AppIcon.icns" ] && cp "$ROOT/build/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
printf 'APPL????' > "$APP/Contents/PkgInfo"
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || echo "make-app: warning: codesign failed (app still runs)" >&2
echo "built  $APP"
