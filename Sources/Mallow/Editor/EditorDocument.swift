// EditorDocument — the per-window document model (the SwiftUI-facing seam). It owns the configured
// MarkdownTextView and the EditorViewModel (the engine-driven parse → style → hide-syntax → command
// brain, reused verbatim from the AppKit build). One instance per window: the editor representable
// embeds its `textView`, the chrome reads its `vm` (filename, dirty dot), and menu/commands call into
// `vm`. Keeping the text view + view-model together here — instead of inside the representable — is
// what lets the SwiftUI chrome and the AppKit editor share one source of truth.

import SwiftUI
import AppKit

@Observable
final class EditorDocument: Identifiable {
    let id = UUID()
    @ObservationIgnored let textView: MarkdownTextView
    @ObservationIgnored let vm: EditorViewModel

    /// A monotonically-increasing counter the editor bumps on every text/selection change. The chrome
    /// reads it so SwiftUI re-evaluates the derived `vm` getters (displayName / isDirty), which depend
    /// on the NSTextView's contents — state SwiftUI can't observe directly.
    var revision = 0

    init(text: String = "", path: String? = nil) {
        let tv = MarkdownTextView()
        configureTextView(tv)
        tv.string = text
        self.textView = tv
        self.vm = EditorViewModel(textView: tv)
        self.vm.filePath = path
    }

    /// The AppKit window hosting this document's editor — nil before the view enters a window hierarchy /
    /// after teardown. The one accessor for window-level toggle, save-conflict alert anchor, reload
    /// surfacing, and paste focus (DocumentActions / ExternalReload / RenameSheet / PasteHandlers).
    var hostWindow: NSWindow? { textView.window }

    // Chrome-facing derived state (read through `revision` so SwiftUI tracks edits).
    var title: String { _ = revision; return vm.displayName }
    var isDirty: Bool { _ = revision; return vm.isDirty }
}
