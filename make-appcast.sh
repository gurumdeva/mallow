#!/usr/bin/env bash
# ============================================================================
# make-appcast.sh <version>   (e.g. make-appcast.sh 1.2.5)
#
# Regenerates the Sparkle appcast for a NEW release. Run AFTER the notarized DMG
# (Mallow_<version>_aarch64.dmg) exists in the repo root. It:
#   1. stages the new DMG next to the CURRENT committed appcast.xml (so existing
#      entries + their per-version download URLs are preserved),
#   2. runs generate_appcast, which signs the new update with the EdDSA private
#      key from the login Keychain (the app declares the matching SUPublicEDKey,
#      so a forged update can't install), pointing its download URL at this
#      version's GitHub release asset,
#   3. copies the updated appcast.xml back to the repo root to be committed.
#
# Then: git add appcast.xml && commit && push  — the raw HTTPS URL is the feed.
# See docs/security/sparkle-update-security.md.
# ============================================================================
set -euo pipefail
cd "$(dirname "$0")"

VER="${1:?usage: make-appcast.sh <version>   e.g. 1.2.5}"
DMG="Mallow_${VER}_aarch64.dmg"
[ -f "$DMG" ] || { echo "error: $DMG not found in repo root (build + notarize it first)." >&2; exit 1; }

GEN="$(/usr/bin/find .build/artifacts -name generate_appcast -type f 2>/dev/null | head -1)"
[ -x "$GEN" ] || { echo "error: generate_appcast not found — run 'swift build' first." >&2; exit 1; }

STAGE="appcast-staging"
rm -rf "$STAGE"; mkdir -p "$STAGE"
cp "$DMG" "$STAGE/"
# Re-use the committed appcast so older versions keep their (per-tag) download URLs. generate_appcast
# only ADDS the new entry; old entries are untouched.
[ -f appcast.xml ] && cp appcast.xml "$STAGE/appcast.xml"

# --download-url-prefix applies to the NEW entry only → this version's GitHub release asset URL.
"$GEN" --download-url-prefix "https://github.com/gurumdeva/mallow/releases/download/v${VER}/" "$STAGE"

# Fail loudly if the new enclosure came out UNSIGNED — a signed SUPublicEDKey app would then reject
# its own update (the exact silent-misconfig the security policy guards against).
if ! grep -q 'sparkle:edSignature' "$STAGE/appcast.xml"; then
  echo "error: generated appcast has NO edSignature — the update would be rejected by the app." >&2
  echo "       (is the private key in the login Keychain? does the app embed SUPublicEDKey?)" >&2
  exit 1
fi

cp "$STAGE/appcast.xml" appcast.xml
echo "✓ appcast.xml updated + signed for v${VER}. Next: git add appcast.xml && commit && push."
