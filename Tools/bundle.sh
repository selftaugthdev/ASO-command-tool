#!/bin/bash
# Wraps the SwiftPM executable in a .app bundle.
#
# A bare SwiftPM executable can show SwiftUI windows, but without a bundle it has
# no Info.plist, so it launches as a background process with no Dock icon and no
# menu bar focus. This produces a normal double-clickable app.
set -euo pipefail

cd "$(dirname "$0")/.."

APP_NAME="ASO Command Center"
BUNDLE_ID="com.thierry.asocommandcenter"
BINARY=".build/release/ASOCommandCenter"
DIST="dist"
APP="$DIST/$APP_NAME.app"

if [ ! -f "$BINARY" ]; then
    echo "error: $BINARY not found. Run 'make release' first." >&2
    exit 1
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BINARY" "$APP/Contents/MacOS/$APP_NAME"
chmod +x "$APP/Contents/MacOS/$APP_NAME"

# The icon is only picked up when both the file is present and CFBundleIconFile
# names it; a bundle missing either shows the generic white page in Finder.
ICON_ENTRY=""
if [ -f "Resources/AppIcon.icns" ]; then
    cp "Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
    ICON_ENTRY="    <key>CFBundleIconFile</key>          <string>AppIcon</string>"
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>              <string>$APP_NAME</string>
    <key>CFBundleDisplayName</key>       <string>$APP_NAME</string>
    <key>CFBundleIdentifier</key>        <string>$BUNDLE_ID</string>
    <key>CFBundleExecutable</key>        <string>$APP_NAME</string>
$ICON_ENTRY
    <key>CFBundlePackageType</key>       <string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key>           <string>1</string>
    <key>LSMinimumSystemVersion</key>    <string>14.0</string>
    <key>NSHighResolutionCapable</key>   <true/>
    <!-- Regular app: Dock icon and menu bar, not a background agent. -->
    <key>LSUIElement</key>               <false/>
</dict>
</plist>
PLIST

# Sign with a real identity when one exists.
#
# This matters more than it looks. An ad-hoc signature ("-") produces a
# different code identity on every build, and the Keychain binds its
# "Always Allow" decision to that identity — so every rebuild invalidates it
# and macOS asks for your password again. A stable Apple Development identity
# keeps the ACL valid across rebuilds, so you approve access once.
IDENTITY="${CODESIGN_IDENTITY:-}"
if [ -z "$IDENTITY" ]; then
    IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null \
        | grep "Apple Development" \
        | /usr/bin/head -1 \
        | sed -E 's/.*"(.*)"/\1/')
fi

if [ -n "$IDENTITY" ]; then
    codesign --force --deep --sign "$IDENTITY" \
        --identifier "$BUNDLE_ID" \
        --options runtime \
        "$APP"
    echo "Signed with: $IDENTITY"
else
    codesign --force --deep --sign - --identifier "$BUNDLE_ID" "$APP" 2>/dev/null \
        || true
    echo "warning: no Apple Development identity found; signed ad-hoc." >&2
    echo "         macOS will re-prompt for Keychain access after every rebuild." >&2
fi

echo "Built $APP"
