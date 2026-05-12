#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

swift run TokenMeterSelfTest
swift build -c release --product TokenMeter
"$ROOT_DIR/scripts/package.sh"
test -d "$ROOT_DIR/dist/TokenMeter.app"
test -f "$ROOT_DIR/dist/TokenMeter-0.1.0.zip"
test -f "$ROOT_DIR/dist/TokenMeter-0.1.0.pkg"
test -f "$ROOT_DIR/dist/TokenMeter.zip"
test -f "$ROOT_DIR/dist/TokenMeter.pkg"
unzip -l "$ROOT_DIR/dist/TokenMeter.zip" "TokenMeter.app/Contents/MacOS/TokenMeter" >/dev/null
test -f "$ROOT_DIR/dist/TokenMeter.app/Contents/Resources/TokenMeter.icns"
codesign --verify --deep --strict "$ROOT_DIR/dist/TokenMeter.app"
plutil -lint "$ROOT_DIR/dist/TokenMeter.app/Contents/Info.plist"
pkgutil --check-signature "$ROOT_DIR/dist/TokenMeter-0.1.0.pkg" >/dev/null || true
pkgutil --check-signature "$ROOT_DIR/dist/TokenMeter.pkg" >/dev/null || true
PKG_CHECK_PARENT="$(mktemp -d)"
PKG_CHECK_DIR="$PKG_CHECK_PARENT/pkg-expanded"
trap 'rm -rf "$PKG_CHECK_PARENT"' EXIT
pkgutil --expand-full "$ROOT_DIR/dist/TokenMeter.pkg" "$PKG_CHECK_DIR" >/dev/null
grep -q 'install-location="/Applications"' "$PKG_CHECK_DIR/PackageInfo"
if grep -q "<relocate>" "$PKG_CHECK_DIR/PackageInfo"; then
    echo "TokenMeter.pkg must not relocate existing app bundles" >&2
    exit 1
fi

echo "verify passed"
