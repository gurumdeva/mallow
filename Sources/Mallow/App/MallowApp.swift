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
            VStack(spacing: 0) {
                MarkdownEditor(doc: doc)
                StatusBar(doc: doc)   // bottom word/char/read-time bar
            }
            // Chrome OVERLAYS the editor's top (not in the layout flow), so it stays flush at the window
            // top and covers the editor's top band — the editor's textContainerInset clears it. (Putting
            // it in a VStack pushed it below the title-bar safe area, so scrolled text bled in above it.)
            ChromeBar(doc: doc, showStyle: $showStyle, showInfo: $showInfo,
                      onExport: { doc.exportPDF() }, onRename: { showRename = true })
        }
        .ignoresSafeArea(edges: .top)   // chrome flush at the very top of the window
        .frame(minWidth: 480, minHeight: 360)
        // The macOS window title — what the Window menu, Mission Control, and ⌘` cycling show. Bound to
        // this window's OWN document so every window is named for its file/heading instead of all reading
        // "Mallow". `doc.title` reads `revision` (bumped on edit/save/rename/reload/open), so it tracks the
        // chrome live. `.hiddenTitleBar` hides the title-bar TEXT, but this still drives the title string.
        .navigationTitle(doc.title)
        .background(Theme.bg)
        .background(WindowActiveTracker(doc: doc))   // report this window active to AppState for the menu commands
        .background(WindowConfigurator(doc: doc))    // close-confirm on unsaved edits + session geometry persistence
        .sheet(isPresented: $showRename) { RenameSheet(doc: doc) }
        .onAppear { WindowRegistry.shared.register(doc) }
        .onDisappear {
            WindowRegistry.shared.unregister(doc)
            // Drop the app-wide active-doc pointer if it was us, so a menu command fired after this window
            // closes can't act on — or strongly retain (leak) — a torn-down document + its NSTextView. A
            // surviving window re-asserts itself active via WindowActiveTracker when it next becomes key.
            if AppState.shared.activeDoc === doc { AppState.shared.activeDoc = nil }
        }
        .onReceive(NotificationCenter.default.publisher(for: .mallowOpenFile)) { note in
            guard let path = note.userInfo?["path"] as? String, claimFileOpen(path) else { return }
            // Focus an already-open window for this file instead of opening a duplicate (data-safety).
            if let existing = WindowRegistry.shared.document(forPath: path) {
                WindowRegistry.shared.focusWindow(of: existing)
            } else {
                openWindow(value: OpenSpec.file(path: path))
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .mallowToggleInfo)) { _ in
            if doc === AppState.shared.activeDoc { showInfo.toggle() }   // ⇧⌘I toggles Document Info on the front window
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

Try **bold**, *italic*, ~~strikethrough~~, and `inline code`. A [link](https://example.com) renders underlined; the #, **, > markers always collapse away — you edit clean styled text and change structure from the Style menu.

## Lists

- Live styling that never rewrites your text
- Lists, quotes, and code rendered in place
  - nested items indent cleanly

> A blockquote shows a soft left bar instead of the > marker.

```
code blocks sit on a rounded card
```
"""
