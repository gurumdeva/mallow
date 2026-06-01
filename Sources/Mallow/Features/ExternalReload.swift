// ExternalReload — re-sync a window with its file on disk when the window regains focus (the SwiftUI
// re-port of the AppKit ExternalReload, itself the native analogue of the Tauri FileService
// .syncFromDiskIfChanged + decideSyncAction). Instead of an fs watcher we use window-focus as the
// trigger: when you switch away to edit the file in another app (or git pulls it) and come back, we
// re-read the file and reconcile. Re-homed from EditorController onto EditorDocument, which owns the
// text view + view-model in the SwiftUI build.
//
// Decision (matches the reference's pure decideSyncAction, comparing actual content — never a debounced
// flag): the saved/loaded text in `vm.baseline` is the last content we did I/O on, so it is the
// external-change baseline.
//   • disk == current                          → noop      (no external change vs the buffer)
//   • disk != current && editor == baseline    → silent    (no local edits → reload, no data loss)
//   • disk != current && editor != baseline    → prompt    (conflict → ask before discarding)
// "editor == baseline" is the engine's content equality (inkstone_is_dirty, via vm.isDirty) — the same
// primitive the chrome's dirty dot uses — so a markdown-equivalent re-save from another app reads as no
// local edits. "disk == current" is a literal byte compare against the live buffer (textView.string),
// matching the task: identical bytes on disk are a no-op even if the buffer is dirty against baseline.
//
// Wiring: WindowActiveTracker already owns this window's NSWindow.didBecomeKeyNotification observer (it
// marks the window's doc active for the menu commands); the integrator adds a
// `doc.reloadFromDiskIfChanged()` call in that same handler. This file is
// otherwise self-contained: the re-entrancy guard (so the focus that returns when the modal alert
// closes doesn't re-enter and stack a second alert) lives here, since extensions can't add stored
// properties.

import AppKit

extension EditorDocument {
    /// What to do after comparing the live buffer, the last-I/O baseline, and the current disk content.
    /// Pure (mirrors the reference's `decideSyncAction`); `editorMatchesBaseline` is the engine's
    /// content equality so a markdown-equivalent external re-save reads as "no local edits".
    private enum SyncDecision { case noop, silent, prompt }

    /// The pure reconcile rule. `diskMatchesCurrent`: disk bytes == the live buffer. `editorMatchesBaseline`:
    /// the buffer is engine-clean vs the last content we did I/O on (no unsaved local edits).
    private static func decideSync(diskMatchesCurrent: Bool,
                                   editorMatchesBaseline: Bool) -> SyncDecision {
        if diskMatchesCurrent { return .noop }      // buffer already equals disk → nothing to do
        if editorMatchesBaseline { return .silent } // external change, no local edits → safe reload
        return .prompt                              // external change + local edits → confirm
    }

    /// Documents currently inside a sync (re-entrancy guard). While the conflict alert is up its nested
    /// modal loop can re-deliver key focus to this window; without this we'd re-enter and stack a second
    /// alert. Keyed by the document's identity so it's per-window and needs no stored property.
    private static var syncing = Set<ObjectIdentifier>()

    /// Re-read the file and reconcile the editor with disk; safe to call on every key event. No-op when
    /// there's no file path, the file can't be read, or the buffer already equals disk. Silently reloads
    /// when there are no local edits; otherwise prompts before discarding local edits.
    func reloadFromDiskIfChanged() {
        let id = ObjectIdentifier(self)
        guard !Self.syncing.contains(id) else { return }   // already reconciling this window
        guard let path = vm.filePath else { return }        // unsaved document — nothing to compare

        // Read the file fresh. If it was deleted/moved/temporarily unreadable, keep the editor as-is and
        // stay silent (we'll retry on the next focus; saving recreates it) — like the reference.
        guard let disk = try? String(contentsOfFile: path, encoding: .utf8) else { return }

        // Compare disk against the LIVE buffer (literal bytes) and against the saved baseline (engine
        // equality, via vm.isDirty — the same primitive the dirty dot uses).
        let diskMatchesCurrent = (disk == textView.string)
        let editorMatchesBaseline = !vm.isDirty

        switch Self.decideSync(diskMatchesCurrent: diskMatchesCurrent,
                               editorMatchesBaseline: editorMatchesBaseline) {
        case .noop:
            return

        case .silent:
            // No local edits, so adopting disk loses nothing. Replace the buffer and re-baseline.
            applyReload(disk, path: path)

        case .prompt:
            // Local edits AND an external change — one side must lose, so ask first. The guard keeps the
            // focus that returns when this modal closes from re-entering and stacking a second alert.
            Self.syncing.insert(id)
            defer { Self.syncing.remove(id) }
            hostWindow?.makeKeyAndOrderFront(nil)   // surface WHICH document is prompting
            let alert = NSAlert()
            alert.messageText = L.t("reload.title")
            alert.informativeText = L.t("reload.body", ["name": vm.displayName])
            alert.addButton(withTitle: L.t("reload.confirm"))    // first button → reload (accept disk)
            alert.addButton(withTitle: L.t("reload.keepMine"))   // second button → keep local edits
            if alert.runModal() == .alertFirstButtonReturn {
                applyReload(disk, path: path)   // accept the disk version
            } else {
                // Kept local edits: record that we've seen this disk version so the same content won't
                // re-prompt on every focus. markSaved re-baselines to disk; the buffer still differs from
                // it, so the document stays correctly dirty (and the dot stays lit).
                vm.markSaved(path: path, content: disk)
                revision &+= 1
            }
        }
    }

    /// Load `disk` into the editor as the new clean baseline, then re-run the pipeline and refresh the
    /// chrome. Mirrors the reference reload: replace text + re-baseline + refresh; the buffer changes
    /// only by adopting the file's own bytes, never a silent rewrite.
    ///
    /// The replace goes through the text view's edit path (shouldChangeText → replaceCharacters →
    /// didChangeText) — NOT `textView.string = …` — so the reload is a single undoable step and the
    /// existing undo stack is preserved (the same undoable seam EditorViewModel.replace(with:) uses for
    /// engine commands; DocumentActions warns that `string =` registers no undo and wipes the stack).
    /// The caret is clamped to the new length first, since the old offset may now be out of range.
    private func applyReload(_ disk: String, path: String) {
        let full = NSRange(location: 0, length: (textView.string as NSString).length)
        textView.replaceCharactersUndoably(in: full, with: disk)
        let len = (disk as NSString).length
        let caret = min(textView.selectedRange().location, len)
        textView.setSelectedRange(NSRange(location: caret, length: 0))
        vm.markSaved(path: path, content: disk)   // disk is now the clean baseline (not dirty)
        vm.refresh()                              // re-parse, restyle, recompute hidden glyphs, focus
        revision &+= 1                            // chrome re-renders title / dirty dot
    }
}
