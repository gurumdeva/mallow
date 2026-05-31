// MallowApp — the SwiftUI entry point (replaces the old AppKit main.swift + AppDelegate + WindowFactory).
// A WindowGroup whose content is the editor surface; the transparent titlebar (`.hiddenTitleBar`) makes
// room for the custom SwiftUI chrome added on top. This first cut renders the editor only — chrome,
// menus, popovers, and the open/save/session lifecycle land in the following phases.

import SwiftUI

@main
struct MallowApp: App {
    var body: some Scene {
        WindowGroup {
            EditorWindow()
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
    @State private var doc = EditorDocument(text: demoMarkdown)
    @State private var showStyle = false
    @State private var showInfo = false

    var body: some View {
        ZStack(alignment: .top) {
            MarkdownEditor(doc: doc)
                .ignoresSafeArea()
            ChromeBar(doc: doc, showStyle: $showStyle, showInfo: $showInfo,
                      onExport: { doc.exportPDF() }, onRename: {})
        }
        .frame(minWidth: 480, minHeight: 360)
        .background(Theme.bg)
        .background(WindowActiveTracker(doc: doc))   // report this window active to AppState for the menu commands
    }
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
