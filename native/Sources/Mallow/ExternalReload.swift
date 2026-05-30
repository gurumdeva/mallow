// ExternalReload — re-sync a window with its file on disk when the window regains focus (the native
// analogue of the Tauri FileService.syncFromDiskIfChanged + decideSyncAction). Instead of an fs
// watcher we use window-focus as the trigger: when you switch away to edit the file in another app
// (or git pulls it) and come back, we re-read the file and reconcile.
//
// Decision (matches the reference's pure decideSyncAction, comparing actual content — never a
// debounced flag): the saved/loaded text in `vm.baseline` is the last content we did I/O on, so it
// is the external-change baseline.
//   • disk == baseline                          → noop      (no external change)
//   • disk != baseline && editor == baseline    → silent    (no local edits → reload, no data loss)
//   • disk != baseline && editor != baseline    → prompt    (conflict → ask before discarding)
// "editor == baseline" is the engine's content equality (inkstone_is_dirty), the same primitive the
// chrome's dirty dot uses — so a markdown-equivalent re-save from another app counts as no change.
//
// Wiring: EditorController is already the window's delegate; the integrator adds NSWindowDelegate's
// windowDidBecomeKey to call reloadFromDiskIfChanged() (see sharedChanges). This file is otherwise
// self-contained: the re-entrancy guard (so the focus that returns when the modal alert closes
// doesn't re-enter) lives here, since extensions can't add stored properties.

import AppKit

extension EditorController {
    /// What to do after comparing the editor, the last-I/O baseline, and the current disk content.
    /// Pure (mirrors the reference's `decideSyncAction`); `editorMatchesBaseline` is the engine's
    /// content equality so a markdown-equivalent external re-save reads as "no local edits".
    private enum SyncDecision { case noop, silent, prompt }
    private static func decideSync(diskMatchesBaseline: Bool,
                                   editorMatchesBaseline: Bool) -> SyncDecision {
        if diskMatchesBaseline { return .noop }     // no external change
        if editorMatchesBaseline { return .silent } // external change, no local edits → safe reload
        return .prompt                              // external change + local edits → confirm
    }

    /// Controllers currently inside a sync (re-entrancy guard). While the conflict alert is up its
    /// nested modal loop can re-deliver focus to this window; without this we'd re-enter and stack
    /// a second alert. Keyed by identity so it's per-window and needs no stored property.
    private static var syncing = Set<ObjectIdentifier>()

    /// Called when the window regains key focus. Re-reads the file and reconciles the editor with
    /// disk; no-op when there's no file path or no external change.
    @objc func reloadFromDiskIfChanged() {
        let id = ObjectIdentifier(self)
        guard !Self.syncing.contains(id) else { return }   // already reconciling this window
        guard let path = vm.filePath else { return }        // unsaved document — nothing to compare

        // Read the file fresh. If it was deleted/moved/temporarily unreadable, keep the editor as-is
        // and stay silent (we'll retry on the next focus; saving recreates it) — like the reference.
        guard let disk = try? String(contentsOfFile: path, encoding: .utf8) else { return }

        let baseline = vm.baseline
        // Compare against the last content we did I/O on. baseline is the engine-normalized truth the
        // dirty dot uses; go through the Engine seam (inkIsDirty → inkstone_is_dirty) so disk-vs-
        // baseline equality means the same thing the chrome's dirty dot does, with no raw-FFI here.
        let diskMatchesBaseline = !inkIsDirty(disk, baseline)
        let editorMatchesBaseline = !vm.isDirty

        switch Self.decideSync(diskMatchesBaseline: diskMatchesBaseline,
                               editorMatchesBaseline: editorMatchesBaseline) {
        case .noop:
            return

        case .silent:
            // No local edits, so adopting disk loses nothing. Replace the buffer and re-baseline.
            applyReload(disk, path: path)

        case .prompt:
            // Local edits AND an external change — one side must lose, so ask first. The guard keeps
            // the focus that returns when this modal closes from re-entering.
            Self.syncing.insert(id)
            defer { Self.syncing.remove(id) }
            window?.makeKeyAndOrderFront(nil)   // surface WHICH document is prompting
            let alert = NSAlert()
            alert.messageText = "This file changed on disk. Reload?"
            alert.informativeText =
                "\(vm.displayName) was changed by another app. Reloading discards your unsaved edits."
            alert.addButton(withTitle: "Reload")
            alert.addButton(withTitle: "Keep Mine")
            if alert.runModal() == .alertFirstButtonReturn {
                applyReload(disk, path: path)   // accept the disk version
            } else {
                // Kept local edits: record that we've seen this disk version so the same content
                // won't re-prompt on every focus. markSaved re-baselines to disk; the editor still
                // differs from it, so the document stays correctly dirty.
                vm.markSaved(path: path, content: disk)
                updateChrome()
            }
        }
    }

    /// Load `disk` into the editor as the new clean baseline, then re-run the live-style pipeline and
    /// refresh the chrome. Selection is clamped to the new length (the old caret may be out of range).
    /// Mirrors the reference reload: replace text + re-baseline + refresh; the buffer changes only by
    /// adopting the file's own bytes, never a silent rewrite.
    private func applyReload(_ disk: String, path: String) {
        textView.string = disk
        let len = (disk as NSString).length
        let caret = min(textView.selectedRange().location, len)
        textView.setSelectedRange(NSRange(location: caret, length: 0))
        vm.markSaved(path: path, content: disk)   // disk is now the clean baseline (not dirty)
        vm.refresh()                              // re-parse, restyle, recompute hidden glyphs, focus
        updateChrome()
    }
}
