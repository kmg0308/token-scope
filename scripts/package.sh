#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="TokenMeter"
EXECUTABLE_NAME="TokenMeter"
VERSION="${VERSION:-0.1.0}"
BUILD_NUMBER="${BUILD_NUMBER:-$(date +%Y%m%d%H%M)}"
BUILD_COMMIT="${BUILD_COMMIT:-$(git -C "$ROOT_DIR" rev-parse --short HEAD 2>/dev/null || echo dev)}"
DEFAULT_REPOSITORY="${DEFAULT_REPOSITORY:-${GITHUB_REPOSITORY:-}}"
if [[ -z "$DEFAULT_REPOSITORY" ]]; then
    ORIGIN_URL="$(git -C "$ROOT_DIR" config --get remote.origin.url 2>/dev/null || true)"
    if [[ "$ORIGIN_URL" =~ github.com[:/]([^/]+)/([^/.]+)(\.git)?$ ]]; then
        DEFAULT_REPOSITORY="${BASH_REMATCH[1]}/${BASH_REMATCH[2]}"
    fi
fi
DIST_DIR="$ROOT_DIR/dist"
APP_DIR="$DIST_DIR/$APP_NAME.app"

cd "$ROOT_DIR"

swift run TokenMeterSelfTest
swift build -c release --product TokenMeter

BIN_DIR="$(swift build -c release --show-bin-path)"
rm -rf "$DIST_DIR/TokenMeter.app"
rm -f "$DIST_DIR"/TokenMeter-*.zip "$DIST_DIR"/TokenMeter-*.pkg "$DIST_DIR/$APP_NAME.zip" "$DIST_DIR/$APP_NAME.pkg"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$BIN_DIR/$EXECUTABLE_NAME" "$APP_DIR/Contents/MacOS/$EXECUTABLE_NAME"
chmod +x "$APP_DIR/Contents/MacOS/$EXECUTABLE_NAME"
swift "$ROOT_DIR/scripts/make_icon.swift" "$APP_DIR/Contents/Resources/TokenMeter.icns"

cat > "$APP_DIR/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>$EXECUTABLE_NAME</string>
    <key>CFBundleIdentifier</key>
    <string>local.tokenmeter.app</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>TokenMeter</string>
    <key>CFBundleIconFile</key>
    <string>TokenMeter</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>CFBundleVersion</key>
    <string>$BUILD_NUMBER</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSHumanReadableCopyright</key>
    <string>Local-only token usage viewer.</string>
    <key>TSBuildCommit</key>
    <string>$BUILD_COMMIT</string>
    <key>TSGitHubRepository</key>
    <string>$DEFAULT_REPOSITORY</string>
</dict>
</plist>
PLIST

if command -v codesign >/dev/null 2>&1; then
    codesign --force --deep --sign - "$APP_DIR" >/dev/null
fi

if command -v xattr >/dev/null 2>&1; then
    xattr -cr "$APP_DIR"
fi

ZIP_PATH="$DIST_DIR/$APP_NAME-$VERSION.zip"
PKG_PATH="$DIST_DIR/$APP_NAME-$VERSION.pkg"
FIXED_ZIP_PATH="$DIST_DIR/$APP_NAME.zip"
FIXED_PKG_PATH="$DIST_DIR/$APP_NAME.pkg"
rm -f "$ZIP_PATH"
(
    cd "$DIST_DIR"
    ditto -c -k --norsrc --noextattr --noqtn --keepParent "$APP_NAME.app" "$ZIP_PATH"
)
cp "$ZIP_PATH" "$FIXED_ZIP_PATH"

rm -f "$PKG_PATH"
pkgbuild \
    --component "$APP_DIR" \
    --install-location "/Applications" \
    --identifier "local.tokenmeter.app.pkg" \
    --version "$VERSION" \
    "$PKG_PATH" >/dev/null
cp "$PKG_PATH" "$FIXED_PKG_PATH"

cat > "$DIST_DIR/manifest.json" <<JSON
{
  "name": "$APP_NAME",
  "version": "$VERSION",
  "build": "$BUILD_NUMBER",
  "commit": "$BUILD_COMMIT",
  "zip": "$(basename "$ZIP_PATH")",
  "pkg": "$(basename "$PKG_PATH")",
  "latestZip": "$(basename "$FIXED_ZIP_PATH")",
  "latestPkg": "$(basename "$FIXED_PKG_PATH")"
}
JSON

echo "Built $APP_DIR"
echo "Built $ZIP_PATH"
echo "Built $PKG_PATH"
echo "Built $FIXED_ZIP_PATH"
echo "Built $FIXED_PKG_PATH"
