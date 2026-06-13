// LaunchOpen — resolves the macOS "extra window when launched with a document" problem for Mallow's
// value-based WindowGroup. On a cold launch SwiftUI auto-creates ONE window from the `nil` OpenSpec, whose
// content `OpenSpec.make(for:)` resolves to the restored last file (or the welcome demo). A file handed to
// the app at launch (Finder "Open With" / `open -a` / dock drop) arrives a few milliseconds LATER via
// `MallowAppDelegate.application(_:open:)` → `.mallowOpenFile`, which opens a SECOND window — leaving the
// user with the restored-last-file window PLUS the opened-file window (two windows; identical titles when
// the last file IS the opened file).
//
// We can't pick the initial window's content for the file at make-time: tracing the launch shows the open
// event is delivered AFTER SwiftUI has already evaluated the scene and restored the last file. So instead,
// when a file-open arrives DURING the launch phase and lands on the spurious, still-clean initial window,
// we open the file in its own window and CLOSE that initial window — sequenced so the file window has
// registered first, so we never drop to zero windows and trip terminate-after-last-window-closed. Once the
// launch phase ends, opens behave normally (a new window per file, matching File ▸ Open).
//
// Identity note: SwiftUI keeps ONE `@State` EditorDocument per window even across the mount/unmount churn
// it does while adding the file window, so the initial window's *document identity* is stable. The launch
// decision keys off that (and the receiving window's own document), NOT the WindowRegistry — the registry
// is transiently empty mid-launch (the initial window briefly unregisters during the churn).

import AppKit

/// What the `.mallowOpenFile` handler on a given window should do with an open request. Pure value so the
/// decision is unit-testable apart from its side effects.
enum LaunchOpenAction: Equatable {
    /// The receiving window already shows this exact file → just focus it (open nothing).
    case focusThisWindow
    /// Open the file in a new window (or focus an existing one) — normal running-app behavior.
    case openNewWindow
    /// Open the file in a new window AND close the receiving window: it is the spurious auto-created
    /// restore/welcome window that this launch's file-open supersedes.
    case openAndSupersede
}

enum LaunchOpen {
    /// True only during the cold-launch phase. A file handed to the app while this is true supersedes the
    /// auto-created restore/welcome window; once it flips false (a beat after launch — see
    /// `MallowAppDelegate.applicationDidFinishLaunching`), opens create their own windows as usual.
    private(set) static var isLaunching = true

    /// The auto-created initial (restore/welcome) window's document, tagged at its first appearance during
    /// launch. Weak — the registry/coordinator must never keep a closed window's document alive.
    weak static var initialDoc: EditorDocument?

    /// A superseded initial window queued to close once the file window has registered (so ≥2 windows
    /// exist at close time). Weak for the same reason.
    weak static var docPendingClose: EditorDocument?

    /// Tag the initial window — called from its `.onAppear` when its OpenSpec was `nil`. First tag wins
    /// (SwiftUI may re-mount it; the document identity is stable, so re-tags are harmless no-ops).
    static func tagInitialWindow(_ doc: EditorDocument) {
        guard isLaunching, initialDoc == nil else { return }
        initialDoc = doc
    }

    /// PURE decision for the `.mallowOpenFile` handler. Kept free of side effects so it's unit-testable.
    /// `receivingWindowIsInitial` is whether the window receiving the notification is the tagged initial
    /// window; `isLaunching` is the phase flag. Same-file is compared by canonical path so symlink/`.`/`..`
    /// spellings collapse (the registry's own dedup key).
    static func decide(openPath: String,
                       receivingWindowPath: String?,
                       receivingWindowIsDirty: Bool,
                       receivingWindowIsInitial: Bool,
                       isLaunching: Bool) -> LaunchOpenAction {
        if let p = receivingWindowPath,
           let a = WindowRegistry.canonicalPath(p),
           let b = WindowRegistry.canonicalPath(openPath), a == b {
            return .focusThisWindow                       // already showing this exact file
        }
        if isLaunching, receivingWindowIsInitial, !receivingWindowIsDirty {
            return .openAndSupersede                      // spurious clean restore/welcome window → yield it
        }
        return .openNewWindow
    }

    /// Queue the (clean, spurious) initial window to be closed once the file window registers.
    static func markSupersede(_ doc: EditorDocument) {
        docPendingClose = doc
    }

    /// True if `doc` is a spurious DUPLICATE restore window that should be closed on sight. macOS/SwiftUI
    /// spawns a fresh `nil`-spec WindowGroup window — which `OpenSpec.make` restores the last file into —
    /// not only at launch but also as a side effect of opening a file while the app is ALREADY running.
    /// When that restored file is already shown in another window, the new window is a pure duplicate
    /// (violating the registry's single-writer-per-file invariant), so the caller closes it and the
    /// existing window keeps the file. Only nil-spec (auto-created), clean, file-backed windows match —
    /// a welcome/blank window (no path) or a user-opened `.file` window never does. This is the bug
    /// report's "make the initial window participate in the same dedup".
    static func isSpuriousDuplicateRestoreWindow(_ doc: EditorDocument, wasNilSpec: Bool) -> Bool {
        guard wasNilSpec, !doc.vm.isDirty, doc.vm.filePath != nil else { return false }
        return WindowRegistry.shared.otherDocument(sharingFileWith: doc) != nil
    }

    /// Close a superseded initial window now that another window (the file window) has registered — at
    /// which point closing the initial one leaves ≥1 window, so terminate-after-last-window-closed can't
    /// fire. No-op unless something is queued and the newly-registered window is a different one.
    static func closePendingIfReady(newlyRegistered doc: EditorDocument) {
        guard let victim = docPendingClose, victim !== doc else { return }
        docPendingClose = nil
        victim.hostWindow?.close()
    }

    /// End the launch phase: later file-opens behave normally (a new window each). Called a beat after
    /// `applicationDidFinishLaunching` so a launch file-open (delivered around then) still supersedes.
    static func endLaunchPhase() {
        isLaunching = false
        initialDoc = nil
        docPendingClose = nil
    }
}
