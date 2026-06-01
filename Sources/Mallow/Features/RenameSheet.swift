// RenameSheet — the SwiftUI rename sheet, shown when the user clicks the titlebar filename (the
// SwiftUI re-port of the AppKit RenameInTitlebar popover). A small dark surface with a text field
// pre-filled with the current filename + Cancel / Rename buttons; on submit it renames the actual file
// on disk — FileManager.moveItem within the SAME folder — then updates the document's path and bumps
// `revision` so the chrome's filename re-renders. Untitled (unsaved) documents have no file on disk
// yet, so there is nothing to rename; we just dismiss (a Save As fallback would belong on the lead,
// which owns the save panel — out of scope for a self-contained sheet).
//
// `RenameValidation` is REUSED VERBATIM from the AppKit RenameInTitlebar.swift (the pure
// normalize-a-typed-filename enum), as is the disk-rename logic (same-folder move + canonical-path
// clobber check). All file-name validation lives in that enum — no engine round-trip is needed for a
// pure path op. Colors come from the shared `Theme` tokens so light/dark tracks the editor.
//
// Integration (the lead adds these to EditorWindow in App/MallowApp.swift):
//   @State private var showRename = false
//   ChromeBar(… onRename: { showRename = true })
//   .sheet(isPresented: $showRename) { RenameSheet(doc: doc) }

import SwiftUI
import AppKit

// MARK: - Filename validation (copied VERBATIM from the AppKit RenameInTitlebar.swift)

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

/// Why a rename couldn't be applied — used to pick the alert message (mirrors the AppKit RenameError).
private enum RenameFailure: Error {
    case invalid   // empty / contains a separator / "." / ".."
    case exists    // a *different* file already has that name in the folder
}

// MARK: - The sheet

/// A modal rename sheet over the editor window. Owns the typed name + an optional inline error; on
/// submit it validates, renames the on-disk file in place, updates the document, and dismisses.
struct RenameSheet: View {
    /// The per-window document: `vm.displayName` seeds the field, `vm.filePath` is the file to rename,
    /// and `revision` is bumped after a successful rename so the chrome's filename re-renders.
    let doc: EditorDocument

    /// Supplied by `.sheet(...)` — closes the sheet (Cancel, a successful rename, or an unsaved no-op).
    @Environment(\.dismiss) private var dismiss

    /// The editable filename, seeded once from the current name. The user retypes over the selection.
    @State private var name: String
    /// A short inline message shown under the field when a rename fails (invalid / name taken / IO).
    @State private var errorText: String?
    /// Drives initial focus + select-all on the field so the user can immediately retype the name.
    @FocusState private var fieldFocused: Bool

    init(doc: EditorDocument) {
        self.doc = doc
        _name = State(initialValue: doc.vm.displayName)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // The filename field — dark elevated surface, ~13pt, submits on Return (→ commit()).
            TextField(L.t("rename.placeholder"), text: $name)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(Theme.text)
                .focused($fieldFocused)
                .onSubmit(commit)                 // Return triggers the (default) Rename action
                .padding(.vertical, 7)
                .padding(.horizontal, 10)
                .background(Theme.elevated, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(Theme.border, lineWidth: 1)
                )

            // Inline failure message (only after a failed attempt) — kept in-sheet so the user can fix
            // the name without a separate alert getting in the way.
            if let errorText {
                Text(errorText)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Cancel (Escape) + Rename (default / Return). No good localization key exists for these in
            // this context (menu.close would be wrong), so they stay literal.
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Rename", action: commit)
                    .keyboardShortcut(.defaultAction)   // Return + the highlighted default button
            }
        }
        .padding(16)
        .frame(width: 280)
        .background(Theme.bg)
        .onAppear {
            // Focus the field so the name is editable immediately (SwiftUI selects all on first focus).
            fieldFocused = true
        }
    }

    // MARK: - Commit

    /// Validate the typed name and rename the on-disk file in the SAME folder, then update the document
    /// and dismiss. No-ops (and dismisses) for an unsaved document or an unchanged name; surfaces an
    /// inline message + an NSAlert on a validation / IO failure.
    private func commit() {
        // Unsaved (untitled) document → no file on disk to rename. Do nothing destructive; just close.
        // (A Save As fallback like the AppKit version's belongs on the lead, which owns the save panel.)
        guard let oldPath = doc.vm.filePath else { dismiss(); return }

        do {
            guard let newName = RenameValidation.normalize(name) else { throw RenameFailure.invalid }
            let oldURL = URL(fileURLWithPath: oldPath)
            // Same folder + new name — never trust the typed string to carry its own directory.
            let newURL = oldURL.deletingLastPathComponent().appendingPathComponent(newName)
            if newURL.lastPathComponent == oldURL.lastPathComponent { dismiss(); return }  // unchanged → no-op

            let fm = FileManager.default
            // Refuse to clobber a *different* existing file. A case-only rename on a case-insensitive
            // volume (foo.md → Foo.md) resolves to the same file, so allow it (compare resolved paths).
            if fm.fileExists(atPath: newURL.path) {
                let sameFile = (try? oldURL.resourceValues(forKeys: [.canonicalPathKey]).canonicalPath)
                    == (try? newURL.resourceValues(forKeys: [.canonicalPathKey]).canonicalPath)
                if !sameFile { throw RenameFailure.exists }
            }

            try fm.moveItem(at: oldURL, to: newURL)
            // The file's CONTENT is unchanged, so the saved baseline still matches — only the path moves.
            // setPath updates vm.filePath (+ displayName) WITHOUT touching the dirty baseline (a clean doc
            // stays clean after a rename); bumping revision re-renders the chrome's filename.
            doc.vm.setPath(newURL.path)
            doc.revision &+= 1
            RecentFiles.add(newURL.path)   // also drops the now-stale old path (filtered: missing on disk)
            dismiss()
        } catch {
            present(error)
        }
    }

    /// Surface a failure: a short inline message in the sheet + a modal NSAlert on the window (matching
    /// the AppKit version's alert), reusing the existing `rename.error.*` / `common.ok` locale keys.
    private func present(_ error: Error) {
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
        errorText = alert.informativeText   // also keep it visible in-sheet so the field stays editable
        alert.present(anchoredTo: doc.hostWindow)   // sheet on the editor window when present, else app-modal
    }
}
