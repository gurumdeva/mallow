# Sparkle Auto-Update — Security Policy Checklist

Mallow ships in-app auto-updates via [Sparkle 2](https://sparkle-project.org). The framework is
cryptographically sound, but every historical Sparkle CVE traced to a MISCONFIGURATION, not the core.
This file is the enforced checklist; each item is verified at integration and re-checked every release.

## The five conditions (all MUST hold)

### 1. Minimum version pinned above every known CVE
- `Package.swift` requires Sparkle `from: "2.9.4"` (SemVer ⇒ `>= 2.9.4, < 3.0.0`).
- 2.9.4 includes ALL 2025 XPC-validation fixes (CVE-2025-10015 / -10016: local privilege escalation +
  TCC bypass, first fixed in 2.7.3), the 2.9.2 delta-symlink guard, and the installer-connection
  validation. Never lower this floor; re-check the latest advisory each release and raise if newer.

### 2. Cryptographically signed updates AND signed feed
- Every update artifact carries an **EdDSA (ed25519) `sparkle:edSignature`**, verified against the
  app's embedded **`SUPublicEDKey`** — so a forged update cannot install even if GitHub is compromised.
- **`SUVerifyUpdateBeforeExtraction = YES`**: the signature is checked BEFORE the archive is extracted
  (never operate on unverified bytes). This is also Sparkle's documented prerequisite for a signed feed.
- **`SURequireSignedFeed = YES`**: the appcast feed itself is validated, not just the enclosure, so a
  tampered feed (fake release notes, downgrade, withheld update) is rejected too. `generate_appcast`
  signs the feed automatically because the app declares this requirement — it embeds a second
  `edSignature` in a trailing `sparkle-signatures` comment (verified 2026-07-09 in the v1.2.5 appcast:
  the enclosure carries `sparkle:edSignature=…` AND the file ends with a `sparkle-signatures` block).
  No manual feed-signing step; never hand-edit the appcast or the feed signature breaks.
- Feed + release notes served over **HTTPS only** (raw.githubusercontent.com) — no ATS exception.
- The private EdDSA key never leaves this Mac's login Keychain; it is NOT in the repo or CI.

### 3. No package/installer path (stay off the 2025-CVE attack surface)
- Updates are a **`.app` inside a `.dmg`**, whole-bundle swap — never a `.pkg`.
- The privileged **Installer/Downloader XPC services are NOT enabled** (`SUEnableInstallerLauncherService`
  and `SUEnableDownloaderService` are absent ⇒ default NO; the app is non-sandboxed with write access to
  `/Applications`, so Sparkle never needs the privileged path the 2025 CVEs targeted).
- The app is **not sandboxed**; if that ever changes, re-audit the XPC service requirement.

### 4. Signing-key custody
- Generated 2026-07-09 with Sparkle's `generate_keys` → private key in this Mac's **login Keychain**.
- **Public key** (embedded as `SUPublicEDKey` in AppBundle/Info.plist):
  `Er284WSoE1o70PHSUuI1Ml9SqaJHIiNRTYk8sKbePDk=`
- **Offline backup — do this once by hand, then delete the file:**
  ```sh
  .build/artifacts/sparkle/Sparkle/bin/generate_keys -x mallow-sparkle-privatekey.txt
  # move mallow-sparkle-privatekey.txt into a password manager / offline vault, then:
  rm mallow-sparkle-privatekey.txt
  ```
  Never commit it or place it in a synced folder (it is git-ignored). Losing BOTH the Keychain entry
  and this backup means minting a new key + shipping an app update carrying the new `SUPublicEDKey`
  before any newly-signed update can reach existing users.

### 5. Apple code signing + notarization unchanged
- The `.app`, the vendored `libinkstone.dylib`, AND the embedded `Sparkle.framework` (plus its nested
  `Autoupdate`, `Updater.app`, and XPC services) are all signed **inside-out** with the same
  **Developer ID Application** identity under the **hardened runtime**, then the DMG is **notarized**.
- Sparkle signing (update-path integrity) and Apple signing (execution integrity) are BOTH required —
  they defend different links in the chain and Sparkle 2 double-verifies them.

## Release pipeline addition
Order matters — **stapling the notarization ticket rewrites the DMG's bytes**, which would invalidate a
signature generated earlier. So per release:
1. `./build-app.sh` (signs the .app + embedded frameworks inside-out).
2. Build the DMG, then `./notarize-dmg.sh Mallow_<ver>_aarch64.dmg mallow-notary` (submits + **staples**).
3. **Only now** `./make-appcast.sh <ver>` — wraps `generate_appcast` (private key from the Keychain),
   signs the enclosure + the feed over the FINAL stapled DMG, and FAILS LOUDLY if the enclosure comes
   out unsigned (guards against shipping a feed the signed-feed app would reject).
4. `git add appcast.xml && commit && push` — the raw HTTPS `SUFeedURL` serves it.

Never hand-edit `appcast.xml`: it is a signed file (note the `sparkle-sign-warning` header), so any manual
change breaks both signatures — always regenerate via `make-appcast.sh`.
