// Autosave — debounced background save for documents that already have a file path. Once a document
// is backed by a file, edits are flushed to disk shortly after typing stops, so work isn't lost to a
// crash or an forgotten ⌘S. Untitled documents are deliberately excluded: autosaving one would have
// to pop a Save panel, and Mallow never surprises the user with a dialog they didn't ask for.
//
// Mirrors the Tauri reference (src/main.ts "자동 저장"): on every text change, cancel the pending
// timer and, if the document is dirty AND has a path, schedule a save 1.5s out. The save reuses the
// controller's own write(to:) path (via saveDocument), so the saved baseline, the ● dirty dot, and
// the recent-files list all stay correct — autosave is just a timed ⌘S, not a second write path.

import AppKit

extension EditorController {
    /// Idle delay before an edited, file-backed document is flushed to disk. Matches the reference's
    /// 1500ms: long enough to coalesce a burst of keystrokes into one write, short enough to feel safe.
    private static let autosaveDelay: TimeInterval = 1.5

    /// Debounce a background save. Called from `textDidChange` (see sharedChanges). Each keystroke
    /// resets the countdown; only after editing pauses for `autosaveDelay` does the write fire — and
    /// only for a dirty, file-backed document (never an untitled one, which would need a Save panel).
    func scheduleAutosave() {
        // Always cancel the in-flight timer first: a fresh edit means the previous countdown is stale.
        autosaveTimer?.invalidate()
        autosaveTimer = nil

        // Untitled docs are never autosaved (no surprise dialog); a clean doc has nothing to write.
        guard vm.filePath != nil, vm.isDirty else { return }

        // Block-based timer with a weak self: if the window closes mid-countdown the controller can
        // still deallocate, and a fire that races a teardown simply finds nil and no-ops.
        autosaveTimer = Timer.scheduledTimer(withTimeInterval: Self.autosaveDelay,
                                             repeats: false) { [weak self] _ in
            self?.performAutosave()
        }
    }

    /// The deferred write. Re-checks the guards (state may have changed during the idle window — e.g.
    /// the user hit ⌘S, or an Undo restored the saved text) and routes through the normal save so the
    /// baseline/recents/chrome bookkeeping is identical to a manual save. saveDocument writes directly
    /// (no panel) because filePath is non-nil; passing nil as the sender is fine (it's unused there).
    private func performAutosave() {
        autosaveTimer = nil
        guard vm.filePath != nil, vm.isDirty else { return }
        saveDocument(nil)
    }

    /// Stop any pending autosave (e.g. on window close, so a queued write can't fire after teardown).
    /// Safe to call repeatedly; harmless if no timer is scheduled.
    func cancelAutosave() {
        autosaveTimer?.invalidate()
        autosaveTimer = nil
    }
}
