// MallowCommands — the SwiftUI menu bar (`.commands`), replacing the AppKit NSMenu from main.swift.
// Each command acts on `AppState.shared.activeDoc` — the key editor window's document — read at click
// time (so it always targets the front window). This replaces the responder-chain routing the old
// EditorController relied on. File New/Open/Recent + the session lifecycle land in the lifecycle phase;
// this covers Save/Export, the Format menu, and the View menu.

import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct MallowCommands: Commands {
    /// The front editor window's document, resolved at the moment a command fires — guarded on a LIVE
    /// window. A just-closed window's document can briefly linger in `activeDoc` (focus moving to another
    /// app, or before its `onDisappear` clears it); acting on one would target a torn-down editor, so a
    /// document whose NSWindow is gone reads as "no active document" and the command simply no-ops.
    private var doc: EditorDocument? {
        guard let d = AppState.shared.activeDoc, d.textView.window != nil else { return nil }
        return d
    }
    /// The editor coordinator behind that document (for paste/clipboard commands that act on the text view).
    private var coordinator: MarkdownEditor.Coordinator? { doc?.textView.delegate as? MarkdownEditor.Coordinator }
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        // App ▸ Check for Updates… — slotted right under "About Mallow", the conventional spot. Asks
        // GitHub Releases whether a newer build exists and offers to open the Releases page.
        CommandGroup(after: .appInfo) {
            Button(L.t("menu.checkUpdates")) { UpdateChecker.checkNow() }
        }

        // File ▸ New / Open / Open Recent (replaces the default "New Window"). New opens a blank window;
        // Open / Recent open a window onto a file via the OpenSpec value.
        CommandGroup(replacing: .newItem) {
            Button(L.t("menu.new")) { openWindow(value: OpenSpec.blank) }
                .keyboardShortcut("n", modifiers: .command)
            Button(L.t("menu.open")) { openFile() }
                .keyboardShortcut("o", modifiers: .command)
            Menu(L.t("menu.openRecent")) {
                let recents = RecentFiles.list()
                if recents.isEmpty {
                    Button(L.t("recent.none")) {}.disabled(true)
                } else {
                    ForEach(recents, id: \.self) { path in
                        Button((path as NSString).lastPathComponent) { openOrFocus(path) }
                    }
                    Divider()
                    Button(L.t("menu.clearRecent")) { RecentFiles.clear() }
                }
            }
        }

        // File ▸ Save / Save As / Export (slots into the standard Save menu position).
        CommandGroup(replacing: .saveItem) {
            Button(L.t("menu.save")) { doc?.save() }
                .keyboardShortcut("s", modifiers: .command)
            Button(L.t("menu.saveAs")) { doc?.saveAs() }
                .keyboardShortcut("s", modifiers: [.command, .shift])
            Divider()
            Button(L.t("menu.exportPdf")) { doc?.exportPDF() }
                .keyboardShortcut("e", modifiers: .command)
            Button(L.t("menu.exportHtml")) { doc?.exportHTML() }
                .keyboardShortcut("e", modifiers: [.command, .shift])
        }

        // Edit ▸ Paste & Match Style / Copy as Rich Text (clipboard extras on the editor coordinator).
        CommandGroup(after: .pasteboard) {
            Button(L.t("menu.pasteMatchStyle")) { coordinator?.pasteAndMatchStyle() }
                .keyboardShortcut("v", modifiers: [.command, .shift])
            Button(L.t("menu.copyRichText")) { coordinator?.copyAsRichText() }
                .keyboardShortcut("c", modifiers: [.command, .option])
        }

        // Format — a new top-level menu (the engine commands the Style popover also issues).
        CommandMenu(L.t("menu.format")) {
            Button(L.t("format.bold")) { doc?.vm.apply("toggle_strong") }
                .keyboardShortcut("b", modifiers: .command)
            Button(L.t("format.italic")) { doc?.vm.apply("toggle_emphasis") }
                .keyboardShortcut("i", modifiers: .command)
            Button(L.t("format.strikethrough")) { doc?.vm.apply("toggle_strikethrough") }
            Button(L.t("format.inlineCode")) { doc?.vm.apply("toggle_inline_code") }
            Divider()
            Button("H1") { doc?.vm.applyHeading(1) }.keyboardShortcut("1", modifiers: .command)
            Button("H2") { doc?.vm.applyHeading(2) }.keyboardShortcut("2", modifiers: .command)
            Button("H3") { doc?.vm.applyHeading(3) }.keyboardShortcut("3", modifiers: .command)
            Button(L.t("format.body")) { doc?.vm.applyHeading(0) }
                .keyboardShortcut("0", modifiers: [.command, .option])
            Divider()
            Button(L.t("format.bullet")) { doc?.vm.apply("toggle_bullet_list") }
            Button(L.t("format.numbered")) { doc?.vm.apply("toggle_ordered_list") }
            Button(L.t("format.quote")) { doc?.vm.apply("toggle_blockquote") }
            Button(L.t("format.codeBlock")) { doc?.vm.apply("toggle_code_block") }
            Button(L.t("format.divider")) { doc?.vm.apply("insert_divider") }
        }

        // View — focus mode, keep-on-top, zoom, etc. Injected INTO the standard View menu (via the
        // .sidebar placement) rather than as a separate CommandMenu: a CommandMenu makes a NEW menu, so
        // macOS's auto-provided "View" menu (Enter Full Screen) and our "보기" showed up as TWO View
        // menus. Merging keeps a single View menu with our items above the system Enter Full Screen.
        CommandGroup(after: .sidebar) {
            Button(L.t("menu.focusMode")) { doc?.toggleFocus() }
                .keyboardShortcut("f", modifiers: [.command, .control])
            Button(L.t("menu.keepOnTop")) { doc?.toggleKeepOnTop() }
            Button(L.t("menu.typewriter")) { doc?.toggleTypewriter() }
                .keyboardShortcut("t", modifiers: [.command, .control])
            Button(L.t("menu.foldSections")) { doc?.toggleFoldAll() }
                .keyboardShortcut("o", modifiers: [.command, .control])
            Button(L.t("menu.foldSection")) { doc?.toggleFoldSection() }
                .keyboardShortcut(".", modifiers: [.command, .option])
            Divider()
            Button(L.t("menu.documentInfo")) {
                NotificationCenter.default.post(name: .mallowToggleInfo, object: nil)
            }
            .keyboardShortcut("i", modifiers: [.command, .shift])
            Divider()
            Button(L.t("menu.zoomIn")) { doc?.zoomIn() }
                .keyboardShortcut("+", modifiers: .command)
            Button(L.t("menu.zoomOut")) { doc?.zoomOut() }
                .keyboardShortcut("-", modifiers: .command)
            Button(L.t("menu.actualSize")) { doc?.zoomReset() }
                .keyboardShortcut("0", modifiers: .command)
        }
    }

    /// File ▸ Open — pick a markdown/text file and open it in a new window.
    private func openFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText, .plainText]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            openOrFocus(url.path)
        }
    }

    /// Open `path` in a new window, or focus the window already editing it (data-safety: avoids two
    /// windows on one file autosave-clobbering each other).
    private func openOrFocus(_ path: String) {
        if let existing = WindowRegistry.shared.document(forPath: path) {
            WindowRegistry.shared.focusWindow(of: existing)
        } else {
            openWindow(value: OpenSpec.file(path: path))
        }
    }
}
