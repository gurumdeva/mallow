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
// functions all live here. Call sites are listed in the INTEGRATION NOTES at the bottom — per the task,
// no existing file is edited; the lead wires these in by hand.

import AppKit

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

    /// Record a newly-opened window's document. Idempotent: registering the same document twice (e.g. a
    /// re-entrant `.onAppear`) does not create a duplicate entry.
    func register(_ doc: EditorDocument) {
        let key = ObjectIdentifier(doc)
        compact()
        guard !entries.contains(where: { $0.key == key }) else { return }
        entries.append(Entry(doc: doc, key: key))
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
/// reply (see INTEGRATION NOTES).
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

    let alert = NSAlert()
    alert.alertStyle = .warning
    // No dedicated quit-with-N-dirty key exists in the locale tables (only the single-document
    // `dialog.discard.*`), so the quit-specific title/body are literal English per the task; the body
    // names the count so the user knows the blast radius.
    alert.messageText = dirty.count == 1
        ? "You have 1 document with unsaved changes."
        : "You have \(dirty.count) documents with unsaved changes."
    alert.informativeText = "If you quit now, those changes will be lost."

    // Quit Anyway is first → it's the default (⏎) and gets destructive styling; Cancel is the Esc action
    // so a stray ⌘Q that hits ⏎ still quits intentionally, while Esc keeps the app alive. Mirrors the
    // button ordering of WindowConfigurator.confirmDiscard.
    let quit = alert.addButton(withTitle: "Quit Anyway")     // .alertFirstButtonReturn
    quit.hasDestructiveAction = true
    let cancel = alert.addButton(withTitle: L.t("dialog.discard.cancel"))   // localized "Cancel"
    cancel.keyEquivalent = "\u{1b}"   // Esc → Cancel (don't quit)

    return alert.runModal() == .alertFirstButtonReturn
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
    alert.messageText = "“\((path as NSString).lastPathComponent)” is open in another window."
    alert.informativeText = "Save there, or close that window first, to avoid overwriting "
        + "each other's changes."
    alert.addButton(withTitle: L.t("common.ok"))
    if let anchor {
        alert.beginSheetModal(for: anchor)   // non-blocking sheet when we have a window to hang it on
    } else {
        alert.runModal()
    }
}

// =============================================================================================
// INTEGRATION NOTES (no existing file was edited per the task; the lead applies these by hand):
// =============================================================================================
//
// All five entry points are one-liners against the existing seams. Everything below runs on the main
// thread already (window lifecycle, menu commands, DocumentActions) — the same main-thread-by-convention
// model the rest of the app uses (no actor isolation anywhere in the codebase).
//
// ── 1) register / unregister — tie registry membership to window lifetime ──────────────────────────
//
//   Preferred (deterministic with SwiftUI's @State document): EditorWindow.body in MallowApp.swift,
//   alongside the existing `.background(WindowActiveTracker)` / `.background(WindowConfigurator)`:
//
//       .onAppear    { WindowRegistry.shared.register(doc) }
//       .onDisappear { WindowRegistry.shared.unregister(doc) }
//
//   (`doc` is the `@State private var doc` already in EditorWindow.) `.onAppear` fires once the window's
//   view is up; `.onDisappear` fires when the window closes. register() is idempotent, so even if a
//   future SwiftUI quirk re-fires onAppear it won't double-insert. Weak entries make unregister a
//   belt-and-suspenders step — a closed window's doc would compact out on its own — but calling it keeps
//   the table tight and the dirty-count exact the instant a window closes.
//
//   Alternative (if you'd rather key off the NSWindow): register inside WindowConfigurator.Coordinator
//   .attach(to:) and unregister in its `deinit`. EditorWindow.onAppear/onDisappear is simpler and is the
//   recommended spot; pick one, not both.
//
// ── 2) ⌘Q guard — MallowAppDelegate.applicationShouldTerminate ─────────────────────────────────────
//
//   Add this method to MallowAppDelegate (AppLifecycle.swift). It is NOT currently implemented (the
//   delegate only has applicationShouldTerminateAfterLastWindowClosed), so there's no conflict:
//
//       func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
//           confirmQuitIfDirty() ? .terminateNow : .terminateCancel
//       }
//
//   `.terminateNow` proceeds with the quit; `.terminateCancel` aborts it and keeps the app running. This
//   fires for ⌘Q / Quit menu / logout-initiated termination — the cases the per-window windowShouldClose
//   never sees. (Leave applicationShouldTerminateAfterLastWindowClosed as-is.)
//
// ── 3) Save / Save-As guard — DocumentActions.write(to:) / saveAs() ────────────────────────────────
//
//   In `write(to:)`, before the `content.write(...)`, refuse to overwrite a file another window owns:
//
//       if pathOpenInOtherWindow(url.path, excluding: self) {
//           presentPathInUseAlert(path: url.path, anchor: textView.window)
//           return
//       }
//
//   `excluding: self` makes a normal Save back to your own file always allowed (you are not "another"
//   window). This guards BOTH Save (existing path) and Save-As (panel-chosen path), since both funnel
//   through `write(to:)`. If you prefer to guard only the explicit-target cases, put the same check at
//   the top of `saveAs()` right after the panel returns a `url` instead — but `write(to:)` is the single
//   chokepoint and is the recommended spot.
//
// ── 4) Open / Open-Recent — focus an existing window instead of duplicating ─────────────────────────
//
//   (a) MallowCommands.openFile() (the NSOpenPanel path): after the panel yields `url`, prefer focus:
//
//       if let existing = WindowRegistry.shared.document(forPath: url.path) {
//           WindowRegistry.shared.focusWindow(of: existing)
//       } else {
//           openWindow(value: OpenSpec.file(path: url.path))
//       }
//
//   (b) MallowCommands Open-Recent buttons (the ForEach over RecentFiles.list()): same pattern around
//       the existing `openWindow(value: OpenSpec.file(path: path))`:
//
//       Button((path as NSString).lastPathComponent) {
//           if let existing = WindowRegistry.shared.document(forPath: path) {
//               WindowRegistry.shared.focusWindow(of: existing)
//           } else {
//               openWindow(value: OpenSpec.file(path: path))
//           }
//       }
//
//   (c) MallowApp.swift, the `.mallowOpenFile` receiver (Finder "open with" / `open -a` / dock drop):
//       inside the `.onReceive`, focus-existing before opening. It already gates on `claimFileOpen(path)`
//       (the per-runloop OS-event de-dupe); add the registry check after that:
//
//           .onReceive(NotificationCenter.default.publisher(for: .mallowOpenFile)) { note in
//               guard let path = note.userInfo?["path"] as? String, claimFileOpen(path) else { return }
//               if let existing = WindowRegistry.shared.document(forPath: path) {
//                   WindowRegistry.shared.focusWindow(of: existing)
//               } else {
//                   openWindow(value: OpenSpec.file(path: path))
//               }
//           }
//
//   Why both `claimFileOpen` and the registry check stay: claimFileOpen de-dupes the *same OS event*
//   fanning out to every mounted receiver within ~1s (a transient race); the registry check is the
//   durable "this file is already open in a live window" decision. They solve different problems — keep
//   both. (A small optional polish: factor the three-line focus-or-open into one helper, e.g.
//   `openOrFocus(path:openWindow:)`, and call it from all three sites; not required.)
//
// ── Canonicalization note ──────────────────────────────────────────────────────────────────────────
//
//   All comparisons go through WindowRegistry.canonicalPath (symlinks resolved + standardized), so
//   `/tmp/x.md` vs `/private/tmp/x.md`, a `~`-relative path, and a `./x.md` all dedupe to one identity.
//   It does not require the target to exist, so a brand-new Save-As path still compares correctly against
//   any window that already holds that (about-to-exist) file.
// =============================================================================================
