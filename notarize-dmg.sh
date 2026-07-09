#!/usr/bin/env bash
# ============================================================================
# notarize-dmg.sh — submit a (signed) DMG to Apple notarization and staple the
#                   ticket, so the app installs with a plain double-click.
#
#   ./notarize-dmg.sh Mallow_1.0.0_aarch64.dmg [profile]
#
# PREREQUISITES (one-time, user-owned — see the README / chat checklist):
#   1. Paid Apple Developer Program membership.
#   2. A "Developer ID Application" certificate in the keychain (build-app.sh
#      auto-signs with it).
#   3. A stored notarytool credential profile. Create it ONCE with an
#      app-specific password (https://appleid.apple.com → Sign-In & Security →
#      App-Specific Passwords):
#
#        xcrun notarytool store-credentials "mallow-notary" \
#          --apple-id "YOUR_APPLE_ID_EMAIL" \
#          --team-id "YOUR_TEAM_ID" \
#          --password "APP_SPECIFIC_PASSWORD"
#
# The DMG's .app must already be code-signed (build-app.sh does that when the
# Developer ID cert is present). This script only notarizes + staples.
# ============================================================================
set -euo pipefail

DMG="${1:?usage: ./notarize-dmg.sh <path-to-dmg> [keychain-profile]}"
PROFILE="${2:-mallow-notary}"

if [ ! -f "$DMG" ]; then
  echo "error: DMG not found: $DMG" >&2
  exit 1
fi

echo "== submitting to notarization (profile: $PROFILE) — this can take a few minutes =="
xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait

echo "== stapling the ticket onto the DMG =="
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"

echo
echo "done — $DMG is signed, notarized, and stapled."
echo "Verify on a clean machine: a double-click should open it with no Gatekeeper warning."
