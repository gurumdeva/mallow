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
- **`SURequireSignedFeed = YES`**: the appcast feed itself is validated, not just the enclosure.
- Feed + release notes served over **HTTPS only** (raw.githubusercontent.com) — no ATS exception.
- The private EdDSA key never leaves this Mac's login Keychain; it is NOT in the repo or CI.

### 3. No package/installer path (stay off the 2025-CVE attack surface)
- Updates are a **`.app` inside a `.dmg`**, whole-bundle swap — never a `.pkg`.
- The privileged **Installer/Downloader XPC services are NOT enabled** (`SUEnableInstallerLauncherService`
  and `SUEnableDownloaderService` are absent ⇒ default NO; the app is non-sandboxed with write access to
  `/Applications`, so Sparkle never needs the privileged path the 2025 CVEs targeted).
- The app is **not sandboxed**; if that ever changes, re-audit the XPC service requirement.

### 4. Signing-key custody
- Generated with Sparkle's `generate_keys` → stored in this Mac's **login Keychain** (account
  `ed25519`, service `https://sparkle-project.org`).
- A one-time **offline backup** of the private key is exported to a user-controlled secure location
  (NOT the repo, NOT a synced folder). Losing it means minting a new key + shipping an app update that
  carries the new `SUPublicEDKey` before any signed-with-the-new-key update can be delivered.

### 5. Apple code signing + notarization unchanged
- The `.app`, the vendored `libinkstone.dylib`, AND the embedded `Sparkle.framework` (plus its nested
  `Autoupdate`, `Updater.app`, and XPC services) are all signed **inside-out** with the same
  **Developer ID Application** identity under the **hardened runtime**, then the DMG is **notarized**.
- Sparkle signing (update-path integrity) and Apple signing (execution integrity) are BOTH required —
  they defend different links in the chain and Sparkle 2 double-verifies them.

## Release pipeline addition
After notarizing the DMG: `generate_appcast <dir-of-dmgs>` signs each release with the private key and
writes `appcast.xml` (feed at `SUFeedURL`). Commit + push `appcast.xml`; the raw HTTPS URL is the feed.
Never hand-edit signatures.
