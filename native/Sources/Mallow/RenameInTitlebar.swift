// RenameInTitlebar — click the centered titlebar filename to rename the file on disk (View/Controller
// glue, mirroring Mallow's FilenamePopover + FileService.applyRename). A small popover with a text
// field opens under the name; on commit we rename the actual file in the SAME folder via FileManager
// and update the view-model's path + chrome + Open Recent. Untitled (unsaved) documents have no disk
// file yet, so there's nothing to rename — we fall back to Save As (the save panel), like the
// reference. All file-name validation lives here (no engine round-trip needed for a pure path op).
//
// The titlebar label is a plain NSTextField (see ChromeBar.makeChromeBar); the integrator attaches an
// NSClickGestureRecognizer to it targeting `renameFromTitlebar(_:)` (see sharedChanges), so the label
// stays a label and updateChrome()'s `titleLabel?.stringValue = name` keeps working unchanged.

import AppKit

// MARK: - Filename validation (ported from Document.normalizeFilename + the Rust rename_file guard)

enum RenameValidation {
    /// Normalize a user-typed name to a `*.md` filename, or nil if it can't be a safe filename.
    /// Rules (verbatim from the Tauri `Document.normalizeFilename`): trim whitespace, drop a trailing
    /// `.md` (case-insensitive) then re-add it, require a non-empty base, and reject anything that
    /// could escape the folder or overwrite a sibling — a path separator (`/` or `\`) or the special
    /// names `.` / `..`. The disk path is built as `<same folder>/<this name>`, so these are the only
    /// inputs that could break out; blocking them here is the first line of defense.
    static func normalize(_ name: String) -> String? {
        var base = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if base.lowercased().hasSuffix(".md") {
            base = String(base.dropLast(3)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if base.isEmpty { return nil }
        if base.contains("/") || base.contains("\\") || base == "." || base == ".." { return nil }
        return base + ".md"
    }
}

/// Why a rename couldn't be applied — used to pick the alert message (mirrors the Tauri RenameError).
private enum RenameFailure: Error {
    case invalid   // empty / contains a separator / "." / ".."
    case exists    // a *different* file already has that name in the folder
}

// MARK: - Titlebar rename action + popover

extension EditorController {
    /// Titlebar filename click → rename. Saved documents get the inline rename popover; untitled
    /// documents have no file on disk yet, so there's nothing to rename — fall back to Save As.
    @objc func renameFromTitlebar(_ sender: Any?) {
        guard vm.filePath != nil else { saveDocumentAs(sender); return }
        let anchor = (sender as? NSView) ?? titleButton ?? window?.contentView
        guard let anchor = anchor else { return }
        presentRenamePopover(from: anchor)
    }

    /// Show a small popover with a text field pre-filled with the current name, selected for retype.
    private func presentRenamePopover(from anchor: NSView) {
        let pop = NSPopover()
        pop.behavior = .transient
        pop.appearance = NSAppearance(named: .darkAqua)   // match the dark chrome

        let field = RenameField(frame: NSRect(x: 16, y: 14, width: 208, height: 24))
        field.stringValue = vm.displayName
        field.font = NSFont.systemFont(ofSize: 13)
        field.placeholderString = L.t("rename.placeholder")
        field.lineBreakMode = .byTruncatingMiddle
        field.bezelStyle = .roundedBezel
        field.isBezeled = true

        // Commit on Return, dismiss on Escape. The field forwards both to us; the closures capture the
        // popover weakly so dismissing can't retain it past close.
        field.onCommit = { [weak self, weak pop] in
            guard let self = self else { return }
            let name = field.stringValue
            // Close first so a failure alert (modal) isn't drawn under a transient popover.
            pop?.performClose(nil)
            self.commitRename(to: name, from: anchor)
        }
        field.onCancel = { [weak pop] in pop?.performClose(nil) }

        let vc = NSViewController()
        let v = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 52))
        v.addSubview(field)
        vc.view = v
        pop.contentViewController = vc
        pop.contentSize = v.frame.size
        pop.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
        // Focus + select the whole name so the user can immediately retype (like FilenamePopover).
        pop.contentViewController?.view.window?.makeFirstResponder(field)
        field.selectText(nil)
    }

    /// Validate + perform the rename of the on-disk file, then update path / chrome / Open Recent.
    /// No-ops silently when the name is unchanged; surfaces an alert on a validation/IO failure.
    private func commitRename(to typed: String, from anchor: NSView) {
        // Re-read the path at commit time (it may have changed via Save As while the popover was up).
        guard let oldPath = vm.filePath else { return }
        do {
            guard let newName = RenameValidation.normalize(typed) else { throw RenameFailure.invalid }
            let oldURL = URL(fileURLWithPath: oldPath)
            // Same folder + new name — never trust the typed string to carry its own directory.
            let newURL = oldURL.deletingLastPathComponent().appendingPathComponent(newName)
            if newURL.lastPathComponent == oldURL.lastPathComponent { return }  // unchanged → no-op

            let fm = FileManager.default
            // Refuse to clobber a *different* existing file. A case-only rename on a case-insensitive
            // volume (foo.md → Foo.md) resolves to the same file, so allow it (compare resolved paths).
            if fm.fileExists(atPath: newURL.path) {
                let sameFile = (try? oldURL.resourceValues(forKeys: [.canonicalPathKey]).canonicalPath)
                    == (try? newURL.resourceValues(forKeys: [.canonicalPathKey]).canonicalPath)
                if !sameFile { throw RenameFailure.exists }
            }

            try fm.moveItem(at: oldURL, to: newURL)
            // The file's CONTENT is unchanged, so the saved baseline still matches — only the path
            // moves. The controller's setPath updates vm.filePath (+ displayName) and refreshes the
            // chrome, without touching the dirty baseline (so a clean doc stays clean after rename).
            setPath(newURL.path)
            RecentFiles.add(newURL.path)        // also drops the stale old path (filtered: missing now)
        } catch {
            presentRenameError(error, from: anchor)
        }
    }

    /// Show a brief alert (sheet on the window) explaining why the rename failed.
    private func presentRenameError(_ error: Error, from anchor: NSView) {
        let alert = NSAlert()
        switch error {
        case RenameFailure.invalid:
            alert.messageText = L.t("rename.error.invalid.title")
            alert.informativeText = L.t("rename.error.invalid.body")
        case RenameFailure.exists:
            alert.messageText = L.t("rename.error.exists.title")
            alert.informativeText = L.t("rename.error.exists.body")
        default:
            alert.messageText = L.t("rename.error.failed.title")
            alert.informativeText = error.localizedDescription
        }
        alert.addButton(withTitle: L.t("common.ok"))
        if let window = window {
            alert.beginSheetModal(for: window, completionHandler: nil)
        } else {
            alert.runModal()
        }
    }
}

// MARK: - Rename text field

/// An NSTextField that reports Return / Escape to closures, so the popover can commit or dismiss
/// without a delegate object. (Mirrors FilenamePopover's keydown handling.)
final class RenameField: NSTextField {
    var onCommit: (() -> Void)?
    var onCancel: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36, 76:                       // Return / keypad Enter → commit
            onCommit?()
        case 53:                           // Escape → cancel
            onCancel?()
        default:
            super.keyDown(with: event)
        }
    }

    // Escape can also arrive as a cancelOperation through the responder chain (field editor).
    override func cancelOperation(_ sender: Any?) { onCancel?() }
}
