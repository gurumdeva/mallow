// Mallow — the native macOS app (Swift/AppKit) on the Inkstone engine.
//
// Architecture (MVVM): Models = ParseModels; ViewModel = EditorViewModel (parse/render/command/state
// logic); Views = MarkdownTextView, ChromeBar, Theme; Controller = EditorController (window +
// delegates + menu forwarding); Services = Engine (the Inkstone C-ABI seam), RecentFilesStore,
// PDFExporter. This file is just the app bootstrap: the menu bar + the first window.
//
// Build (from native/, with the sibling inkstone repo built — see build.sh / README):
//   ( cd ../../inkstone && cargo build --features ffi --release ) && swift run Mallow

import AppKit

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let appDelegate = AppDelegate()
app.delegate = appDelegate

// Menus are app-global. Window-level actions use target nil so the responder chain delivers them to
// the KEY window's EditorController; New/Open target the app delegate so they work with no window.
let mainMenu = NSMenu()

let appItem = NSMenuItem()
mainMenu.addItem(appItem)
let appMenu = NSMenu()
appMenu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
appItem.submenu = appMenu

let fileItem = NSMenuItem()
mainMenu.addItem(fileItem)
let fileMenu = NSMenu(title: "File")
func addFile(_ title: String, _ action: Selector, _ key: String,
             _ mods: NSEvent.ModifierFlags = .command, target: AnyObject? = nil) {
    let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
    item.keyEquivalentModifierMask = mods
    item.target = target  // nil → responder chain (the key window's controller)
    fileMenu.addItem(item)
}
addFile("New", #selector(AppDelegate.newDocument(_:)), "n", target: appDelegate)
addFile("Open…", #selector(AppDelegate.openDocument(_:)), "o", target: appDelegate)
let recentItem = NSMenuItem(title: "Open Recent", action: nil, keyEquivalent: "")
recentItem.submenu = recentMenu
fileMenu.addItem(recentItem)
rebuildRecentMenu()
addFile("Save", #selector(EditorController.saveDocument(_:)), "s")
addFile("Save As…", #selector(EditorController.saveDocumentAs(_:)), "s", [.command, .shift])
fileMenu.addItem(.separator())
addFile("Export as PDF…", #selector(EditorController.exportPDF(_:)), "e")
addFile("Export as HTML…", #selector(EditorController.exportHTML(_:)), "e", [.command, .shift])
fileMenu.addItem(.separator())
addFile("Close", #selector(NSWindow.performClose(_:)), "w")
fileItem.submenu = fileMenu

// Edit menu — standard actions route through the responder chain to the text view (target nil).
// Find (⌘F) opens the native find bar (`usesFindBar`), which includes replace.
let editItem = NSMenuItem()
mainMenu.addItem(editItem)
let editMenu = NSMenu(title: "Edit")
func addEdit(_ title: String, _ sel: Selector, _ key: String,
            _ mods: NSEvent.ModifierFlags = .command, tag: Int = 0) {
    let item = NSMenuItem(title: title, action: sel, keyEquivalent: key)
    item.keyEquivalentModifierMask = mods
    item.tag = tag
    editMenu.addItem(item)
}
addEdit("Undo", Selector(("undo:")), "z")
addEdit("Redo", Selector(("redo:")), "z", [.command, .shift])
editMenu.addItem(.separator())
addEdit("Cut", #selector(NSText.cut(_:)), "x")
addEdit("Copy", #selector(NSText.copy(_:)), "c")
addEdit("Paste", #selector(NSText.paste(_:)), "v")
addEdit("Select All", #selector(NSText.selectAll(_:)), "a")
editMenu.addItem(.separator())
addEdit("Find…", #selector(NSTextView.performFindPanelAction(_:)), "f", tag: 1)
addEdit("Find Next", #selector(NSTextView.performFindPanelAction(_:)), "g", tag: 2)
addEdit("Find Previous", #selector(NSTextView.performFindPanelAction(_:)), "g", [.command, .shift], tag: 3)
addEdit("Use Selection for Find", #selector(NSTextView.performFindPanelAction(_:)), "e", tag: 7)
editItem.submenu = editMenu

let formatItem = NSMenuItem()
mainMenu.addItem(formatItem)
let formatMenu = NSMenu(title: "Format")
func addFmt(_ title: String, _ action: Selector, _ key: String = "",
            _ mods: NSEvent.ModifierFlags = .command) {
    let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
    if !key.isEmpty { item.keyEquivalentModifierMask = mods }
    item.target = nil  // responder chain → key window's controller
    formatMenu.addItem(item)
}
addFmt("Bold", #selector(EditorController.cmdBold(_:)), "b")
addFmt("Italic", #selector(EditorController.cmdItalic(_:)), "i")
addFmt("Strikethrough", #selector(EditorController.cmdStrike(_:)))
addFmt("Inline Code", #selector(EditorController.cmdCode(_:)))
formatMenu.addItem(.separator())
addFmt("Heading 1", #selector(EditorController.cmdH1(_:)), "1")
addFmt("Heading 2", #selector(EditorController.cmdH2(_:)), "2")
addFmt("Heading 3", #selector(EditorController.cmdH3(_:)), "3")
addFmt("Body", #selector(EditorController.cmdBody(_:)), "0")
formatMenu.addItem(.separator())
addFmt("Bullet List", #selector(EditorController.cmdBullet(_:)))
addFmt("Numbered List", #selector(EditorController.cmdNumbered(_:)))
addFmt("Quote", #selector(EditorController.cmdQuote(_:)))
addFmt("Code Block", #selector(EditorController.cmdCodeBlock(_:)))
addFmt("Divider", #selector(EditorController.cmdDivider(_:)))
formatItem.submenu = formatMenu

let viewItem = NSMenuItem()
mainMenu.addItem(viewItem)
let viewMenu = NSMenu(title: "View")
let focusItem = NSMenuItem(title: "Focus Mode",
                          action: #selector(EditorController.toggleFocusMode(_:)), keyEquivalent: "f")
focusItem.keyEquivalentModifierMask = [.command, .control]
focusItem.target = nil  // responder chain → key window's controller
viewMenu.addItem(focusItem)
viewItem.submenu = viewMenu

app.mainMenu = mainMenu

// First window: a file passed on the command line (Finder "Open With" / `open -a Mallow file.md`),
// else the welcome demo. New / Open open further windows.
if CommandLine.arguments.count > 1,
   let content = try? String(contentsOfFile: CommandLine.arguments[1], encoding: .utf8) {
    makeEditor(content, CommandLine.arguments[1])
} else {
    makeEditor(demoText, nil)
}

app.activate(ignoringOtherApps: true)
app.run()
