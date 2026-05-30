// EditorController — the per-document window controller (Controller layer). It owns the window, the
// text view, and the titlebar chrome, and it sits in the responder chain so the key window's menu
// actions reach it. It holds no editor logic: text/selection delegate events and menu/button actions
// are forwarded to the EditorViewModel (commands, rendering) or to file/export services. Chrome (the
// centered filename + ● dot) is refreshed from the view-model's derived state.

import AppKit
import UniformTypeIdentifiers

final class EditorController: NSWindowController, NSTextViewDelegate, NSWindowDelegate, NSLayoutManagerDelegate {
    let textView: MarkdownTextView
    let vm: EditorViewModel
    weak var titleLabel: NSTextField?   // custom titlebar filename
    weak var dotView: NSView?           // ● modified-indicator slot

    init(textView: MarkdownTextView, window: NSWindow) {
        self.textView = textView
        self.vm = EditorViewModel(textView: textView)
        super.init(window: window)   // NSWindowController owns the window + sits in its responder chain
        textView.delegate = self
        window.delegate = self
        // Accessing layoutManager forces TextKit 1, where the glyph-generation delegate fires.
        textView.layoutManager?.delegate = self
        vm.refresh()
        updateChrome()
    }

    required init?(coder: NSCoder) { fatalError("EditorController is created in code, not a nib") }

    // MARK: chrome (the view-model decides the name + dirty flag; we render them)

    func updateChrome() {
        window?.isDocumentEdited = vm.isDirty
        let name = vm.displayName
        window?.title = name                  // still set (Window menu / Mission Control)
        titleLabel?.stringValue = name        // the visible centered filename
        dotView?.isHidden = !vm.isDirty       // ● shown only when there are unsaved edits
    }

    func setPath(_ path: String?) { vm.setPath(path); updateChrome() }

    // MARK: text-view + layout-manager delegate

    func textDidChange(_ notification: Notification) { vm.refresh(); updateChrome() }

    func textViewDidChangeSelection(_ notification: Notification) { vm.selectionChanged() }

    /// Mark hidden syntax glyphs as `.null` (zero-width, not drawn) from the view-model's set.
    func layoutManager(_ lm: NSLayoutManager,
                       shouldGenerateGlyphs glyphs: UnsafePointer<CGGlyph>,
                       properties props: UnsafePointer<NSLayoutManager.GlyphProperty>,
                       characterIndexes: UnsafePointer<Int>,
                       font: NSFont,
                       forGlyphRange glyphRange: NSRange) -> Int {
        let hidden = vm.hiddenChars
        if hidden.isEmpty { return 0 }  // 0 = no override, use default glyph generation
        var newProps = [NSLayoutManager.GlyphProperty](repeating: .null, count: glyphRange.length)
        var changed = false
        for i in 0 ..< glyphRange.length {
            if hidden.contains(characterIndexes[i]) {
                newProps[i] = .null
                changed = true
            } else {
                newProps[i] = props[i]
            }
        }
        if !changed { return 0 }
        lm.setGlyphs(glyphs, properties: &newProps,
                     characterIndexes: characterIndexes, font: font, forGlyphRange: glyphRange)
        return glyphRange.length
    }

    // MARK: format commands (responder-chain menu/button targets → view-model)

    @objc func toggleFocusMode(_ sender: Any?) {
        vm.focusMode.toggle()
        (sender as? NSMenuItem)?.state = vm.focusMode ? .on : .off
        vm.restyle()                       // restore normal colors
        if vm.focusMode { vm.applyFocus() }
    }
    @objc func cmdBold(_ s: Any?) { vm.apply("toggle_strong"); updateChrome() }
    @objc func cmdItalic(_ s: Any?) { vm.apply("toggle_emphasis"); updateChrome() }
    @objc func cmdStrike(_ s: Any?) { vm.apply("toggle_strikethrough"); updateChrome() }
    @objc func cmdCode(_ s: Any?) { vm.apply("toggle_inline_code"); updateChrome() }
    @objc func cmdH1(_ s: Any?) { vm.applyHeading(1); updateChrome() }
    @objc func cmdH2(_ s: Any?) { vm.applyHeading(2); updateChrome() }
    @objc func cmdH3(_ s: Any?) { vm.applyHeading(3); updateChrome() }
    @objc func cmdBody(_ s: Any?) { vm.applyHeading(0); updateChrome() }
    @objc func cmdBullet(_ s: Any?) { vm.apply("toggle_bullet_list"); updateChrome() }
    @objc func cmdNumbered(_ s: Any?) { vm.apply("toggle_ordered_list"); updateChrome() }
    @objc func cmdQuote(_ s: Any?) { vm.apply("toggle_blockquote"); updateChrome() }
    @objc func cmdCodeBlock(_ s: Any?) { vm.apply("toggle_code_block"); updateChrome() }
    @objc func cmdDivider(_ s: Any?) { vm.apply("insert_divider"); updateChrome() }

    // MARK: titlebar buttons

    /// Style button → pop the Format menu under the button (the Mallow ✏️ panel's role).
    @objc func showStyleMenu(_ sender: NSButton) {
        if let fmt = NSApp.mainMenu?.item(withTitle: "Format")?.submenu {
            fmt.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
        }
    }

    /// Info button → a small popover with the document's word / character counts.
    @objc func showInfo(_ sender: NSButton) {
        let s = textView.string
        let words = s.split { $0 == " " || $0 == "\n" || $0 == "\t" }.count
        let chars = s.count
        let pop = NSPopover()
        pop.behavior = .transient
        let vc = NSViewController()
        let label = NSTextField(labelWithString: "Words  \(words)\nCharacters  \(chars)")
        label.font = NSFont.systemFont(ofSize: 13)
        label.maximumNumberOfLines = 2
        let v = NSView(frame: NSRect(x: 0, y: 0, width: 180, height: 64))
        label.frame = NSRect(x: 16, y: 14, width: 148, height: 36)
        v.addSubview(label)
        vc.view = v
        pop.contentViewController = vc
        pop.show(relativeTo: sender.bounds, of: sender, preferredEdge: .maxY)
    }

    // MARK: file I/O + export (the @objc menu targets; writes go through the view-model state)

    func confirmDiscardIfDirty() -> Bool {
        guard vm.isDirty else { return true }
        window?.makeKeyAndOrderFront(nil)  // surface WHICH document is prompting (e.g. during ⌘Q)
        let alert = NSAlert()
        alert.messageText = "Discard unsaved changes?"
        alert.informativeText = "The current document has edits that haven't been saved."
        alert.addButton(withTitle: "Discard")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    @objc func saveDocument(_ sender: Any?) {
        if let path = vm.filePath { write(to: URL(fileURLWithPath: path)) } else { saveDocumentAs(sender) }
    }
    @objc func saveDocumentAs(_ sender: Any?) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.nameFieldStringValue = vm.displayName.hasSuffix(".md") ? vm.displayName : "Untitled.md"
        if panel.runModal() == .OK, let url = panel.url { write(to: url) }
    }
    private func write(to url: URL) {
        let content = textView.string
        do {
            try content.write(to: url, atomically: true, encoding: .utf8)
            vm.markSaved(path: url.path, content: content)
            updateChrome()
            RecentFiles.add(url.path)
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    @objc func exportHTML(_ sender: Any?) {
        let title = vm.displayName.replacingOccurrences(of: ".md", with: "")
        let html = inkRenderHtml(textView.string, title)
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.html]
        panel.nameFieldStringValue = "\(title).html"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try html.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    @objc func exportPDF(_ sender: Any?) {
        let title = vm.displayName.replacingOccurrences(of: ".md", with: "")
        let html = inkRenderHtml(textView.string, title)
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = "\(title).pdf"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        _ = PDFExporter(html: html, to: url)
    }

    // MARK: window lifecycle

    func windowShouldClose(_ sender: NSWindow) -> Bool { confirmDiscardIfDirty() }

    /// Drop this window's controller once it closes so it (and its window) deallocate. Deferred so we
    /// never release ourselves from inside our own delegate callback.
    func windowWillClose(_ notification: Notification) {
        DispatchQueue.main.async { editors.removeAll { $0 === self } }
    }
}
