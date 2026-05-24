#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="${VERSION:-0.1.0}"
cd "$ROOT_DIR"

"$ROOT_DIR/scripts/package.sh"
test -d "$ROOT_DIR/dist/TokenMeter.app"
test -f "$ROOT_DIR/dist/TokenMeter-$VERSION.zip"
test -f "$ROOT_DIR/dist/TokenMeter-$VERSION.pkg"
test -f "$ROOT_DIR/dist/TokenMeter.zip"
test -f "$ROOT_DIR/dist/TokenMeter.pkg"
test -f "$ROOT_DIR/dist/manifest.json"
python3 -m json.tool "$ROOT_DIR/dist/manifest.json" >/dev/null
unzip -l "$ROOT_DIR/dist/TokenMeter.zip" "TokenMeter.app/Contents/MacOS/TokenMeter" >/dev/null
test -f "$ROOT_DIR/dist/TokenMeter.app/Contents/Resources/TokenMeter.icns"
codesign --verify --deep --strict "$ROOT_DIR/dist/TokenMeter.app"
plutil -lint "$ROOT_DIR/dist/TokenMeter.app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Print :CFBundleName' "$ROOT_DIR/dist/TokenMeter.app/Contents/Info.plist" | grep -qx 'TokenMeter'
/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$ROOT_DIR/dist/TokenMeter.app/Contents/Info.plist" | grep -qx 'TokenMeter'
/usr/libexec/PlistBuddy -c 'Print :CFBundlePackageType' "$ROOT_DIR/dist/TokenMeter.app/Contents/Info.plist" | grep -qx 'APPL'
/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT_DIR/dist/TokenMeter.app/Contents/Info.plist" | grep -q '[^[:space:]]'
/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$ROOT_DIR/dist/TokenMeter.app/Contents/Info.plist" | grep -q '[^[:space:]]'
/usr/libexec/PlistBuddy -c 'Print :TokenMeterBuildCommit' "$ROOT_DIR/dist/TokenMeter.app/Contents/Info.plist" >/dev/null
if /usr/libexec/PlistBuddy -c 'Print :TSBuildCommit' "$ROOT_DIR/dist/TokenMeter.app/Contents/Info.plist" >/dev/null 2>&1; then
    echo "Info.plist must not contain old TSBuildCommit" >&2
    exit 1
fi
if /usr/libexec/PlistBuddy -c 'Print :LSUIElement' "$ROOT_DIR/dist/TokenMeter.app/Contents/Info.plist" >/dev/null 2>&1; then
    echo "Info.plist must not make TokenMeter a menu-bar-only app" >&2
    exit 1
fi
if /usr/libexec/PlistBuddy -c 'Print :LSBackgroundOnly' "$ROOT_DIR/dist/TokenMeter.app/Contents/Info.plist" >/dev/null 2>&1; then
    echo "Info.plist must not make TokenMeter a background-only app" >&2
    exit 1
fi
if /usr/libexec/PlistBuddy -c 'Print :TSGitHubRepository' "$ROOT_DIR/dist/TokenMeter.app/Contents/Info.plist" >/dev/null 2>&1; then
    echo "Info.plist must not contain unused TSGitHubRepository" >&2
    exit 1
fi
pkgutil --check-signature "$ROOT_DIR/dist/TokenMeter-$VERSION.pkg" >/dev/null || true
pkgutil --check-signature "$ROOT_DIR/dist/TokenMeter.pkg" >/dev/null || true
PKG_CHECK_PARENT="$(mktemp -d)"
PKG_CHECK_DIR="$PKG_CHECK_PARENT/pkg-expanded"
trap 'rm -rf "$PKG_CHECK_PARENT"' EXIT
pkgutil --expand-full "$ROOT_DIR/dist/TokenMeter.pkg" "$PKG_CHECK_DIR" >/dev/null
grep -q 'install-location="/Applications"' "$PKG_CHECK_DIR/PackageInfo"
grep -q 'relocatable="false"' "$PKG_CHECK_DIR/PackageInfo"
grep -q '<relocate/>' "$PKG_CHECK_DIR/PackageInfo"
if grep -q "<relocate>" "$PKG_CHECK_DIR/PackageInfo"; then
    echo "TokenMeter.pkg must not relocate existing app bundles" >&2
    exit 1
fi

echo "verify passed"
