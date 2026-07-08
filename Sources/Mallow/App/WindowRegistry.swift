// WindowRegistry — the app-level registry of open editor documents, and the three data-safety guards
// that ride on top of it. The Tauri app this mirrors enforced single-writer-per-file in the Rust core
// (path_open_in_other_window / focus_or_claim_window_for_path / dirty_window_count); SwiftUI's
// WindowGroup gives us no such cross-window awareness (each window is an island that autosaves its own
// buffer), so we reconstruct it here. The registry closes three concrete data-loss / duplication gaps:
//
//   (a) two windows editing — and saving over — the SAME file, silently clobbering each other;
//   (b) re-opening an already-open file as a second, divergent window;
//   (c) ⌘Q tearing the app down while some window still has unsaved edits, with no prompt.
//
// Design notes:
//   • Weak references. The registry must never keep a closed window's document (and thus its NSTextView /
//     NSWindow) alive. Entries hold the document weakly; any method that walks the table first compacts
//     out the entries whose document has deallocated. Identity is the document's ObjectIdentifier.
//   • Canonical paths. De-duplication keys off the file's *canonical* path (symlinks resolved, `.`/`..`
//     and a trailing slash normalized), so `/tmp/a.md`, `/private/tmp/a.md`, and `./a.md` from the same
//     cwd all collapse to one identity. A document with no `vm.filePath` (an unsaved buffer) never
//     matches — two blank windows are legitimately distinct.
//   • Main-thread affinity. Documents, text views, and windows are all main-thread/AppKit objects, and
//     every caller (window lifecycle, menu commands, save/open) is already on the main thread, so the
//     registry takes no lock; it is a plain main-thread singleton like AppState.shared.
//
// This file is self-contained: the registry, the canonical-path helper, and the three free guard
// functions all live here.

import AppKit
import os

// MARK: - Registry

/// A registry of the currently-open editor documents (one per window). Singleton, main-thread-only.
/// Entries are weak, so a window that closes drops out automatically (its document deallocs when the
/// SwiftUI `@State` holding it goes away); walking methods compact dead entries lazily before they read.
final class WindowRegistry {
    static let shared = WindowRegistry()
    private init() {}

    /// One open document. The document is held weakly (the registry must not extend a closed window's
    /// lifetime); `key` is its stable identity so `unregister` and de-dup work even after `doc` is gone.
    private struct Entry {
        weak var doc: EditorDocument?
        let key: ObjectIdentifier
    }

    /// The open documents, in registration order. Order is preserved only so iteration is deterministic
    /// (e.g. the quit prompt counts them stably); nothing depends on it semantically.
    private var entries: [Entry] = []

    // MARK: registration (called on window open / close)

    /// Log channel for registry invariant violations (a collision is a bug in the open/save conventions,
    /// not a user error — so it's logged, not surfaced).
    private static let log = Logger(subsystem: "com.gurumdeva.mallow", category: "WindowRegistry")

    /// Record a newly-opened window's document. Idempotent: registering the same document twice (e.g. a
    /// re-entrant `.onAppear`) does not create a duplicate entry.
    ///
    /// COLLISION DETECTION (single-writer-per-file): the open / Save call sites are supposed to focus the
    /// existing window rather than open a second one on the same on-disk file (canonical path). If one
    /// slips through, a second document lands here for a path another LIVE window already holds — two
    /// autosaving writers over one file, the exact data-loss this registry exists to prevent. `register`
    /// now DETECTS that (previously it deduped by object identity only) and returns `true`. It still
    /// appends the entry: an untracked dirty window is invisible to the ⌘Q guard (silent loss), which is
    /// worse than the collision. The verdict lets callers/tests assert the invariant; here we log it.
    @discardableResult
    func register(_ doc: EditorDocument) -> Bool {
        let key = ObjectIdentifier(doc)
        compact()
        guard !entries.contains(where: { $0.key == key }) else { return false }  // re-register → not a collision
        let collided = otherDocument(sharingFileWith: doc) != nil
        if collided {
            Self.log.error("two windows now editing the same file: \(doc.vm.filePath ?? "?", privacy: .public)")
        }
        entries.append(Entry(doc: doc, key: key))
        return collided
    }

    /// Drop a closing window's document from the registry. Safe to call for a document that was never
    /// registered (no-op) or whose entry has already been compacted away.
    func unregister(_ doc: EditorDocument) {
        let key = ObjectIdentifier(doc)
        entries.removeAll { $0.key == key }
    }

    // MARK: queries

    /// All currently-open documents (live entries only), in registration order.
    func documents() -> [EditorDocument] {
        compact()
        return entries.compactMap(\.doc)
    }

    /// The OTHER open document whose file is the same on disk as `path`, comparing canonical paths so
    /// symlinks / `.`/`..` / relative spellings dedupe. `excluding` is skipped by identity so a window
    /// never matches itself (pass the document doing the open/save). Returns nil if no other window holds
    /// that file. When (pathologically) several do, the first in registration order wins.
    func document(forPath path: String, excluding excluded: EditorDocument? = nil) -> EditorDocument? {
        guard let wanted = WindowRegistry.canonicalPath(path) else { return nil }
        let excludedKey = excluded.map(ObjectIdentifier.init)
        compact()
        for entry in entries {
            guard let doc = entry.doc else { continue }
            if entry.key == excludedKey { continue }
            guard let docPath = doc.vm.filePath,
                  let docCanonical = WindowRegistry.canonicalPath(docPath) else { continue }
            if docCanonical == wanted { return doc }
        }
        return nil
    }

    /// Convenience over `document(forPath:excluding:)` keyed off a document's own current file. Returns
    /// the *other* window already editing this document's file (nil for an unsaved doc, or none open).
    func otherDocument(sharingFileWith doc: EditorDocument) -> EditorDocument? {
        guard let path = doc.vm.filePath else { return nil }
        return document(forPath: path, excluding: doc)
    }

    /// The open documents with unsaved changes (`vm.isDirty`). Used by the ⌘Q guard to decide whether to
    /// prompt and to count how many windows are at risk.
    func dirtyDocuments() -> [EditorDocument] {
        documents().filter { $0.vm.isDirty }
    }

    // MARK: focus

    /// Bring `doc`'s window to the front and make it key (so "open" can focus an already-open file
    /// instead of duplicating it). No-op if the window isn't materialized yet. Also un-minimizes a
    /// miniaturized window so a focus request can't silently land in the Dock.
    func focusWindow(of doc: EditorDocument) {
        guard let window = doc.textView.window else { return }
        if window.isMiniaturized { window.deminiaturize(nil) }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    // MARK: internals

    /// Remove entries whose document has deallocated. Called before any read so the registry never hands
    /// back a stale entry and never grows unboundedly as windows come and go.
    private func compact() {
        entries.removeAll { $0.doc == nil }
    }

    /// Canonicalize a filesystem path for identity comparison: expand `~`, resolve symlinks, and
    /// standardize `.`/`..`/redundant-slash spellings, returning the absolute canonical path. Returns nil
    /// only for an empty string. This does NOT require the file to exist (a Save-As target may be new), so
    /// it leans on URL standardization rather than `realpath`, then resolves symlinks on whatever prefix
    /// does exist. The result is what two paths are compared by to decide they name the same file.
    static func canonicalPath(_ path: String) -> String? {
        guard !path.isEmpty else { return nil }
        let expanded = (path as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: expanded)
        // If the file EXISTS, prefer the filesystem's OWN canonical path — it case-normalizes on a
        // case-insensitive volume (default APFS), so `Note.md` and `note.md` resolve to ONE key. Without
        // this they canonicalize differently, so two windows open on the same on-disk file and silently
        // clobber each other's autosave — exactly the single-writer guarantee this registry exists for.
        // (RenameSheet's same-file check already uses this key.)
        if let canonical = (try? url.resourceValues(forKeys: [.canonicalPathKey]))?.canonicalPath {
            return canonical
        }
        // `resolvingSymlinksInPath` also standardizes the path and makes it absolute; for a path whose
        // leaf doesn't exist yet it resolves the existing prefix and leaves the rest standardized — exactly
        // what we want so an about-to-be-created Save-As target still dedupes against an open window.
        return url.resolvingSymlinksInPath().standardizedFileURL.path
    }
}

// MARK: - Guard 1: ⌘Q with unsaved changes

/// Decide whether the app may quit, given the currently-open windows. If one or more windows have unsaved
/// changes, present a single modal alert naming the count and return the user's choice; otherwise allow
/// the quit. Call this from `MallowAppDelegate.applicationShouldTerminate(_:)` and map the Bool to a
/// `NSApplication.TerminateReply`.
///
/// Returns `true` to proceed with termination, `false` to cancel it. With no dirty windows it returns
/// `true` immediately (no alert) — the per-window close-confirm in WindowConfigurator already covers the
/// close-one-window case; this guard exists for the quit-everything-at-once case the per-window delegate
/// never sees.
///
/// Main-thread-only by contract, like everything else here (the codebase uses no actor isolation; main-
/// thread affinity is enforced by convention / `DispatchQueue.main`). Every call site — the delegate's
/// termination hook, DocumentActions, the menu-command closures — already runs on main.
func confirmQuitIfDirty() -> Bool {
    let dirty = WindowRegistry.shared.dirtyDocuments()
    guard !dirty.isEmpty else { return true }   // nothing unsaved → quit freely

    // The title names the count so the user knows the blast radius. Quit Anyway is the destructive default
    // (⏎); Cancel is the Esc action — same button ordering as WindowConfigurator.confirmDiscard. Now fully
    // localized (en/ko/ja) — previously the title/body/confirm were literal English while only Cancel was
    // localized, giving a ko/ja user a mixed-language dialog.
    let title = dirty.count == 1
        ? L.t("dialog.quit.titleOne")
        : L.t("dialog.quit.titleMany", ["count": "\(dirty.count)"])
    return NSAlert.confirmDestructive(title: title,
                                      body: L.t("dialog.quit.body"),
                                      confirm: L.t("dialog.quit.confirm"),
                                      cancel: L.t("dialog.discard.cancel"))
}

// MARK: - Guards 2 & 3: opening / saving onto a file already open elsewhere

/// True iff some *other* open window already edits the file at `path` (canonical-path compared). The lead
/// consults this in two places:
///
///   • Save / Save-As (`DocumentActions.write` / `saveAs`): block writing onto a file another window
///     owns, so two windows can't autosave over each other (gap a). Pass the saving document as
///     `excluding` so saving back to your own file is always allowed.
///   • Open / Open-Recent: prefer focusing the existing window over opening a duplicate (gap b). There,
///     resolve the actual document with `WindowRegistry.shared.document(forPath:)` and call
///     `focusWindow(of:)` — this Bool is the cheap "is it already open?" predicate.
func pathOpenInOtherWindow(_ path: String, excluding doc: EditorDocument? = nil) -> Bool {
    WindowRegistry.shared.document(forPath: path, excluding: doc) != nil
}

/// Present a modal alert explaining that `path` is already open in another window, so a Save / Save-As
/// onto it was blocked. Returns nothing — it is purely informational (the only safe action is to not
/// overwrite). The lead calls this from the Save path right after `pathOpenInOtherWindow` returns true,
/// then aborts the write. Title/body are literal English (no matching locale key); it offers a single
/// dismiss button and, as a courtesy, brings the conflicting window forward so the user can find it.
func presentPathInUseAlert(path: String, anchor: NSWindow? = nil) {
    // Surface the window that owns the file so "it's open elsewhere" is actionable, not abstract.
    if let other = WindowRegistry.shared.document(forPath: path) {
        WindowRegistry.shared.focusWindow(of: other)
    }
    let alert = NSAlert()
    alert.alertStyle = .warning
    alert.messageText = L.t("conflict.inUse.title", ["name": (path as NSString).lastPathComponent])
    alert.informativeText = L.t("conflict.inUse.body")
    alert.addButton(withTitle: L.t("common.ok"))
    alert.present(anchoredTo: anchor)   // non-blocking sheet when we have a window to hang it on, else app-modal
}
