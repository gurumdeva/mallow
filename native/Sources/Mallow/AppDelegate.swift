// AppDelegate — app-level actions and config. New / Open each spawn an independent window; the app
// quits when the last window closes, and ⌘Q re-applies each window's unsaved-changes guard (Quit
// does NOT route through windowShouldClose). Also holds the app-wide constants (file types, demo).

import AppKit
import UniformTypeIdentifiers

let markdownTypes: [UTType] = [UTType(filenameExtension: "md") ?? .plainText, .plainText]

let demoText = """
# Inkstone

A native macOS editor where **markdown is the source of truth** — parsed and
styled live by a Rust engine, with the system IME for 한글 / 日本語.

`#`, `**`, and `>` collapse away and return only on the caret's line. Try
*italic*, ~~strikethrough~~, `inline code`, or a [link](https://example.com).

## Highlights
- **Live styling** that never rewrites your text
- Lists, quotes, and code rendered in place
1. headings sized by level
2. links, code, and rules

> Markdown stays markdown — nothing is changed behind your back.

The Format menu and ⌘B / ⌘I run the engine's commands; ⌘N / O / S handle files.
"""

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    // ⌘Q / Log Out / Restart / Shut Down do NOT invoke each window's windowShouldClose, so the
    // per-window discard guard must be re-applied here or unsaved edits are silently lost on quit.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        for editor in editors where !editor.confirmDiscardIfDirty() {
            return .terminateCancel   // a window had unsaved edits and the user chose Cancel
        }
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
