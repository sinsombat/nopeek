#!/usr/bin/env bash
#
# Assemble build/NoPeek.app from the SwiftPM release build and ad-hoc sign it.
#
# Usage:   scripts/build-app.sh
# Output:  build/NoPeek.app  (bundle id com.sinsombat.nopeek, LSUIElement, signed ad-hoc)
#
# Spec §9: no Developer ID — the app is built locally and signed ad-hoc, so it is
# never quarantined. The SwiftPM product is named NoPeekApp; the bundle's
# executable is renamed to NoPeek because the LaunchAgent's Program path points
# at `<app>/Contents/MacOS/NoPeek`.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

APP_DIR="$ROOT_DIR/build/NoPeek.app"
CONTENTS_DIR="$APP_DIR/Contents"
EXECUTABLE_NAME="NoPeek"
BUNDLE_ID="com.sinsombat.nopeek"
BUNDLE_VERSION="1.0.1"
MINIMUM_SYSTEM_VERSION="26.0"

cd "$ROOT_DIR"

echo "==> swift build -c release"
swift build -c release

BIN_DIR="$(swift build -c release --show-bin-path)"
BUILT_EXECUTABLE="$BIN_DIR/NoPeekApp"
if [ ! -x "$BUILT_EXECUTABLE" ]; then
    echo "error: release executable not found at $BUILT_EXECUTABLE" >&2
    exit 1
fi

echo "==> assembling $APP_DIR"
rm -rf "$APP_DIR"
mkdir -p "$CONTENTS_DIR/MacOS"
cp "$BUILT_EXECUTABLE" "$CONTENTS_DIR/MacOS/$EXECUTABLE_NAME"

# App icon: resources/AppIcon-1024.png → Contents/Resources/AppIcon.icns. Built
# here (not committed as .icns) so the source PNG stays the single source of
# truth; `sips` + `iconutil` are present on macOS everywhere, CI included.
ICON_SOURCE="$ROOT_DIR/resources/AppIcon-1024.png"
if [ ! -f "$ICON_SOURCE" ]; then
    echo "error: icon source not found at $ICON_SOURCE" >&2
    exit 1
fi
echo "==> app icon (AppIcon-1024.png → AppIcon.icns)"
ICONSET="$ROOT_DIR/build/AppIcon.iconset"
rm -rf "$ICONSET"
mkdir -p "$ICONSET" "$CONTENTS_DIR/Resources"
for size in 16 32 128 256 512; do
    sips -z "$size" "$size" "$ICON_SOURCE" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    sips -z "$((size * 2))" "$((size * 2))" "$ICON_SOURCE" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$CONTENTS_DIR/Resources/AppIcon.icns"
rm -rf "$ICONSET"

# No usage-description keys on purpose: NoPeek never asks for a TCC permission
# (spec §9). `LSUIElement` keeps it out of the Dock and the app switcher.
cat > "$CONTENTS_DIR/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleExecutable</key>
	<string>$EXECUTABLE_NAME</string>
	<key>CFBundleIconFile</key>
	<string>AppIcon</string>
	<key>CFBundleIdentifier</key>
	<string>$BUNDLE_ID</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleName</key>
	<string>$EXECUTABLE_NAME</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>$BUNDLE_VERSION</string>
	<key>CFBundleVersion</key>
	<string>$BUNDLE_VERSION</string>
	<key>LSMinimumSystemVersion</key>
	<string>$MINIMUM_SYSTEM_VERSION</string>
	<key>LSUIElement</key>
	<true/>
	<key>NSHumanReadableCopyright</key>
	<string>© 2026 Sinsombat. Ad-hoc signed, not notarized.</string>
</dict>
</plist>
PLIST

plutil -lint "$CONTENTS_DIR/Info.plist"

echo "==> ad-hoc codesign"
# No --deep: deprecated by Apple and never needed for a single-executable
# bundle (there are no nested frameworks or helpers to sign).
codesign --force -s - "$APP_DIR"
codesign --verify --verbose=2 "$APP_DIR"

echo "==> built $APP_DIR ($BUNDLE_ID, min macOS $MINIMUM_SYSTEM_VERSION, v$BUNDLE_VERSION)"
