#!/bin/bash
# Builds "Gruppen.app" from Sources/ using the Swift compiler that ships with
# the Xcode Command Line Tools. No Xcode project required.
#
#   ./build.sh              build into ./build
#   ./build.sh --install    build, then replace /Applications/Gruppen.app
#   ./build.sh --run        build and launch
#   ./build.sh --dmg        build, then package a shareable Gruppen-<ver>.dmg
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="Gruppen"
BUNDLE_ID="com.dhilanpatel.gruppen"
EXECUTABLE="Gruppen"
VERSION="4.02"
BUILD_NUMBER="$(date +%Y%m%d%H%M)"
MIN_MACOS="13.0"

BUILD_DIR="build"
APP_DIR="$BUILD_DIR/$APP_NAME.app"
SDK="$(xcrun --show-sdk-path)"
ARCH="$(uname -m)"

INSTALL=0
RUN=0
DMG=0
for arg in "$@"; do
    case "$arg" in
        --install) INSTALL=1 ;;
        --run) RUN=1 ;;
        --dmg) DMG=1 ;;
        *) echo "unknown option: $arg" >&2; exit 2 ;;
    esac
done

rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"

echo "Compiling $APP_NAME $VERSION ($BUILD_NUMBER) for $ARCH…"
xcrun swiftc \
    -O \
    -whole-module-optimization \
    -parse-as-library \
    -sdk "$SDK" \
    -target "$ARCH-apple-macos$MIN_MACOS" \
    -o "$APP_DIR/Contents/MacOS/$EXECUTABLE" \
    $(find Sources -name '*.swift' | sort)

cat > "$APP_DIR/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>$APP_NAME</string>
    <key>CFBundleDisplayName</key><string>$APP_NAME</string>
    <key>CFBundleExecutable</key><string>$EXECUTABLE</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
    <key>LSMinimumSystemVersion</key><string>$MIN_MACOS</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSHumanReadableCopyright</key><string>Copyright © $(date +%Y) Dhilan Patel. All rights reserved.</string>
    <key>NSSupportsAutomaticTermination</key><false/>
    <key>NSSupportsSuddenTermination</key><false/>
</dict>
</plist>
PLIST

if [ -f "Resources/AppIcon.icns" ]; then
    cp "Resources/AppIcon.icns" "$APP_DIR/Contents/Resources/AppIcon.icns"
fi

# Ad-hoc signature. Enough for local use and for a stable TCC identity; ship to
# other machines only after signing with a Developer ID and notarising, or
# Gatekeeper will block it.
echo "Signing (ad-hoc)…"
codesign --force --sign - --timestamp=none "$APP_DIR" >/dev/null 2>&1

echo "Built $APP_DIR"

if [ "$DMG" = "1" ]; then
    DMG_NAME="$APP_NAME-$VERSION.dmg"
    STAGING="$BUILD_DIR/dmg-staging"
    rm -rf "$STAGING" "$BUILD_DIR/$DMG_NAME"
    mkdir -p "$STAGING"

    cp -R "$APP_DIR" "$STAGING/$APP_NAME.app"
    ln -s /Applications "$STAGING/Applications"

    # The build is ad-hoc signed, so Gatekeeper will refuse a plain double
    # click on someone else's Mac. Ship the one-time workaround alongside it
    # rather than letting people hit a dead end.
    cat > "$STAGING/READ ME FIRST.txt" <<'NOTE'
Gruppen — first launch
======================

1. Drag Gruppen onto the Applications folder in this window.

2. The first time you open it, macOS will say Gruppen "cannot be opened
   because it is from an unidentified developer", or that it is damaged.
   This is expected: the app is signed ad-hoc rather than with a paid
   Apple Developer ID. It is not a sign that anything is wrong with it.

   To open it anyway, either:

   a) Right-click (or Control-click) Gruppen in Applications and choose
      "Open", then click "Open" in the dialog. You only do this once.

   or, if macOS refuses outright:

   b) Open Terminal and run:
        xattr -dr com.apple.quarantine /Applications/Gruppen.app

3. Gruppen needs no special permissions. It launches and force quits the
   apps you group together, nothing else.

What it does
------------
Group your applications, launch a whole group with one click or one global
hotkey, and force close the group when you are done with that context.

  • Snapshot   turns whatever you have open right now into a Gruppe
  • Sequence   launches 1 -> N in order and terminates N -> 1 in reverse
  • Presets    suggests Gruppen based on what is installed
NOTE

    echo "Packaging $DMG_NAME…"
    hdiutil create \
        -volname "$APP_NAME $VERSION" \
        -srcfolder "$STAGING" \
        -ov -format UDZO \
        "$BUILD_DIR/$DMG_NAME" >/dev/null

    rm -rf "$STAGING"
    echo "Packaged $BUILD_DIR/$DMG_NAME ($(du -h "$BUILD_DIR/$DMG_NAME" | cut -f1))"
fi

if [ "$INSTALL" = "1" ]; then
    DEST="/Applications/$APP_NAME.app"
    if pgrep -x "$EXECUTABLE" >/dev/null; then
        echo "Quitting running $APP_NAME…"
        osascript -e "quit app \"$APP_NAME\"" 2>/dev/null || pkill -x "$EXECUTABLE" || true
        sleep 1
    fi
    rm -rf "$DEST"
    cp -R "$APP_DIR" "$DEST"
    echo "Installed $DEST"
    if [ "$RUN" = "1" ]; then open "$DEST"; fi
elif [ "$RUN" = "1" ]; then
    open "$APP_DIR"
fi
