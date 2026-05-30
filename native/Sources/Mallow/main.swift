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
appMenu.addItem(withTitle: L.t("menu.quit"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
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
addFile(L.t("menu.new"), #selector(AppDelegate.newDocument(_:)), "n", target: appDelegate)
addFile(L.t("menu.open"), #selector(AppDelegate.openDocument(_:)), "o", target: appDelegate)
let recentItem = NSMenuItem(title: L.t("menu.openRecent"), action: nil, keyEquivalent: "")
recentItem.submenu = recentMenu
fileMenu.addItem(recentItem)
rebuildRecentMenu()
addFile(L.t("menu.save"), #selector(EditorController.saveDocument(_:)), "s")
addFile(L.t("menu.saveAs"), #selector(EditorController.saveDocumentAs(_:)), "s", [.command, .shift])
fileMenu.addItem(.separator())
addFile(L.t("menu.exportPdf"), #selector(EditorController.exportPDF(_:)), "e")
addFile(L.t("menu.exportHtml"), #selector(EditorController.exportHTML(_:)), "e", [.command, .shift])
fileMenu.addItem(.separator())
addFile(L.t("menu.close"), #selector(NSWindow.performClose(_:)), "w")
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
addEdit(L.t("menu.undo"), Selector(("undo:")), "z")
addEdit(L.t("menu.redo"), Selector(("redo:")), "z", [.command, .shift])
editMenu.addItem(.separator())
addEdit(L.t("menu.cut"), #selector(NSText.cut(_:)), "x")
addEdit(L.t("menu.copy"), #selector(NSText.copy(_:)), "c")
addEdit(L.t("menu.paste"), #selector(NSText.paste(_:)), "v")
// ClipboardExtras: Paste and Match Style (⇧⌘V) + Copy as Rich Text (⌥⌘C). target nil → responder
// chain to the key window's EditorController (same as the other Edit items).
addEdit(L.t("menu.pasteMatchStyle"), #selector(EditorController.pasteAsPlainText(_:)), "v", [.command, .shift])
addEdit(L.t("menu.copyRichText"), #selector(EditorController.copyAsRichText(_:)), "c", [.command, .option])
addEdit(L.t("menu.selectAll"), #selector(NSText.selectAll(_:)), "a")
editMenu.addItem(.separator())
addEdit(L.t("menu.find"), #selector(NSTextView.performFindPanelAction(_:)), "f", tag: 1)
addEdit(L.t("menu.findNext"), #selector(NSTextView.performFindPanelAction(_:)), "g", tag: 2)
addEdit(L.t("menu.findPrevious"), #selector(NSTextView.performFindPanelAction(_:)), "g", [.command, .shift], tag: 3)
addEdit(L.t("menu.useSelectionForFind"), #selector(NSTextView.performFindPanelAction(_:)), "e", tag: 7)
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
addFmt(L.t("format.bold"), #selector(EditorController.cmdBold(_:)), "b")
addFmt(L.t("format.italic"), #selector(EditorController.cmdItalic(_:)), "i")
addFmt(L.t("format.strikethrough"), #selector(EditorController.cmdStrike(_:)))
addFmt(L.t("format.inlineCode"), #selector(EditorController.cmdCode(_:)))
formatMenu.addItem(.separator())
addFmt(L.t("format.h1"), #selector(EditorController.cmdH1(_:)), "1")
addFmt(L.t("format.h2"), #selector(EditorController.cmdH2(_:)), "2")
addFmt(L.t("format.h3"), #selector(EditorController.cmdH3(_:)), "3")
// Body uses ⌥⌘0 (not ⌘0) so View ▸ Actual Size (TextZoom) can own ⌘0, the macOS-standard reset key.
addFmt(L.t("format.body"), #selector(EditorController.cmdBody(_:)), "0", [.command, .option])
formatMenu.addItem(.separator())
addFmt(L.t("format.bullet"), #selector(EditorController.cmdBullet(_:)))
addFmt(L.t("format.numbered"), #selector(EditorController.cmdNumbered(_:)))
addFmt(L.t("format.quote"), #selector(EditorController.cmdQuote(_:)))
addFmt(L.t("format.codeBlock"), #selector(EditorController.cmdCodeBlock(_:)))
addFmt(L.t("format.divider"), #selector(EditorController.cmdDivider(_:)))
formatItem.submenu = formatMenu

let viewItem = NSMenuItem()
mainMenu.addItem(viewItem)
let viewMenu = NSMenu(title: "View")   // internal id — keep literal "View"
let focusItem = NSMenuItem(title: L.t("menu.focusMode"),
                          action: #selector(EditorController.toggleFocusMode(_:)), keyEquivalent: "f")
focusItem.keyEquivalentModifierMask = [.command, .control]
focusItem.target = nil  // responder chain → key window's controller
viewMenu.addItem(focusItem)
// KeepOnTop: pin the key window above other apps (no accelerator).
let keepOnTopItem = NSMenuItem(title: L.t("menu.keepOnTop"),
                          action: #selector(EditorController.toggleKeepOnTop(_:)), keyEquivalent: "")
keepOnTopItem.target = nil  // responder chain → key window's controller
viewMenu.addItem(keepOnTopItem)
// TypewriterScroll: keep the caret line vertically centered (⌃⌘T).
let typewriterItem = NSMenuItem(title: L.t("menu.typewriter"),
                                action: #selector(EditorController.toggleTypewriter(_:)), keyEquivalent: "t")
typewriterItem.keyEquivalentModifierMask = [.command, .control]
typewriterItem.target = nil  // responder chain → key window's controller
viewMenu.addItem(typewriterItem)
// InfoPanel: the ⇧⌘I document-info popover (also opened by the titlebar info button).
let infoItem = NSMenuItem(title: L.t("menu.documentInfo"),
                          action: #selector(EditorController.showDocumentInfo(_:)), keyEquivalent: "i")
infoItem.keyEquivalentModifierMask = [.command, .shift]
infoItem.target = nil  // responder chain → key window's controller
viewMenu.addItem(infoItem)
// TextZoom: ⌘+ / ⌘− / ⌘0 per-window text zoom. ⌘0 = Actual Size (macOS norm); Format ▸ Body was
// moved to ⌥⌘0 to free ⌘0 for this (the earlier-installed Format item would otherwise shadow it).
viewMenu.addItem(.separator())
func addZoom(_ title: String, _ sel: Selector, _ key: String) {
    let item = NSMenuItem(title: title, action: sel, keyEquivalent: key)
    item.keyEquivalentModifierMask = .command
    item.target = nil  // responder chain → key window's controller
    viewMenu.addItem(item)
}
addZoom(L.t("menu.zoomIn"), #selector(EditorController.zoomIn(_:)), "+")
addZoom(L.t("menu.zoomOut"), #selector(EditorController.zoomOut(_:)), "-")
addZoom(L.t("menu.actualSize"), #selector(EditorController.zoomReset(_:)), "0")
viewItem.submenu = viewMenu

app.mainMenu = mainMenu

// First window: SessionRestore decides — an explicit CLI/Finder file (`open -a Mallow file.md`)
// wins; else silently reopen last session's document; else the welcome demo on first run; else blank.
// New / Open open further windows.
let explicitArg = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : nil
switch SessionStore.planStartup(explicitPath: explicitArg, demo: demoText) {
case .explicit(let content, let path): makeEditor(content, path)
case .restore(let content, let path):  makeEditor(content, path)
case .welcome:                         makeEditor(demoText, nil)
case .blank:                           makeEditor("", nil)
}

app.activate(ignoringOtherApps: true)
app.run()
