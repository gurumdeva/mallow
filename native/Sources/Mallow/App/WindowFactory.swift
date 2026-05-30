// WindowFactory — builds, shows, and retains an editor window. Each open document is its own
// window + EditorController, retained in `editors` and dropped on close (windowWillClose). Wires the
// Mallow chrome: transparent dark titlebar, the chrome overlay, and the editor scroll view.

import AppKit

/// All open editor windows; documents live independently (one document per window).
var editors: [EditorController] = []

/// Build, show, and retain a new editor window holding `content` (backed by `path` if given).
@discardableResult
func makeEditor(_ content: String, _ path: String?) -> EditorController {
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 760, height: 560),
        styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
        backing: .buffered, defer: false
    )
    window.center()
    // Mallow chrome: transparent titlebar, hidden native title, dark bg, drag-anywhere.
    window.titlebarAppearsTransparent = true
    window.titleVisibility = .hidden
    window.backgroundColor = mallowBG
    window.appearance = NSAppearance(named: .darkAqua)   // match the dark reference (light theme: TODO)
    window.isMovableByWindowBackground = true
    let scroll = NSScrollView(frame: window.contentView!.bounds)
    scroll.autoresizingMask = [.width, .height]
    scroll.hasVerticalScroller = true
    scroll.drawsBackground = false
    let textView = MarkdownTextView(frame: scroll.bounds)
    configureTextView(textView)
    textView.string = content
    textView.setSelectedRange(NSRange(location: 0, length: 0))  // caret to top
    scroll.documentView = textView
    window.contentView!.addSubview(scroll)
    let controller = EditorController(textView: textView, window: window)
    // The Mallow-style titlebar overlay (centered filename + corner buttons), pinned to the top.
    let chrome = makeChromeBar(controller)
    window.contentView!.addSubview(chrome)
    NSLayoutConstraint.activate([
        chrome.topAnchor.constraint(equalTo: window.contentView!.topAnchor),
        chrome.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor),
        chrome.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor),
        chrome.heightAnchor.constraint(equalToConstant: 52),
    ])
    controller.setPath(path)   // refresh the chrome label now that it's wired
    if let path = path { RecentFiles.add(path) }   // remember opened files
    // SessionRestore: the FIRST window inherits last session's saved frame (clamped on-screen);
    // later windows keep their centered/cascade position. Done before ordering front so it appears
    // at the restored geometry, not centered-then-jumping.
    let isFirstWindow = editors.isEmpty
    editors.append(controller)
    if isFirstWindow, let frame = SessionStore.restoredFrame() {
        window.setFrame(frame, display: false)
    }
    controller.sessionObservers = SessionStore.track(window: window, controller: controller)   // persist geometry + last-file (tokens removed on close)
    window.makeKeyAndOrderFront(nil)
    window.makeFirstResponder(textView)   // editor ready to type immediately on open (like Mallow)
    return controller
}
