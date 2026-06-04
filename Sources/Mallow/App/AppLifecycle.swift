// AppLifecycle — the app-level plumbing SwiftUI's `App`/`WindowGroup` doesn't give us for free:
//   1) an NSApplicationDelegate (via `@NSApplicationDelegateAdaptor` in MallowApp) to receive the
//      Finder "open with" / `open -a` / dock-drop file events that never reach a Scene, and turn each
//      into a `.mallowOpenFile` notification the scene can act on with `openWindow(value: .file(path:))`;
//   2) a per-window `WindowConfigurator` that, once SwiftUI has materialized the host NSWindow, installs
//      a close-confirmation NSWindowDelegate (the unsaved-changes guard the AppKit build did in
//      `windowShouldClose`) and starts SessionStore geometry/last-file tracking for that window.
//
// Why a notification instead of calling `openWindow` from the delegate: `@Environment(\.openWindow)` is
// only resolvable inside a View/Scene body, not from an AppDelegate. So the delegate's job is purely to
// *broadcast* the path; MallowApp subscribes and does the actual window open.
//
// Why a representable for the window delegate (mirroring WindowActiveTracker / SessionRestore's seam):
// WindowGroup content windows on macOS 14 expose no SwiftUI hook for "should this window close?" — that
// decision lives on NSWindowDelegate. The only way to reach the NSWindow from SwiftUI is to find it from
// a hosted NSView, so this representable defers a frame to grab `view.window` and wires the delegate
// there. It is deliberately conservative about an existing delegate (forwards, never silently drops it).

import SwiftUI
import AppKit

// MARK: - Notification

extension Notification.Name {
    /// Posted by `MallowAppDelegate` for each file the OS hands us (Finder double-click, `open -a`,
    /// dock drop). `userInfo["path"]` is the absolute file path. MallowApp observes this and opens a
    /// window with `OpenSpec.file(path:)`.
    static let mallowOpenFile = Notification.Name("mallowOpenFile")
    /// Posted by the View ▸ Document Info (⇧⌘I) command; the front editor window toggles its info popover.
    static let mallowToggleInfo = Notification.Name("mallowToggleInfo")
}

// MARK: - Application delegate

/// The `NSApplicationDelegate` SwiftUI installs via `@NSApplicationDelegateAdaptor` (added in MallowApp).
/// Its sole responsibilities are the app-wide lifecycle events `App`/`WindowGroup` can't express:
/// receiving OS-level open-file requests and the last-window-closed termination policy.
final class MallowAppDelegate: NSObject, NSApplicationDelegate {

    // MARK: open-file events

    /// The modern entry point (macOS 10.13+): Finder "Open With", `open -a Mallow file.md`, and dock
    /// drops all arrive here with one or more file URLs. We don't open windows directly (no `openWindow`
    /// outside a Scene) — we broadcast each path so the scene can turn it into `OpenSpec.file(path:)`.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            postOpen(url)
        }
    }

    /// Legacy single-file fallback. Some launch paths (older callers, certain Apple Events) still use
    /// `application(_:openFile:)` rather than `open urls:`; handle both so no entry point is missed.
    /// Returning `true` tells AppKit we took responsibility for the file.
    func application(_ sender: NSApplication, openFile filename: String) -> Bool {
        postOpen(URL(fileURLWithPath: filename))
        return true
    }

    /// Broadcast a single file open request as `.mallowOpenFile` with its path in `userInfo`. Only
    /// genuine file URLs are forwarded (a stray non-file URL would have no `.path` worth opening).
    private func postOpen(_ url: URL) {
        guard url.isFileURL else { return }
        NotificationCenter.default.post(
            name: .mallowOpenFile,
            object: nil,
            userInfo: ["path": url.path]
        )
    }

    // MARK: termination policy

    /// Quit when the last editor window is closed (standard single-purpose-editor behavior, matching the
    /// old AppKit build). Without this a windowless app would linger in the Dock with only the menu bar.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    /// Confirm before quitting if any window has unsaved changes (⌘Q closes all windows at once, which
    /// would otherwise bypass the per-window close prompt). Mirrors the Tauri app's dirty-window guard.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard confirmQuitIfDirty() else { return .terminateCancel }
        // Force the debounced session write (window geometry + last-edited file) before we exit, so
        // quitting within the ~0.4s save-debounce window doesn't drop the final state on the floor.
        SessionStore.flushNow()
        return .terminateNow
    }

    /// Drop the automatic window-tab affordances (Show Tab Bar / Show All Tabs) — this is a single-window-
    /// per-document editor, and removing them de-clutters the system View menu so it doesn't duplicate the
    /// app's own 보기/View menu.
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSWindow.allowsAutomaticWindowTabbing = false
    }
}

// MARK: - Per-window configurator

/// A zero-size `NSViewRepresentable` dropped into an editor window's `.background(...)`. Once SwiftUI has
/// attached the content to a real NSWindow, it:
///   • installs a close-confirmation `NSWindowDelegate` (Coordinator) so closing a window with unsaved
///     edits prompts a discard confirm (the AppKit build's `windowShouldClose`), and
///   • starts `SessionStore` tracking (geometry + last-edited file) for that window.
///
/// It mirrors `WindowActiveTracker`'s shape on purpose: same `DispatchQueue.main.async { view.window }`
/// deferral to reach the window after it exists, same Coordinator-owns-the-teardown lifetime model.
struct WindowConfigurator: NSViewRepresentable {
    /// This window's document — read for the dirty check on close and the last-file path for the session.
    let doc: EditorDocument

    /// Latched once the launch's FIRST editor window has had the saved geometry applied, so the restore
    /// targets exactly one window — later windows keep SwiftUI's cascade instead of all stacking onto the
    /// one restored frame. Main-thread-only (every `attach` runs on main), like the rest of this file.
    static var didApplyRestoredFrame = false

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        let coordinator = context.coordinator
        coordinator.doc = doc

        // The window doesn't exist yet inside makeNSView; defer one runloop turn so `view.window` is set,
        // exactly as WindowActiveTracker / SessionRestore do. `view` is captured weakly so a window torn
        // down before this fires can't be resurrected.
        DispatchQueue.main.async { [weak view] in
            guard let window = view?.window else { return }
            coordinator.attach(to: window)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        // Nothing to do on update: the window identity and the document are fixed for this view's life,
        // and SessionStore's own NotificationCenter observers handle ongoing geometry/last-file changes.
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    /// Owns the window wiring: it IS the window's delegate (answering `windowShouldClose`), forwards any
    /// other delegate calls to a pre-existing delegate, and holds the SessionStore observer tokens so
    /// they're removed when the window (and thus this coordinator) goes away.
    final class Coordinator: NSObject, NSWindowDelegate {
        /// Set in makeNSView before `attach`. Weak isn't needed (the document outlives the window via the
        /// SwiftUI View's @State), but it's an unowned-style reference only used while the window is live.
        var doc: EditorDocument?

        /// The window we configured (weak — we never want to keep a closing window alive).
        private weak var window: NSWindow?

        /// A delegate that was already set on the window when we arrived. SwiftUI does NOT assign a
        /// delegate to WindowGroup content windows on macOS 14, so this is normally nil — but we forward
        /// to it defensively rather than stomp it, in case a future SwiftUI/AppKit change sets one.
        private weak var previousDelegate: NSWindowDelegate?

        /// SessionStore's geometry/last-file observers for this window. Block-based NotificationCenter
        /// observers are NOT auto-removed when the observed window deallocs (SessionRestore documents
        /// this), so we keep the tokens and remove them in `deinit`.
        private var sessionTokens: [NSObjectProtocol] = []

        /// Wire up the window: preserve any existing delegate, become the delegate, and start session
        /// tracking. Idempotent guard via `self.window` so a duplicate deferred call is a no-op.
        func attach(to window: NSWindow) {
            guard self.window == nil else { return }
            self.window = window

            // Preserve and forward, don't destroy. If something already owns this window's delegate, keep
            // a reference so unhandled delegate messages still reach it (see `respondsToSelector` /
            // `forwardingTarget` below). Guard against the degenerate self-reference.
            if let existing = window.delegate, existing !== self {
                previousDelegate = existing
            }
            window.delegate = self

            // Restore the last session's window geometry — but only for the FIRST editor window of the
            // launch (the latch ensures later windows keep their cascade rather than all snapping onto the
            // saved frame). Done before session tracking starts so tracking's initial capture records this
            // restored frame, not the transient default size.
            if !WindowConfigurator.didApplyRestoredFrame {
                WindowConfigurator.didApplyRestoredFrame = true
                if let frame = SessionStore.restoredFrame() {
                    window.setFrame(frame, display: true)
                }
            }

            // Persist geometry + last-edited file for this window. The closure reads the live path each
            // time the window becomes main, so renames/saves are reflected without re-registration.
            sessionTokens = SessionStore.track(window: window) { [weak self] in
                self?.doc?.vm.filePath
            }
        }

        // MARK: NSWindowDelegate — close confirmation

        /// The unsaved-changes guard. Clean document → allow the close. Dirty → run a modal discard
        /// confirm and return the user's choice (true = discard & close, false = keep editing). This is
        /// the SwiftUI-era home of the AppKit build's `windowShouldClose`.
        func windowShouldClose(_ sender: NSWindow) -> Bool {
            guard let doc, doc.vm.isDirty else {
                return true   // nothing unsaved (or no doc) — close freely
            }
            return confirmDiscard(on: sender)
        }

        /// Modal "Discard unsaved changes?" alert, reusing the shared `dialog.discard.*` locale keys (same
        /// strings as the old app). Returns true iff the user chose Discard.
        ///
        /// Button order is deliberate: Discard is added first so it's the default (⏎) action and gets the
        /// destructive styling, while Cancel is the escape/`.cancel` action — so an accidental ⌘W that
        /// hits ⏎ still discards intentionally, but pressing Esc (or clicking Cancel) keeps the window.
        private func confirmDiscard(on window: NSWindow) -> Bool {
            NSAlert.confirmDestructive(title: L.t("dialog.discard.title"),
                                       body: L.t("dialog.discard.body"),
                                       confirm: L.t("dialog.discard.confirm"),
                                       cancel: L.t("dialog.discard.cancel"))
        }

        // MARK: NSWindowDelegate — forwarding to a pre-existing delegate

        // We only implement `windowShouldClose`. For every other NSWindowDelegate message, transparently
        // defer to whatever delegate the window already had (normally none on macOS 14). This keeps the
        // configurator additive: it answers the close question and leaves all other behavior untouched.

        override func responds(to aSelector: Selector!) -> Bool {
            if super.responds(to: aSelector) { return true }
            return previousDelegate?.responds(to: aSelector) ?? false
        }

        override func forwardingTarget(for aSelector: Selector!) -> Any? {
            if let previousDelegate, previousDelegate.responds(to: aSelector) {
                return previousDelegate
            }
            return super.forwardingTarget(for: aSelector)
        }

        deinit {
            // Remove the SessionStore observers (not auto-removed on window dealloc — see above) and,
            // if we're still the live delegate, restore whatever was there before us.
            let nc = NotificationCenter.default
            for token in sessionTokens { nc.removeObserver(token) }
            if window?.delegate === self {
                window?.delegate = previousDelegate
            }
        }
    }
}
