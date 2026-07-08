// DocumentActions — the menu/command-driven operations on a document, moved off the old EditorController
// onto EditorDocument (which owns the text view + view-model). The SwiftUI `.commands` (MallowCommands)
// and the chrome call these; each one nudges `revision` so the chrome's title/dirty re-render.

import AppKit
import UniformTypeIdentifiers

extension EditorDocument {
    // MARK: View toggles

    /// Focus mode: dim every block but the caret's. Restyle first (clears any prior dim), then re-apply
    /// the dim when turning on — mirrors the old EditorController.toggleFocusMode.
    func toggleFocus() {
        vm.focusMode.toggle()
        vm.restyle()
        if vm.focusMode { vm.applyFocus() }
        markEdited()
    }

    /// Pin this window above other apps (per-window, transient). Sets the live NSWindow level.
    func toggleKeepOnTop() {
        vm.keepOnTop.toggle()
        hostWindow?.level = vm.keepOnTop ? .floating : .normal
        markEdited()
    }

    /// Fold All Sections: collapse every heading's body to a document outline (View ▸ Fold All Sections).
    /// State is re-derived from the parse each refresh; toggling just re-renders. When folding, nudge the
    /// caret out of a now-collapsed (zero-height, hidden) line so it isn't stranded on an invisible row.
    func toggleFoldAll() {
        vm.allSectionsFolded.toggle()
        vm.refresh()
        vm.parkCaretOutOfFold()   // park on the enclosing heading if the caret landed in a now-folded body
        vm.selectionChanged()     // snaps the caret out of a collapsed (hidden) inline run if it landed in one
        markEdited()
    }

    /// Fold/unfold just the section the caret is in (View ▸ Fold Section) — its enclosing heading's body.
    /// Independent of Fold All; per-section folds reset on edit (the VM owns that — see clearSectionFolds).
    func toggleFoldSection() {
        vm.toggleFoldSectionAtCaret()
        markEdited()
    }

    // MARK: Zoom (View ▸ Zoom In/Out/Actual Size) — clamp 0.5…3.0, step 1.1×, then re-render at scale.

    func zoomIn() { setZoom(vm.zoomFactor * 1.1) }
    func zoomOut() { setZoom(vm.zoomFactor / 1.1) }
    func zoomReset() { setZoom(1) }
    private func setZoom(_ z: CGFloat) {
        vm.zoomFactor = min(max(z, 0.5), 3.0)
        vm.refresh()
        markEdited()
    }

    // MARK: File ▸ Save / Save As

    func save() {
        if let path = vm.filePath { write(to: URL(fileURLWithPath: path)) } else { saveAs() }
    }

    func saveAs() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        // Seed the filename: a file-backed doc keeps its name; an untitled one is named from its first
        // heading (Notion-style — type a `# Title` and Save offers "Title.md"), else "Untitled.md".
        // The user can always edit the field before saving.
        if vm.displayName.hasSuffix(".md") {
            panel.nameFieldStringValue = vm.displayName
        } else {
            let title = vm.titleAsFileName
            panel.nameFieldStringValue = title.isEmpty ? "Untitled.md" : "\(title).md"
        }
        if panel.runModal() == .OK, let url = panel.url { write(to: url) }
    }

    private func write(to url: URL) {
        // Refuse to write onto a file another window is already editing (its autosave would clobber this,
        // and vice-versa). Saving to OUR OWN current path is allowed (excluding: self).
        if pathOpenInOtherWindow(url.path, excluding: self) {
            presentPathInUseAlert(path: url.path, anchor: hostWindow)
            return
        }
        let content = textView.string
        do {
            // Re-prepend the UTF-8 BOM if the file opened with one (the buffer text is BOM-free), so the
            // file's exact bytes are preserved; the saved baseline is the BOM-free buffer text.
            let onDisk = vm.hadBOM ? "\u{FEFF}" + content : content
            try onDisk.write(to: url, atomically: true, encoding: .utf8)
            vm.markSaved(path: url.path, content: content)
            RecentFiles.add(url.path)
            markEdited()   // .navigationTitle(doc.title) re-renders the window title + chrome dirty dot
        } catch {
            presentError(error)
        }
    }

    // MARK: File ▸ Export

    /// Export to PDF via the engine's HTML renderer + the WKWebView PDF exporter (the AppKit path).
    func exportPDF() {
        guard let url = exportPanel(ext: "pdf", type: .pdf) else { return }
        _ = PDFExporter(html: inkRenderHtml(textView.string, vm.baseName), to: url)
    }

    /// Export the engine-rendered standalone HTML.
    func exportHTML() {
        guard let url = exportPanel(ext: "html", type: .html) else { return }
        let html = inkRenderHtml(textView.string, vm.baseName)
        do { try html.write(to: url, atomically: true, encoding: .utf8) } catch { presentError(error) }
    }

    /// A Save panel pre-filled with `<docName>.<ext>` for `type`; nil if the user cancels.
    private func exportPanel(ext: String, type: UTType) -> URL? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [type]
        panel.nameFieldStringValue = "\(vm.baseName).\(ext)"
        return panel.runModal() == .OK ? panel.url : nil
    }

    private func presentError(_ error: Error) {
        NSAlert(error: error).present(anchoredTo: hostWindow)
    }
}
