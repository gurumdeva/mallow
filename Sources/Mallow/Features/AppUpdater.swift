// AppUpdater — the Sparkle 2 in-app updater. Replaces the old GitHub-poll `UpdateChecker`: instead of
// opening the Releases page in a browser, Sparkle downloads, cryptographically verifies (EdDSA against
// the embedded SUPublicEDKey), and installs the update in place, then relaunches. All the update policy
// lives in Info.plist (feed URL, public key, signed-feed requirement, daily background check, and the
// deliberate ABSENCE of the privileged installer/downloader XPC services); see
// docs/security/sparkle-update-security.md for the security checklist this satisfies.
//
// A single shared instance owns the `SPUStandardUpdaterController`, which must outlive every check:
// `startingUpdater: true` kicks off the scheduled background checks (SUEnableAutomaticChecks +
// SUScheduledCheckInterval) at init; the menu command drives an explicit check through the same object.

import AppKit
import Sparkle
import SwiftUI

final class AppUpdater: ObservableObject {
    /// The app-lifetime updater. Created once at launch (see MallowApp) so scheduled checks run and the
    /// controller is retained; the menu command reaches it via this shared instance.
    static let shared = AppUpdater()

    private let controller: SPUStandardUpdaterController

    /// Mirrors Sparkle's `canCheckForUpdates` so the menu item can disable itself while a check is in
    /// flight (Sparkle serializes checks; a second one would otherwise no-op silently).
    @Published private(set) var canCheck = false

    private init() {
        // The standard controller reads all update configuration from Info.plist and presents Sparkle's
        // standard, localized update UI. `startingUpdater: true` starts the scheduled background checks.
        controller = SPUStandardUpdaterController(startingUpdater: true,
                                                  updaterDelegate: nil, userDriverDelegate: nil)
        controller.updater.publisher(for: \.canCheckForUpdates).receive(on: RunLoop.main).assign(to: &$canCheck)
    }

    /// The explicit File/App-menu "Check for Updates…" action — shows Sparkle's UI (progress, release
    /// notes, install-and-relaunch) even when the app is already up to date.
    func checkForUpdates() { controller.checkForUpdates(nil) }
}

/// The "Check for Updates…" menu item, bound to the shared updater so it disables itself while a check
/// is already running (Sparkle serializes checks; a second concurrent one would silently no-op).
struct CheckForUpdatesMenuItem: View {
    @ObservedObject private var updater = AppUpdater.shared
    var body: some View {
        Button { updater.checkForUpdates() } label: {
            Label(L.t("menu.checkUpdates"), systemImage: "arrow.triangle.2.circlepath")
        }
        .disabled(!updater.canCheck)
    }
}
