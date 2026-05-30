// EditorController — the per-document window controller (Controller layer). It owns the window, the
// text view, and the titlebar chrome, and it sits in the responder chain so the key window's menu
// actions reach it. It holds no editor logic: text/selection delegate events and menu/button actions
// are forwarded to the EditorViewModel (commands, rendering) or to file/export services. Chrome (the
// centered filename + ● dot) is refreshed from the view-model's derived state.

import AppKit
import UniformTypeIdentifiers

final class EditorController: NSWindowController, NSTextViewDelegate, NSWindowDelegate, NSLayoutManagerDelegate, NSMenuItemValidation {
    let textView: MarkdownTextView
    let vm: EditorViewModel
    weak var titleLabel: NSTextField?   // custom titlebar filename
    weak var dotView: NSView?           // ● modified-indicator slot
    var typewriterOn = false            // View ▸ Typewriter Scrolling (caret line kept centered)
    var autosaveTimer: Timer?           // debounced background save (Autosave.swift); nil when idle
    var sessionObservers: [NSObjectProtocol] = []   // SessionRestore geometry/last-file observers; removed on close
    private var stylePopover: NSPopover?             // retained while the Text-Style popover is shown

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

    /// Single merged menu validator for the key window (the menu bar is app-global, so checkmarks can
    /// drift when another window toggled a shared item — fix them here before the menu shows). Each
    /// feature folds its branch in: KeepOnTop / Typewriter set their checkmark; ClipboardExtras greys
    /// out its two items when they can't act. Every other selector returns true so the built-in
    /// Edit/File/Format items keep validating as before.
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(toggleFocusMode(_:)):
            item.state = vm.focusMode ? .on : .off   // per-window, like the toggles below — keep it in sync
            return true
        case #selector(toggleKeepOnTop(_:)):
            item.state = vm.keepOnTop ? .on : .off
            return true
        case #selector(toggleTypewriter(_:)):
            item.state = typewriterOn ? .on : .off
            return true
        default:
            return validateClipboardExtra(item)   // answers its own two items, true for the rest
        }
    }

    // MARK: text-view + layout-manager delegate

    func textDidChange(_ notification: Notification) { vm.refresh(); updateChrome(); scheduleAutosave() }

    func textViewDidChangeSelection(_ notification: Notification) {
        vm.selectionChanged()
        if typewriterOn { centerCaretLine() }
    }

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

    /// Style button → the Text-Style popover (the Mallow ✏️ panel's role), anchored under the button.
    /// Replaces the old Format-menu popUp whose `item(withTitle:"Format")` lookup was always nil.
    @objc func showStyleMenu(_ sender: NSButton) {
        let pop = makeStylePopover(self)
        stylePopover = pop
        pop.show(relativeTo: sender.bounds, of: sender, preferredEdge: .maxY)
    }

    // MARK: file I/O + export (the @objc menu targets; writes go through the view-model state)

    func confirmDiscardIfDirty() -> Bool {
        guard vm.isDirty else { return true }
        window?.makeKeyAndOrderFront(nil)  // surface WHICH document is prompting (e.g. during ⌘Q)
        let alert = NSAlert()
        alert.messageText = L.t("dialog.discard.title")
        alert.informativeText = L.t("dialog.discard.body")
        alert.addButton(withTitle: L.t("dialog.discard.confirm"))
        alert.addButton(withTitle: L.t("dialog.discard.cancel"))
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

    /// Regaining focus re-syncs this window with its file on disk (ExternalReload): silent reload
    /// when there are no local edits, prompt on conflict. No-op with no path / no external change.
    func windowDidBecomeKey(_ notification: Notification) { reloadFromDiskIfChanged() }

    func windowShouldClose(_ sender: NSWindow) -> Bool { confirmDiscardIfDirty() }

    /// Drop this window's controller once it closes so it (and its window) deallocate. Deferred so we
    /// never release ourselves from inside our own delegate callback.
    func windowWillClose(_ notification: Notification) {
        cancelAutosave()
        sessionObservers.forEach { NotificationCenter.default.removeObserver($0) }   // no per-window observer leak
        DispatchQueue.main.async { editors.removeAll { $0 === self } }
    }
}
