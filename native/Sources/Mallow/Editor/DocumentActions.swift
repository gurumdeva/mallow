// DocumentActions — the menu/command-driven operations on a document, moved off the old EditorController
// onto EditorDocument (which owns the text view + view-model). The SwiftUI `.commands` (MallowCommands)
// and the chrome call these; each one nudges `revision` so the chrome's title/dirty re-render.

import AppKit
import UniformTypeIdentifiers

extension EditorDocument {
    private var window: NSWindow? { textView.window }

    // MARK: View toggles

    /// Focus mode: dim every block but the caret's. Restyle first (clears any prior dim), then re-apply
    /// the dim when turning on — mirrors the old EditorController.toggleFocusMode.
    func toggleFocus() {
        vm.focusMode.toggle()
        vm.restyle()
        if vm.focusMode { vm.applyFocus() }
        revision &+= 1
    }

    /// Pin this window above other apps (per-window, transient). Sets the live NSWindow level.
    func toggleKeepOnTop() {
        vm.keepOnTop.toggle()
        window?.level = vm.keepOnTop ? .floating : .normal
        revision &+= 1
    }

    // MARK: Zoom (View ▸ Zoom In/Out/Actual Size) — clamp 0.5…3.0, step 1.1×, then re-render at scale.

    func zoomIn() { setZoom(vm.zoomFactor * 1.1) }
    func zoomOut() { setZoom(vm.zoomFactor / 1.1) }
    func zoomReset() { setZoom(1) }
    private func setZoom(_ z: CGFloat) {
        vm.zoomFactor = min(max(z, 0.5), 3.0)
        vm.refresh()
        revision &+= 1
    }

    // MARK: File ▸ Save / Save As

    func save() {
        if let path = vm.filePath { write(to: URL(fileURLWithPath: path)) } else { saveAs() }
    }

    func saveAs() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.nameFieldStringValue = vm.displayName.hasSuffix(".md") ? vm.displayName : "Untitled.md"
        if panel.runModal() == .OK, let url = panel.url { write(to: url) }
    }

    private func write(to url: URL) {
        // Refuse to write onto a file another window is already editing (its autosave would clobber this,
        // and vice-versa). Saving to OUR OWN current path is allowed (excluding: self).
        if pathOpenInOtherWindow(url.path, excluding: self) {
            presentPathInUseAlert(path: url.path, anchor: window)
            return
        }
        let content = textView.string
        do {
            try content.write(to: url, atomically: true, encoding: .utf8)
            vm.markSaved(path: url.path, content: content)
            RecentFiles.add(url.path)
            window?.title = vm.displayName
            revision &+= 1
        } catch {
            presentError(error)
        }
    }

    // MARK: File ▸ Export

    /// Export to PDF via the engine's HTML renderer + the WKWebView PDF exporter (the AppKit path).
    func exportPDF() {
        let title = vm.baseName
        let html = inkRenderHtml(textView.string, title)
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = "\(title).pdf"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        _ = PDFExporter(html: html, to: url)
    }

    /// Export the engine-rendered standalone HTML.
    func exportHTML() {
        let title = vm.baseName
        let html = inkRenderHtml(textView.string, title)
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.html]
        panel.nameFieldStringValue = "\(title).html"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try html.write(to: url, atomically: true, encoding: .utf8) } catch { presentError(error) }
    }

    private func presentError(_ error: Error) {
        let alert = NSAlert(error: error)
        if let window { alert.beginSheetModal(for: window) } else { alert.runModal() }
    }
}
