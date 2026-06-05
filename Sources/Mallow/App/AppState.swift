// AppState — the app-level "which document is active" registry the menu commands act on. SwiftUI's
// `@FocusedValue`/`.focusedSceneValue` doesn't resolve here because the editing surface is an
// NSViewRepresentable (the NSTextView holds first responder, so no SwiftUI view is "focused"), so the
// commands can't rely on it. Instead each window reports itself active when its NSWindow becomes key,
// via WindowActiveTracker — robust and independent of SwiftUI's focus system.

import SwiftUI
import AppKit

@Observable
final class AppState {
    static let shared = AppState()
    private init() {}

    /// The document of the key (front) editor window. Menu commands operate on this.
    var activeDoc: EditorDocument?
}

/// A zero-size representable whose only job is to find its host NSWindow and mark `doc` active whenever
/// that window becomes key (and once on insert). Drop it in an editor window's background.
struct WindowActiveTracker: NSViewRepresentable {
    let doc: EditorDocument

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        let doc = self.doc
        DispatchQueue.main.async { [weak view] in
            guard let window = view?.window else { return }
            // Only claim "active" if this window is actually key. A restored or background window can
            // mount (and run this deferred block) while another window is frontmost; setting activeDoc
            // here unconditionally let a non-key window hijack the menu-command target (so the next ⌘S /
            // Format hit the wrong document). The didBecomeKey observer below still claims it the instant
            // this window does become key.
            if window.isKeyWindow { AppState.shared.activeDoc = doc }
            context.coordinator.token = NotificationCenter.default.addObserver(
                forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main
            ) { _ in
                AppState.shared.activeDoc = doc
                doc.reloadFromDiskIfChanged()   // re-sync with the file if it changed on disk while we were away
            }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var token: NSObjectProtocol?
        deinit { if let token { NotificationCenter.default.removeObserver(token) } }
    }
}
