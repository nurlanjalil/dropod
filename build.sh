#!/bin/bash
# Builds Dropod.app into ./build without Xcode.
# Usage: ./build.sh            build only
#        ./build.sh --run      build, quit any running copy (saving its tabs), launch the new one
#        ./build.sh --install  build, quit any running copy, install to /Applications and launch it
#        ./build.sh --release  build and pack build/Dropod-<version>.zip for a GitHub release
#        ./build.sh --dmg      build and pack build/Dropod.dmg (drag-to-Applications disk image, for releases)
set -euo pipefail
cd "$(dirname "$0")"

APP="build/Dropod.app"
VERSION="0.2.0"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
# Keep build output out of Spotlight and the Apps list: the real Dropod is the one in /Applications.
touch build/.metadata_never_index

swiftc -O -swift-version 5 -target arm64-apple-macos14.0 Sources/*.swift -o "$APP/Contents/MacOS/Dropod"

# The icon is drawn in code; only redraw it when the script changes.
ICNS="build/Dropod.icns"
if [ ! -f "$ICNS" ] || [ scripts/make-icon.swift -nt "$ICNS" ]; then
  WORK="$(mktemp -d)"
  swift scripts/make-icon.swift "$WORK/icon.png"
  mkdir "$WORK/Dropod.iconset"
  for s in 16 32 128 256 512; do
    sips -z $s $s "$WORK/icon.png" --out "$WORK/Dropod.iconset/icon_${s}x${s}.png" >/dev/null
    sips -z $((s * 2)) $((s * 2)) "$WORK/icon.png" --out "$WORK/Dropod.iconset/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns "$WORK/Dropod.iconset" -o "$ICNS"
  rm -rf "$WORK"
fi
cp "$ICNS" "$APP/Contents/Resources/Dropod.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Dropod</string>
  <key>CFBundleDisplayName</key><string>Dropod</string>
  <key>CFBundleIdentifier</key><string>io.github.nurlanjalil.Dropod</string>
  <key>CFBundleExecutable</key><string>Dropod</string>
  <key>CFBundleIconFile</key><string>Dropod</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSDocumentsFolderUsageDescription</key>
  <string>Dropod watches the folder where macOS saves your screenshots, to copy new ones to the clipboard and add them to the Screenshots tab.</string>
  <key>NSDesktopFolderUsageDescription</key>
  <string>Dropod watches the folder where macOS saves your screenshots, to copy new ones to the clipboard and add them to the Screenshots tab.</string>
</dict>
</plist>
PLIST

# Sign with the personal certificate "Dropod Local Signing" when it exists: its identity stays
# the same across builds, so macOS remembers folder access and the login item. Without it,
# sign ad hoc (macOS then sees every build as a new app and asks again).
IDENTITY="${SIGN_IDENTITY:-Dropod Local Signing}"
if security find-identity -p codesigning 2>/dev/null | grep -q "\"$IDENTITY\""; then
  codesign --force --sign "$IDENTITY" "$APP"
  echo "Signed with $IDENTITY"
else
  codesign --force --sign - "$APP" >/dev/null
  echo "Signed ad hoc (create the \"$IDENTITY\" certificate to keep permissions across builds)"
fi
echo "Built $APP"

# Quit politely so Dropod saves its tabs; force it only if it doesn't respond.
quit_app() {
  if pgrep -x Dropod >/dev/null; then
    # Ask nicely, but don't wait forever: an open dialog (such as a permission prompt) blocks the quit.
    osascript -e 'quit app "Dropod"' >/dev/null 2>&1 &
    local asking=$!
    for _ in 1 2 3 4 5 6 7 8 9 10; do kill -0 $asking 2>/dev/null || break; sleep 0.5; done
    kill $asking 2>/dev/null || true
    for _ in 1 2 3 4 5 6 7 8 9 10; do pgrep -x Dropod >/dev/null || break; sleep 0.3; done
    pkill -x Dropod 2>/dev/null || true
  fi
}

case "${1:-}" in
  --dmg)
    # A disk image with the app next to an Applications shortcut: open it, drag one onto the other.
    # Named without a version, so releases/latest/download/Dropod.dmg always gets the newest.
    DMG="build/Dropod.dmg"
    STAGE="$(mktemp -d)/Dropod"
    mkdir -p "$STAGE"
    cp -R "$APP" "$STAGE/"
    ln -s /Applications "$STAGE/Applications"
    rm -f "$DMG"
    hdiutil create -volname "Dropod" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG" >/dev/null
    rm -rf "$(dirname "$STAGE")"
    echo "Packed $DMG"
    ;;
  --release)
    # A zip that keeps the app's signature and attributes intact, for a GitHub release.
    ZIP="build/Dropod-${VERSION}.zip"
    rm -f "$ZIP"
    ditto -c -k --keepParent "$APP" "$ZIP"
    echo "Packed $ZIP"
    ;;
  --run)
    quit_app
    open "$APP"
    ;;
  --install)
    quit_app
    # The app used to be called Stash: quit it and remove it, so only Dropod remains.
    if pgrep -x Stash >/dev/null; then
      osascript -e 'quit app "Stash"' >/dev/null 2>&1 & sleep 2; kill $! 2>/dev/null || true
      pkill -x Stash 2>/dev/null || true
    fi
    rm -rf /Applications/Stash.app
    rm -rf /Applications/Dropod.app
    # Move, not copy, so there is only ever one Dropod app on the Mac.
    mv "$APP" /Applications/Dropod.app
    echo "Installed /Applications/Dropod.app"
    open /Applications/Dropod.app
    ;;
esac
