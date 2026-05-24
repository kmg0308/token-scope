#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="TokenMeter"
EXECUTABLE_NAME="TokenMeter"
VERSION="${VERSION:-0.1.0}"
BUILD_NUMBER="${BUILD_NUMBER:-$(date +%Y%m%d%H%M)}"
BUILD_COMMIT="${BUILD_COMMIT:-$(git -C "$ROOT_DIR" rev-parse --short HEAD 2>/dev/null || echo dev)}"
DIST_DIR="$ROOT_DIR/dist"
APP_DIR="$DIST_DIR/$APP_NAME.app"

xml_escape() {
    local value="$1"
    value="${value//&/&amp;}"
    value="${value//</&lt;}"
    value="${value//>/&gt;}"
    printf '%s' "$value"
}

json_escape() {
    local value="$1"
    value="${value//\\/\\\\}"
    value="${value//\"/\\\"}"
    value="${value//$'\n'/\\n}"
    value="${value//$'\r'/\\r}"
    value="${value//$'\t'/\\t}"
    printf '%s' "$value"
}

cd "$ROOT_DIR"

swift run TokenMeterSelfTest
swift build -c release --product TokenMeter -Xswiftc -warnings-as-errors

BIN_DIR="$(swift build -c release --show-bin-path)"
rm -rf "$DIST_DIR/TokenMeter.app"
rm -f "$DIST_DIR"/TokenMeter-*.zip "$DIST_DIR"/TokenMeter-*.pkg "$DIST_DIR/$APP_NAME.zip" "$DIST_DIR/$APP_NAME.pkg"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$BIN_DIR/$EXECUTABLE_NAME" "$APP_DIR/Contents/MacOS/$EXECUTABLE_NAME"
chmod +x "$APP_DIR/Contents/MacOS/$EXECUTABLE_NAME"
swift "$ROOT_DIR/scripts/make_icon.swift" "$APP_DIR/Contents/Resources/TokenMeter.icns"

PLIST_APP_NAME="$(xml_escape "$APP_NAME")"
PLIST_EXECUTABLE_NAME="$(xml_escape "$EXECUTABLE_NAME")"
PLIST_VERSION="$(xml_escape "$VERSION")"
PLIST_BUILD_NUMBER="$(xml_escape "$BUILD_NUMBER")"
PLIST_BUILD_COMMIT="$(xml_escape "$BUILD_COMMIT")"
JSON_APP_NAME="$(json_escape "$APP_NAME")"
JSON_VERSION="$(json_escape "$VERSION")"
JSON_BUILD_NUMBER="$(json_escape "$BUILD_NUMBER")"
JSON_BUILD_COMMIT="$(json_escape "$BUILD_COMMIT")"

cat > "$APP_DIR/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>$PLIST_EXECUTABLE_NAME</string>
    <key>CFBundleIdentifier</key>
    <string>local.tokenmeter.app</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>$PLIST_APP_NAME</string>
    <key>CFBundleIconFile</key>
    <string>TokenMeter</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$PLIST_VERSION</string>
    <key>CFBundleVersion</key>
    <string>$PLIST_BUILD_NUMBER</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSHumanReadableCopyright</key>
    <string>Local-only token usage viewer.</string>
    <key>TokenMeterBuildCommit</key>
    <string>$PLIST_BUILD_COMMIT</string>
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
COMPONENT_PLIST="$DIST_DIR/$APP_NAME-component.plist"
PKG_ROOT="$DIST_DIR/pkgroot"
trap 'rm -rf "$COMPONENT_PLIST" "$PKG_ROOT"' EXIT
rm -f "$ZIP_PATH"
(
    cd "$DIST_DIR"
    ditto -c -k --norsrc --noextattr --noqtn --keepParent "$APP_NAME.app" "$ZIP_PATH"
)
cp "$ZIP_PATH" "$FIXED_ZIP_PATH"

rm -f "$PKG_PATH"
cat > "$COMPONENT_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<array>
    <dict>
        <key>BundleHasStrictIdentifier</key>
        <true/>
        <key>BundleIsRelocatable</key>
        <false/>
        <key>BundleIsVersionChecked</key>
        <true/>
        <key>BundleOverwriteAction</key>
        <string>upgrade</string>
        <key>RootRelativeBundlePath</key>
        <string>./$APP_NAME.app</string>
    </dict>
</array>
</plist>
PLIST
rm -rf "$PKG_ROOT"
mkdir -p "$PKG_ROOT"
ditto "$APP_DIR" "$PKG_ROOT/$APP_NAME.app"
pkgbuild \
    --root "$PKG_ROOT" \
    --component-plist "$COMPONENT_PLIST" \
    --install-location "/Applications" \
    --identifier "local.tokenmeter.app.pkg" \
    --version "$VERSION" \
    "$PKG_PATH" >/dev/null
cp "$PKG_PATH" "$FIXED_PKG_PATH"

cat > "$DIST_DIR/manifest.json" <<JSON
{
  "name": "$JSON_APP_NAME",
  "version": "$JSON_VERSION",
  "build": "$JSON_BUILD_NUMBER",
  "commit": "$JSON_BUILD_COMMIT",
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
