// StatusBar — the slim bottom bar under the editor, mirroring the Tauri app's footer that showed the
// live word / character counts (+ read-time). A purely visual, read-only strip: ~22pt tall, full-width,
// Theme.bg with a single 1px top hairline (Theme.border) — no buttons, no borders beyond that line, in
// keeping with Mallow's minimal identity.
//
// The numbers come from the SAME pure `DocStats(markdown:)` the Document-Info popover uses, computed off
// `doc.textView.string` (markdown stays the source of truth — the buffer is only read). DocStats is a
// fast value type, so recomputing it in `body` on every render is fine; that is deliberately how it stays
// live. The trick is the leading `_ = doc.revision`: the editor's Coordinator bumps `doc.revision` on each
// text/selection change, and touching it here registers an observation dependency so SwiftUI re-evaluates
// this body (and thus re-reads the NSTextView's contents) on every edit — state SwiftUI can't see directly.
// Colors are the shared `Theme` tokens, so the bar tracks light/dark in lockstep with the editor chrome.

import SwiftUI

struct StatusBar: View {
    /// The per-window document. Its `textView.string` is the source text to count; its `revision` is the
    /// edit/selection tick that drives the live recompute (see the file header). Nothing else is stored.
    let doc: EditorDocument

    /// Total bar height — a slim footer that doesn't compete with the editor (matches the brief's ~22pt).
    private let barHeight: CGFloat = 22

    /// Recompute the (cheap, pure) stats off the current buffer, touching `revision` so SwiftUI tracks it
    /// and re-evaluates this view on every edit. Kept as a computed property (not a bare `_ = …` line in
    /// the ViewBuilder body, which the result builder rejects).
    private var currentStats: DocStats {
        _ = doc.revision
        return DocStats(markdown: doc.textView.string)
    }

    var body: some View {
        let s = currentStats
        return HStack(spacing: 0) {
            Spacer(minLength: 8)            // push the cluster to the trailing edge (right-aligned footer)
            Text(statsLine(s))
                .font(.system(size: 11))
                .foregroundStyle(Theme.dim)
                .lineLimit(1)
                .truncationMode(.head)     // if it ever overflows a tiny window, drop the leftmost stat
                .monospacedDigit()         // counts don't jitter horizontally as digits tick
        }
        .padding(.horizontal, 12)
        .frame(height: barHeight)
        .frame(maxWidth: .infinity)
        .background(Theme.bg)
        // The single 1px top hairline — the bar's only chrome. `.top` alignment pins it to the seam with
        // the editor; height 1 stays crisp (no sub-pixel blur) at any scale.
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Theme.border)
                .frame(height: 1)
        }
        // Read-only, decorative status — keep it out of the a11y tree's interaction path; VoiceOver still
        // reads the composed label as one element.
        .accessibilityElement(children: .combine)
    }

    /// The compact stat string: localized "words" / "characters" labels (reusing the popover's keys) and
    /// the read-time as `\(minutes)\(unit)` — exactly the form the Document-Info popover renders. Joined by
    /// " · " middots to read as one quiet line, e.g. "1,234 Words · 5,678 Characters · 6m".
    private func statsLine(_ s: DocStats) -> String {
        let words = "\(s.words) \(L.t("info.stat.words"))"
        let chars = "\(s.characters) \(L.t("info.stat.characters"))"
        let read  = "\(s.readMinutes)\(L.t("info.readMinuteUnit"))"   // unit-only, like the stat card
        return "\(words) · \(chars) · \(read)"
    }
}
