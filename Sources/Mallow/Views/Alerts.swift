// Alerts — two shared NSAlert helpers so the scattered "build a warning, run it" boilerplate lives in
// one place: a destructive yes/no confirm (the close-window / quit-app guards) and a fire-and-forget
// sheet-or-modal presenter (the error / file-in-use / rename-failure surfaces).

import AppKit

extension NSAlert {
    /// A two-button destructive confirmation. `confirm` is the first button (default ⏎ + destructive
    /// styling); `cancel` is second and bound to Esc — so a stray ⏎ confirms intentionally while Esc backs
    /// out and keeps the window/app. Runs app-modal; returns true iff the user chose `confirm`.
    static func confirmDestructive(title: String, body: String, confirm: String, cancel: String) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = body
        alert.addButton(withTitle: confirm).hasDestructiveAction = true   // .alertFirstButtonReturn (default ⏎)
        alert.addButton(withTitle: cancel).keyEquivalent = "\u{1b}"        // Esc → cancel
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// Show this alert as a non-blocking sheet on `window` when one exists, else a free-standing app-modal.
    /// Fire-and-forget: for informational / error surfaces whose only action is dismissal.
    func present(anchoredTo window: NSWindow?) {
        if let window { beginSheetModal(for: window) } else { runModal() }
    }
}
