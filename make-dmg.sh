#!/usr/bin/env bash
# ============================================================================
# make-dmg.sh <version> [app-path]   (e.g. make-dmg.sh 1.2.5)
#
# Packages the (already signed) Mallow.app into a STYLED, compressed DMG: a
# branded background image, hidden toolbar/sidebar, sized window, and the app +
# Applications-symlink icons arranged with a drag arrow between them.
#
# Pipeline position (see docs/security/sparkle-update-security.md):
#   build-app.sh  →  make-dmg.sh <ver>  →  notarize-dmg.sh <dmg>  →  make-appcast.sh <ver>
# (Notarization staples INTO this DMG, changing its bytes, so make-appcast.sh
#  must run AFTER notarize-dmg.sh.)
#
# The background is AppBundle/dmg-background.tiff (a hi-DPI TIFF). Regenerate it
# from AppBundle/dmg-background.html after editing the design:
#   CHROME=/Applications/Google\ Chrome.app/Contents/MacOS/Google\ Chrome
#   "$CHROME" --headless=new --hide-scrollbars --force-device-scale-factor=2 \
#     --window-size=640,420 --screenshot=/tmp/bg@2x.png file://$PWD/AppBundle/dmg-background.html
#   sips -z 420 640 /tmp/bg@2x.png --out /tmp/bg.png
#   tiffutil -cathidpicheck /tmp/bg.png /tmp/bg@2x.png -out AppBundle/dmg-background.tiff
# ============================================================================
set -euo pipefail
cd "$(dirname "$0")"

VER="${1:?usage: make-dmg.sh <version> [app-path]}"
APP="${2:-.build/Mallow.app}"
VOL="Mallow"
DMG_OUT="Mallow_${VER}_aarch64.dmg"
BG_TIFF="AppBundle/dmg-background.tiff"

[ -d "$APP" ]     || { echo "error: app not found at $APP (run ./build-app.sh first)." >&2; exit 1; }
[ -f "$BG_TIFF" ] || { echo "error: $BG_TIFF missing — regen from AppBundle/dmg-background.html." >&2; exit 1; }

# ---- 1. stage the DMG contents (app + /Applications link + hidden background) ----
WORK="$(mktemp -d)"
STAGE="$WORK/stage"
mkdir -p "$STAGE/.background"
cp -R "$APP" "$STAGE/Mallow.app"
ln -s /Applications "$STAGE/Applications"
cp "$BG_TIFF" "$STAGE/.background/background.tiff"

# ---- 2. create a writable DMG with slack so Finder can write .DS_Store ----
SIZE_MB=$(( $(du -sm "$STAGE" | awk '{print $1}') + 30 ))
RW="$WORK/rw.dmg"
hdiutil detach "/Volumes/$VOL" >/dev/null 2>&1 || true
hdiutil create -srcfolder "$STAGE" -volname "$VOL" -fs HFS+ -format UDRW -size "${SIZE_MB}m" -ov "$RW" >/dev/null
DEV="$(hdiutil attach -readwrite -noverify -noautoopen "$RW" | grep -E '^/dev/' | head -1 | awk '{print $1}')"

# ---- 3. style the mounted volume via Finder ----
# Window is 640x448: the icon-view content (window minus titlebar) matches the 640x420 background.
osascript <<OSA
tell application "Finder"
  tell disk "$VOL"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to {220, 140, 860, 588}
    set vopts to the icon view options of container window
    set arrangement of vopts to not arranged
    set icon size of vopts to 120
    set text size of vopts to 12
    set background picture of vopts to file ".background:background.tiff"
    set position of item "Mallow.app" of container window to {160, 250}
    set position of item "Applications" of container window to {480, 250}
    close
    open
    update without registering applications
    delay 1
  end tell
end tell
OSA

# ---- 4. finalize: flush, detach, compress to a distributable read-only DMG ----
sync
hdiutil detach "$DEV" >/dev/null
rm -f "$DMG_OUT"
hdiutil convert "$RW" -format UDZO -imagekey zlib-level=9 -o "$DMG_OUT" >/dev/null
rm -rf "$WORK"
echo "✓ built styled $DMG_OUT ($(du -h "$DMG_OUT" | cut -f1))"
echo "  next: ./notarize-dmg.sh $DMG_OUT mallow-notary   →   ./make-appcast.sh $VER"
