#!/usr/bin/env bash
# ============================================================================
# build-app.sh — package the SwiftPM `Mallow` executable as a distributable
#                .app bundle (so Finder double-click opens .md files).
#
# Make executable once:   chmod +x build-app.sh
# Run from anywhere:      build-app.sh
#
# Output: .build/Mallow.app   (UNSIGNED — see the note printed at the end)
#
# This does NOT code-sign or notarize. Signing/notarization is a separate,
# user-owned step (see AppBundle/README.md).
# ============================================================================
set -euo pipefail
cd "$(dirname "$0")"                       # markdown-editor (repo root)

APP_NAME="Mallow"
BUNDLE_ID="com.gurumdeva.mallow-native"
BUILD_DIR=".build"
APP="$BUILD_DIR/$APP_NAME.app"
CONTENTS="$APP/Contents"
MACOS_DIR="$CONTENTS/MacOS"
RES_DIR="$CONTENTS/Resources"
FRAMEWORKS_DIR="$CONTENTS/Frameworks"
PLIST_SRC="AppBundle/Info.plist"
ICON_SRC="AppBundle/AppIcon.icns"
INK="../inkstone"

# ---- 0. sanity checks ------------------------------------------------------
if [ ! -f "$PLIST_SRC" ]; then
  echo "error: $PLIST_SRC not found (run from the repo root)." >&2
  exit 1
fi
if [ ! -d "$INK" ]; then
  echo "error: expected the Inkstone engine at $INK (sibling checkout)." >&2
  echo "       clone gurumdeva/inkstone next to markdown-editor, then re-run." >&2
  exit 1
fi

# ---- 1. build the Rust staticlib + the release executable ------------------
# Mallow links libinkstone from $INK/target/release; build it first.
echo "== building libinkstone (cargo --features ffi --release, from $INK) =="
( cd "$INK" && cargo build --features ffi --release )

echo "== swift build -c release =="
swift build -c release
EXE_SRC="$(swift build -c release --show-bin-path)/$APP_NAME"
if [ ! -x "$EXE_SRC" ]; then
  echo "error: built executable not found at $EXE_SRC" >&2
  exit 1
fi

# ---- 2. assemble the bundle skeleton (idempotent: nuke first) --------------
echo "== assembling $APP =="
rm -rf "$APP"
mkdir -p "$MACOS_DIR" "$RES_DIR" "$FRAMEWORKS_DIR"

cp "$EXE_SRC" "$MACOS_DIR/$APP_NAME"
chmod +x "$MACOS_DIR/$APP_NAME"
cp "$PLIST_SRC" "$CONTENTS/Info.plist"

# Optional icon — copy only if present (skip silently if absent).
if [ -f "$ICON_SRC" ]; then
  cp "$ICON_SRC" "$RES_DIR/AppIcon.icns"
  echo "   icon:       bundled AppIcon.icns"
else
  echo "   icon:       (none — $ICON_SRC absent, skipping; app uses generic icon)"
fi

# PkgInfo: harmless, classic byte signature for an APPL bundle.
printf 'APPL????' > "$CONTENTS/PkgInfo"

# ---- 3. make the bundle self-contained (vendor libinkstone if dynamic) -----
# NOTE on linkage: inkstone's Cargo.toml builds crate-type
# ["cdylib","staticlib","rlib"], so BOTH libinkstone.a and libinkstone.dylib
# land in target/release. Apple's ld prefers the .dylib when both share a -L
# dir, so the Mallow binary ends up with an ABSOLUTE LC_LOAD_DYLIB pointing
# into the inkstone build tree — which would NOT exist on another machine.
# To ship a self-contained .app we copy that dylib into Contents/Frameworks
# and rewrite the load command to @rpath. If the binary instead linked the
# staticlib (no inkstone dylib in `otool -L`), there's nothing to do.
INK_LOAD="$(otool -L "$MACOS_DIR/$APP_NAME" | awk '/inkstone.*\.dylib/ {print $1; exit}')"
if [ -n "${INK_LOAD:-}" ]; then
  if [ ! -f "$INK_LOAD" ]; then
    echo "error: binary references $INK_LOAD but that file is missing." >&2
    echo "       rebuild inkstone (cargo build --features ffi --release) first." >&2
    exit 1
  fi
  DYLIB_BASE="$(basename "$INK_LOAD")"
  cp "$INK_LOAD" "$FRAMEWORKS_DIR/$DYLIB_BASE"
  chmod u+w "$FRAMEWORKS_DIR/$DYLIB_BASE"
  # Point the copy's own id at @rpath, repoint the executable's load command,
  # and add an rpath so @rpath resolves to Contents/Frameworks at runtime.
  install_name_tool -id "@rpath/$DYLIB_BASE" "$FRAMEWORKS_DIR/$DYLIB_BASE"
  install_name_tool -change "$INK_LOAD" "@rpath/$DYLIB_BASE" "$MACOS_DIR/$APP_NAME"
  install_name_tool -add_rpath "@loader_path/../Frameworks" "$MACOS_DIR/$APP_NAME" 2>/dev/null || true
  echo "   inkstone:   vendored $DYLIB_BASE → Contents/Frameworks (rewrote to @rpath)"
else
  echo "   inkstone:   statically linked (no dylib to vendor — bundle is self-contained)"
fi

# ---- 3.5. code sign (only when a Developer ID Application cert is available) -
# Signing + notarization let the .app install with a normal double-click (no
# right-click → Open). This needs the PAID Apple Developer Program — a
# "Developer ID Application" certificate in the keychain. Until one exists this
# step is skipped automatically and the bundle stays unsigned (unchanged
# behaviour). Override the identity with SIGN_IDENTITY=… if auto-detect picks
# the wrong one. After this, notarize the DMG with ./notarize-dmg.sh.
SIGN_IDENTITY="${SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null \
  | awk -F'"' '/Developer ID Application/ {print $2; exit}')}"
SIGNED=0
if [ -n "${SIGN_IDENTITY:-}" ]; then
  echo "== code signing (hardened runtime) as: $SIGN_IDENTITY =="
  # Inside-out: sign nested dylibs first, then the bundle. Hardened runtime
  # (--options runtime) is required for notarization; the same-identity dylib
  # signature satisfies its library validation (no disable-library-validation).
  while IFS= read -r -d '' lib; do
    codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$lib"
  done < <(find "$FRAMEWORKS_DIR" -name '*.dylib' -print0 2>/dev/null)
  codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP"
  codesign --verify --deep --strict --verbose=2 "$APP"
  SIGNED=1
  echo "   signed + verified ✓"
else
  echo "   signing:    (no 'Developer ID Application' cert in keychain — bundle left UNSIGNED)"
fi

# ---- 4. report -------------------------------------------------------------
APP_ABS="$(cd "$BUILD_DIR" && pwd)/$APP_NAME.app"
echo
echo "Built: $APP_ABS"
echo
echo "  Verify linkage is bundle-relative (only @rpath + system frameworks):"
echo "    otool -L \"$APP_ABS/Contents/MacOS/$APP_NAME\" | grep -iv /System/Library"
echo
if [ "$SIGNED" = "1" ]; then
  echo "  This bundle is SIGNED (Developer ID, hardened runtime). Next: notarize the DMG so"
  echo "  it installs with a plain double-click —"
  echo "    hdiutil create -volname Mallow -srcfolder <stage> -format UDZO Mallow_<ver>_aarch64.dmg"
  echo "    ./notarize-dmg.sh Mallow_<ver>_aarch64.dmg"
else
  echo "  This bundle is UNSIGNED (no code signing / notarization)."
  echo "  Gatekeeper will block a double-click on first launch. To open it:"
  echo "    • right-click the .app in Finder → Open → Open  (one-time per machine), or"
  echo "    • strip the quarantine flag:"
  echo "        xattr -dr com.apple.quarantine \"$APP_ABS\""
fi
echo
echo "  Test Finder-style open (passes a file to the app):"
echo "    open -a \"$APP_ABS\" /path/to/file.md"
