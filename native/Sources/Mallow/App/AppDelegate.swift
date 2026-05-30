// AppDelegate — app-level actions and config. New / Open each spawn an independent window; the app
// quits when the last window closes, and ⌘Q re-applies each window's unsaved-changes guard (Quit
// does NOT route through windowShouldClose). Also holds the app-wide constants (file types, demo).

import AppKit
import UniformTypeIdentifiers

let markdownTypes: [UTType] = [UTType(filenameExtension: "md") ?? .plainText, .plainText]

let demoText = L.t("welcome.demo")

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    // ⌘Q / Log Out / Restart / Shut Down do NOT invoke each window's windowShouldClose, so the
    // per-window discard guard must be re-applied here or unsaved edits are silently lost on quit.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        for editor in editors where !editor.confirmDiscardIfDirty() {
            return .terminateCancel   // a window had unsaved edits and the user chose Cancel
        }
        SessionStore.flushNow()   // SessionRestore: persist final geometry + last-file before exit
        return .terminateNow
    }

    @objc func newDocument(_ sender: Any?) { makeEditor("", nil) }
    @objc func openDocument(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = markdownTypes
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url,
           let content = try? String(contentsOf: url, encoding: .utf8) {
            makeEditor(content, url.path)
        }
    }
    @objc func openRecent(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String,
              let content = try? String(contentsOfFile: path, encoding: .utf8) else { return }
        makeEditor(content, path)
    }
    @objc func clearRecent(_ sender: Any?) { RecentFiles.clear() }
}
