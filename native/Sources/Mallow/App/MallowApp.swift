// MallowApp — the SwiftUI entry point (replaces the old AppKit main.swift + AppDelegate + WindowFactory).
// A WindowGroup whose content is the editor surface; the transparent titlebar (`.hiddenTitleBar`) makes
// room for the custom SwiftUI chrome added on top. This first cut renders the editor only — chrome,
// menus, popovers, and the open/save/session lifecycle land in the following phases.

import SwiftUI

@main
struct MallowApp: App {
    // The app delegate handles Finder / `open` file events (no SwiftUI hook for those on a plain
    // executable) by posting `.mallowOpenFile`, which EditorWindow turns into an openWindow below.
    @NSApplicationDelegateAdaptor(MallowAppDelegate.self) private var appDelegate

    var body: some Scene {
        // Parameterized by OpenSpec so File ▸ Open / Open Recent can open a window onto a specific file
        // (`openWindow(value:)`), while New Window / first launch arrive as nil → blank / welcome demo.
        WindowGroup(for: OpenSpec.self) { $spec in
            EditorWindow(spec: spec)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 760, height: 560)
        .commands { MallowCommands() }
    }
}

/// One editor window's content: the document model, the editor surface, and the custom titlebar chrome
/// (filename + dirty dot + style/export/info corner buttons) overlaid at the top. The style and info
/// popovers anchor to their corner buttons inside ChromeBar; export + rename are wired here (rename is
/// reintroduced in the features phase).
struct EditorWindow: View {
    @State private var doc: EditorDocument
    @State private var showStyle = false
    @State private var showInfo = false
    @State private var showRename = false
    @Environment(\.openWindow) private var openWindow

    init(spec: OpenSpec?) {
        _doc = State(initialValue: EditorDocument.make(for: spec))
    }

    var body: some View {
        ZStack(alignment: .top) {
            MarkdownEditor(doc: doc)
                .ignoresSafeArea()
            ChromeBar(doc: doc, showStyle: $showStyle, showInfo: $showInfo,
                      onExport: { doc.exportPDF() }, onRename: { showRename = true })
        }
        .frame(minWidth: 480, minHeight: 360)
        .background(Theme.bg)
        .background(WindowActiveTracker(doc: doc))   // report this window active to AppState for the menu commands
        .background(WindowConfigurator(doc: doc))    // close-confirm on unsaved edits + session geometry persistence
        .sheet(isPresented: $showRename) { RenameSheet(doc: doc) }
        .onReceive(NotificationCenter.default.publisher(for: .mallowOpenFile)) { note in
            guard let path = note.userInfo?["path"] as? String, claimFileOpen(path) else { return }
            openWindow(value: OpenSpec.file(path: path))
        }
    }
}

/// De-dupe Finder/`open` file events: every open window mounts the `.onReceive` above, so without this
/// each would call openWindow for the same path. Allow one open per path per ~1 second.
private var lastFileOpen: (path: String, at: TimeInterval) = ("", 0)
private func claimFileOpen(_ path: String) -> Bool {
    let now = ProcessInfo.processInfo.systemUptime
    if lastFileOpen.path == path, now - lastFileOpen.at < 1.0 { return false }
    lastFileOpen = (path, now)
    return true
}

/// First-launch sample document (mirrors the AppKit build's welcome text), exercising headings, inline
/// marks, lists, quote, and code so the live-preview rendering is visible on launch.
let demoMarkdown = """
# Mallow

A native macOS markdown editor — **markdown is the source of truth**, parsed and styled live by a Rust engine, with the system IME for 한글 / 日本語.

## Inline styles

Try **bold**, *italic*, ~~strikethrough~~, and `inline code`. A [link](https://example.com) renders underlined; the #, **, > markers collapse away and return only on the caret's line.

## Lists

- Live styling that never rewrites your text
- Lists, quotes, and code rendered in place
  - nested items indent cleanly

> A blockquote shows a soft left bar instead of the > marker.

```
code blocks sit on a rounded card
```
"""
