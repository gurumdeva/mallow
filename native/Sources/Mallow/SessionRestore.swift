// SessionRestore (Service) — persists + restores the app session across launches, mirroring the Tauri
// reference's window-geometry persistence + StartupPlanner. Two things are remembered, both in
// Application Support/MallowNative/window.json (atomic, debounced):
//   1. the main window's frame (so it reopens at the same size/place), and
//   2. the path of the last-edited document (so it reopens on next launch).
//
// The startup priority matches StartupPlanner.ts exactly (explicit > restore-last > welcome > blank):
//   • an explicit file (Finder "Open With" / CLI arg) ALWAYS wins — `planStartup` returns its content.
//   • else, if we've shown the welcome demo before AND the stored last file still exists, reopen it.
//   • else, on the very first run, show the welcome demo once (and record that we did).
//   • else (re-run with no last file) start blank.
// Restore is silent: a missing last document falls back to blank with no alert (the user didn't click
// it). Off-screen frames are clamped back onto a visible screen before use.
//
// Layering: `SessionStore` is the pure-ish persistence + geometry policy (atomic JSON, debounce, clamp,
// the startup decision) with no window/menu plumbing; `track(window:controller:)` is the only AppKit
// seam — it observes the window's own move/resize/main notifications via NotificationCenter, so the
// geometry-save + last-file capture need NO edits to EditorController/its delegate. Only the two genuine
// call sites — applying the restored frame to the FIRST window, and choosing restore-vs-demo at launch —
// live in shared files (see sharedChanges); everything else is self-contained here.

import AppKit

// MARK: - Persisted session model

/// The on-disk session: the main window's last frame + the last-edited document path + a first-run
/// flag. All optional so a partial / older file still decodes (missing keys ⇒ nil ⇒ sensible default).
private struct SessionState: Codable {
    var x: Double?
    var y: Double?
    var width: Double?
    var height: Double?
    /// Absolute path of the last document the user was editing (nil ⇒ untitled / nothing to restore).
    var lastFile: String?
    /// Set once the welcome demo has been shown, gating restore so the first-run welcome is never
    /// overwritten by a restore (matches StartupPlanner's `welcomed`).
    var welcomed: Bool?

    var frame: NSRect? {
        guard let x, let y, let width, let height, width > 0, height > 0 else { return nil }
        return NSRect(x: x, y: y, width: width, height: height)
    }
}

// MARK: - The startup decision (pure; mirrors StartupPlanner.planStartup)

/// What the FIRST window should open with. The caller (main.swift) executes the chosen branch.
enum StartupPlan {
    /// An explicit file (Finder/CLI) — already read off disk; open its content, backed by `path`.
    case explicit(content: String, path: String)
    /// Silently reopen the last session's document (already read); failures upstream fall to `.blank`.
    case restore(content: String, path: String)
    /// First run, nothing to open → the welcome demo (untitled).
    case welcome
    /// A re-run with no last file → an empty untitled document.
    case blank
}

// MARK: - Session store: persistence + geometry policy + startup planning

enum SessionStore {
    /// Coalesce a burst of move/resize events into a single write (the reference debounces geometry
    /// saves too; live-resize fires continuously). Short, since a crash/quit between events is benign.
    private static let saveDebounce: TimeInterval = 0.4

    private static var storeURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MallowNative", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("window.json")
    }

    /// In-memory mirror of the persisted state; loaded once, mutated by the save helpers, and flushed
    /// atomically. Read on the main thread only (all callers are main-thread AppKit hooks).
    private static var state: SessionState = load()
    private static var pendingSave: DispatchWorkItem?

    private static func load() -> SessionState {
        guard let data = try? Data(contentsOf: storeURL),
              let s = try? JSONDecoder().decode(SessionState.self, from: data) else { return SessionState() }
        return s
    }

    /// Flush `state` to disk atomically (like RecentFilesStore). Best-effort: a write failure leaves
    /// the previous file intact and is silently ignored (session restore is a convenience, not data).
    private static func flush() {
        try? JSONEncoder().encode(state).write(to: storeURL, options: .atomic)
    }

    /// Coalesce rapid geometry changes into one write `saveDebounce` later (cancelling any pending one).
    private static func scheduleFlush() {
        pendingSave?.cancel()
        let work = DispatchWorkItem { flush() }
        pendingSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + saveDebounce, execute: work)
    }

    // MARK: geometry

    /// The restored main-window frame to apply on launch, clamped onto a currently-visible screen, or
    /// nil when there's nothing saved (first run) or no screen contains it usefully. WindowFactory uses
    /// this for the FIRST window only (see sharedChanges); later windows keep their cascade/center.
    static func restoredFrame() -> NSRect? {
        guard let saved = state.frame else { return nil }
        return clampedOnScreen(saved)
    }

    /// Begin tracking a window's geometry + (when it's the active document) its file path. Idempotent
    /// per window is not required — call once, right after the first window is built. Registers
    /// NotificationCenter observers scoped to THIS window so no NSWindowDelegate hook is needed:
    ///   • move / end-of-live-resize  → debounce-save the frame
    ///   • became-main                → record the controller's document as the "last file"
    /// `controller` is captured weakly so tracking never keeps a closed window alive.
    /// Returns the registered observer tokens so the owning controller can remove them on close —
    /// block-based observers are NOT auto-removed when the observed window deallocs, so without this
    /// they accumulate for the app's lifetime (3 per window ever opened).
    @discardableResult
    static func track(window: NSWindow, controller: EditorController) -> [NSObjectProtocol] {
        let nc = NotificationCenter.default
        // Frame changes. `didEndLiveResize` (not `didResize`) avoids a write per drag-frame; `didMove`
        // is discrete already. Both read the live frame so the two stay consistent.
        let onGeometry: (Notification) -> Void = { [weak window] _ in
            guard let window else { return }
            saveFrame(window.frame)
        }
        let move = nc.addObserver(forName: NSWindow.didMoveNotification, object: window, queue: .main) { onGeometry($0) }
        let resize = nc.addObserver(forName: NSWindow.didEndLiveResizeNotification, object: window, queue: .main) { onGeometry($0) }
        // Last-edited document: whenever this window becomes the active one, remember what it's editing
        // (or clear, if it's an untitled buffer). On quit the most-recently-focused document wins —
        // exactly "the last thing you were working on".
        let main = nc.addObserver(forName: NSWindow.didBecomeMainNotification, object: window, queue: .main) { [weak controller] _ in
            saveLastFile(controller?.vm.filePath)
        }
        // Capture the initial frame immediately so even a launch with no later move/resize persists a
        // sensible geometry (e.g. restored-then-quit without touching the window).
        saveFrame(window.frame)
        saveLastFile(controller.vm.filePath)
        return [move, resize, main]
    }

    private static func saveFrame(_ frame: NSRect) {
        guard frame.width > 0, frame.height > 0 else { return }
        state.x = Double(frame.origin.x)
        state.y = Double(frame.origin.y)
        state.width = Double(frame.size.width)
        state.height = Double(frame.size.height)
        scheduleFlush()
    }

    /// Record (or clear) the last-edited document path. Debounced like geometry — the path changes far
    /// less often, but a save-on-quit may set it right before the process exits, so we also expose
    /// `flushNow()` for AppDelegate to force a synchronous write on terminate (see sharedChanges).
    static func saveLastFile(_ path: String?) {
        state.lastFile = path
        scheduleFlush()
    }

    /// Force a synchronous flush (cancelling any pending debounced one). Call from
    /// `applicationShouldTerminate` so the final geometry / last-file aren't lost to the debounce window.
    static func flushNow() {
        pendingSave?.cancel()
        pendingSave = nil
        flush()
    }

    // MARK: startup planning (mirrors StartupPlanner.planStartup priority)

    /// Decide what the first window opens with. `explicitPath` is a Finder/CLI file path (highest
    /// priority); `demo` is the welcome text. Reads the last file off disk here (the only I/O), so the
    /// caller just opens the returned content. Marks `welcomed` as a side effect on the welcome branch
    /// so the next launch switches to the restore path (exactly like the reference's localStorage flag).
    static func planStartup(explicitPath: String?, demo: String) -> StartupPlan {
        // (1) Explicit file (Finder "Open With" / CLI arg) — always wins over any restore/welcome.
        if let explicitPath, let content = try? String(contentsOfFile: explicitPath, encoding: .utf8) {
            return .explicit(content: content, path: explicitPath)
        }

        // (2) Restore last document — only once the welcome demo has been seen (so a first run can't be
        //     hijacked by a stale path) and only if the file still exists + reads. Silent on failure.
        if state.welcomed == true, let path = state.lastFile,
           FileManager.default.fileExists(atPath: path),
           let content = try? String(contentsOfFile: path, encoding: .utf8) {
            return .restore(content: content, path: path)
        }

        // (3) First run, nothing to open → welcome demo once; record it so future launches restore.
        if state.welcomed != true {
            state.welcomed = true
            scheduleFlush()
            return .welcome
        }

        // (4) Re-run with no usable last file → blank.
        return .blank
    }

    // MARK: off-screen clamping

    /// Pull `frame` back onto a visible screen so a window saved on a since-removed monitor (or dragged
    /// mostly off the edge) doesn't reappear unreachable. If it already overlaps a screen meaningfully
    /// it's returned unchanged; otherwise it's resized to fit and re-centered on the best screen's
    /// visible area (excludes the menu bar / Dock).
    static func clampedOnScreen(_ frame: NSRect) -> NSRect {
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return frame }   // headless / no displays — leave as-is

        // "Meaningfully visible" = the frame intersects some screen's visible area by a non-trivial
        // patch (so a 1px sliver on-screen still counts as off-screen and gets recovered).
        let minVisible: CGFloat = 80
        let overlapsEnough = screens.contains { screen in
            let i = frame.intersection(screen.visibleFrame)
            return !i.isNull && i.width >= min(minVisible, frame.width) && i.height >= min(minVisible, frame.height)
        }
        if overlapsEnough { return frame }

        // Recover onto the screen whose visible area overlaps the frame most (else the main screen).
        let target = screens.max { a, b in
            area(frame.intersection(a.visibleFrame)) < area(frame.intersection(b.visibleFrame))
        } ?? screens[0]
        let vis = target.visibleFrame
        // Clamp the SIZE to the visible area first, then center within it.
        let w = min(frame.width, vis.width)
        let h = min(frame.height, vis.height)
        let x = vis.minX + (vis.width - w) / 2
        let y = vis.minY + (vis.height - h) / 2
        return NSRect(x: x, y: y, width: w, height: h)
    }

    private static func area(_ r: NSRect) -> CGFloat { r.isNull ? 0 : r.width * r.height }
}
