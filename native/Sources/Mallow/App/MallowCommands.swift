// MallowCommands — the SwiftUI menu bar (`.commands`), replacing the AppKit NSMenu from main.swift.
// Each command acts on `AppState.shared.activeDoc` — the key editor window's document — read at click
// time (so it always targets the front window). This replaces the responder-chain routing the old
// EditorController relied on. File New/Open/Recent + the session lifecycle land in the lifecycle phase;
// this covers Save/Export, the Format menu, and the View menu.

import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct MallowCommands: Commands {
    /// The front editor window's document, resolved at the moment a command fires.
    private var doc: EditorDocument? { AppState.shared.activeDoc }
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
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
                        Button((path as NSString).lastPathComponent) {
                            openWindow(value: OpenSpec.file(path: path))
                        }
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

        // View — focus mode, keep-on-top, and zoom (typewriter + document-info return in later phases).
        CommandMenu(L.t("menu.view")) {
            Button(L.t("menu.focusMode")) { doc?.toggleFocus() }
                .keyboardShortcut("f", modifiers: [.command, .control])
            Button(L.t("menu.keepOnTop")) { doc?.toggleKeepOnTop() }
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
            openWindow(value: OpenSpec.file(path: url.path))
        }
    }
}
