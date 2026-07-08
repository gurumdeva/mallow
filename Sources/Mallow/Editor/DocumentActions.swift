// DocumentActions — the menu/command-driven operations on a document, moved off the old EditorController
// onto EditorDocument (which owns the text view + view-model). The SwiftUI `.commands` (MallowCommands)
// and the chrome call these; each one nudges `revision` so the chrome's title/dirty re-render.

import AppKit
import UniformTypeIdentifiers

extension EditorDocument {
    // MARK: View toggles

    /// Focus mode: dim every block but the caret's. The recompute recipe (restyle → re-apply dim) lives
    /// on the VM (`setFocusMode`); this is just the menu-glue toggle + chrome bump.
    func toggleFocus() {
        vm.setFocusMode(!vm.focusMode)
        markEdited()
    }

    /// Pin this window above other apps (per-window, transient). Sets the live NSWindow level.
    func toggleKeepOnTop() {
        vm.keepOnTop.toggle()
        hostWindow?.level = vm.keepOnTop ? .floating : .normal
        markEdited()
    }

    /// Fold All Sections: collapse every heading's body to a document outline (View ▸ Fold All Sections).
    /// The recompute recipe (refresh → park caret → snap selection) lives on the VM (`setFoldAll`); this
    /// is just the menu-glue toggle + chrome bump.
    func toggleFoldAll() {
        vm.setFoldAll(!vm.allSectionsFolded)
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
        // Manual save is loud: surface the other-window conflict and any write error via an alert.
        // (RecentFiles is bumped here, not inside `persist`, because recency should track explicit
        // saves — a background autosave shouldn't reorder the Open Recent menu.)
        switch persist(to: url) {
        case .saved:      RecentFiles.add(url.path)
        case .pathInUse:  presentPathInUseAlert(path: url.path, anchor: hostWindow)
        case .failed(let error): presentError(error)
        }
    }

    /// Outcome of a `persist(to:)` attempt, so the two callers can react differently: manual save
    /// alerts on `.pathInUse` / `.failed`; debounced autosave ignores every outcome (stays silent).
    enum PersistResult {
        case saved
        case pathInUse        // another window is the live writer for this path — don't clobber it
        case failed(Error)    // the atomic write threw
    }

    /// The single write routine shared by manual save (`write(to:)`) and debounced autosave
    /// (`EditorBehaviors.performAutosave`). Both need the same five steps and previously duplicated
    /// them: the other-window guard (single-writer-per-file), the UTF-8 BOM re-prepend (so a file that
    /// opened with a BOM keeps its exact bytes while the saved baseline stays BOM-free), the atomic
    /// utf8 write, the `markSaved` baseline update, and the chrome bump. Returns the outcome; callers
    /// decide how loudly to surface it.
    func persist(to url: URL) -> PersistResult {
        // Refuse to write onto a file another window is already editing (its autosave would clobber
        // this, and vice-versa). Saving to OUR OWN current path is allowed (excluding: self).
        if pathOpenInOtherWindow(url.path, excluding: self) { return .pathInUse }
        let content = textView.string
        let onDisk = vm.hadBOM ? "\u{FEFF}" + content : content
        do {
            try onDisk.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            return .failed(error)
        }
        vm.markSaved(path: url.path, content: content)
        markEdited()   // .navigationTitle(doc.title) re-renders the window title + chrome dirty dot
        return .saved
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
