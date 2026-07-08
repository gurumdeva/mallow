// WindowLifecycleController — the executor of the per-window launch / open / dedup / supersede state
// machine, lifted out of EditorWindow's SwiftUI closures so the sequence (and its ~10 timing
// dependencies) lives in one plain, readable place instead of inline in `.onAppear` / `.onDisappear` /
// `.onReceive`. The View now just forwards its three lifecycle callbacks here.
//
// This is a thin value recreated per access (all shared state it touches — LaunchOpen statics, the
// WindowRegistry singleton, AppState, and the file-open dedup below — is external), holding only the
// window's document, its OpenSpec, and an INJECTED `openWindow` closure (so it doesn't depend on
// SwiftUI's `@Environment(\.openWindow)` and could be driven from a test). Behavior is preserved
// EXACTLY from the pre-extraction closures — the launch dance is order- and timing-sensitive.

import AppKit

struct WindowLifecycleController {
    let doc: EditorDocument
    /// The OpenSpec this window was created with. `nil` = SwiftUI auto-created it (launch/reopen) rather
    /// than File ▸ New/Open — the distinction the supersede/dedup logic keys on.
    let spec: OpenSpec?
    /// Injected window opener (`{ openWindow(value: $0) }` from the View's environment), so this type
    /// carries no SwiftUI dependency.
    let openWindow: (OpenSpec) -> Void

    /// EditorWindow.onAppear. A nil spec means SwiftUI auto-created this window (launch or reopen) rather
    /// than File ▸ New/Open (which pass `.blank`/`.file`); tag it so a launch file-open can supersede it.
    /// Then register in the single-writer registry, close a superseded initial window once we're up, and
    /// close a spurious duplicate restore window (macOS spawns one when a file is opened while the app is
    /// already running — the existing window owns the file).
    func onAppear() {
        if spec == nil { LaunchOpen.tagInitialWindow(doc) }
        WindowRegistry.shared.register(doc)
        LaunchOpen.closePendingIfReady(newlyRegistered: doc)  // close a superseded initial window once we're up
        if LaunchOpen.isSpuriousDuplicateRestoreWindow(doc, wasNilSpec: spec == nil) {
            let victim = doc
            DispatchQueue.main.async { victim.hostWindow?.close() }
        }
    }

    /// EditorWindow.onDisappear. Drop the registry entry, and drop the app-wide active-doc pointer if it
    /// was us so a menu command fired after this window closes can't act on — or strongly retain (leak) —
    /// a torn-down document + its NSTextView. A surviving window re-asserts itself active via
    /// WindowActiveTracker when it next becomes key.
    func onDisappear() {
        WindowRegistry.shared.unregister(doc)
        if AppState.shared.activeDoc === doc { AppState.shared.activeDoc = nil }
    }

    /// EditorWindow.onReceive(.mallowOpenFile). Decide what to do with a Finder/`open` file event this
    /// window received, then execute it. Dedups so that — since every open window mounts this handler —
    /// one path opens once per ~1s (see `claimFileOpen`).
    func handleOpenFile(path: String) {
        guard Self.claimFileOpen(path) else { return }
        let action = LaunchOpen.decide(openPath: path,
                                       receivingWindowPath: doc.vm.filePath,
                                       receivingWindowIsDirty: doc.vm.isDirty,
                                       receivingWindowIsInitial: doc === LaunchOpen.initialDoc,
                                       isLaunching: LaunchOpen.isLaunching)
        switch action {
        case .focusThisWindow:
            // This window already holds the file (e.g. the restored last file == the opened file) —
            // focus it rather than open a duplicate.
            WindowRegistry.shared.focusWindow(of: doc)
        case .openNewWindow:
            // Normal behavior: focus an already-open window for this file, else open a new one.
            if let existing = WindowRegistry.shared.document(forPath: path) {
                WindowRegistry.shared.focusWindow(of: existing)
            } else {
                openWindow(.file(path: path))
            }
        case .openAndSupersede:
            // Launch handed us a different file than the restore/welcome this initial window shows:
            // open the file in its own window and close this spurious one (once the file window is up).
            openWindow(.file(path: path))
            LaunchOpen.markSupersede(doc)
        }
    }

    // MARK: - File-open dedup (shared across all windows)

    /// De-dupe Finder/`open` file events: every open window mounts the `.onReceive`, so without this each
    /// would open the same path. Allow one open per path per ~1 second. Static shared state — the dedup is
    /// app-wide, not per-window (this value type is recreated per callback).
    private static var lastFileOpen: (path: String, at: TimeInterval) = ("", 0)
    static func claimFileOpen(_ path: String) -> Bool {
        let now = ProcessInfo.processInfo.systemUptime
        if lastFileOpen.path == path, now - lastFileOpen.at < 1.0 { return false }
        lastFileOpen = (path, now)
        return true
    }
}
