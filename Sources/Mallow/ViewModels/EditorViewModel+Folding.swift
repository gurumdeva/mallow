// EditorViewModel+Folding — View ▸ Fold Section: toggle/clear per-section folds and park the caret
// out of a collapsed body. Folds are re-derived from the parse each refresh (keyed by heading start).

import AppKit

extension EditorViewModel {
    /// Toggle the fold of the section the caret is in — its enclosing heading, i.e. the last heading at
    /// or before the caret. Folds are re-derived from the parse each refresh; `foldedHeadingStarts` keys
    /// them by the heading's UTF-16 start and is reset on any text edit (so a shifted offset can't fold
    /// the wrong section — see `clearSectionFolds`). Fold All (`allSectionsFolded`) is independent.
    func toggleFoldSectionAtCaret() {
        guard let textView else { return }
        let s = textView.string
        let caret = textView.selectedRange().location
        let map = byteToUTF16Map(s)
        let total = (s as NSString).length
        var heading: Int?
        for b in blocks where b.kindTag == "Heading" {
            let lo = b.range.utf16Bounds(map: map, clampedTo: total).lo
            if lo <= caret { heading = lo } else { break }   // blocks are ordered; first heading past the caret stops us
        }
        guard let hStart = heading else { return }   // caret is before the first heading — nothing to fold
        if foldedHeadingStarts.contains(hStart) { foldedHeadingStarts.remove(hStart) } else { foldedHeadingStarts.insert(hStart) }
        refresh()
        // Park the caret on the heading line (always visible) — so it isn't stranded in the now-collapsed
        // body, and re-invoking the command toggles the SAME section back open.
        textView.setSelectedRange(NSRange(location: min(hStart, (textView.string as NSString).length), length: 0))
    }

    /// After Fold All collapses every section, the caret may sit in a now-folded (zero-height) body line,
    /// where it renders invisibly — the caret-snap only escapes `hiddenChars`, but a folded line's newline
    /// lives in `foldedChars` (kept out of `hiddenChars` to preserve line structure). Park the caret on its
    /// enclosing heading line (always visible), mirroring `toggleFoldSectionAtCaret`. No-op when nothing is
    /// folded, the caret's line is already visible, or it sits before the first heading (the intro stays open).
    func parkCaretOutOfFold() {
        guard let textView, allSectionsFolded else { return }
        let total = (textView.string as NSString).length
        let caret = textView.selectedRange().location
        guard caret < total, foldedChars.contains(caret) else { return }   // only act when the caret line is folded
        let s = textView.string
        let map = byteToUTF16Map(s)
        var heading: Int?
        for b in blocks where b.kindTag == "Heading" {
            let lo = b.range.utf16Bounds(map: map, clampedTo: total).lo
            if lo <= caret { heading = lo } else { break }   // last heading at/before the caret (blocks are ordered)
        }
        guard let hStart = heading else { return }   // caret is before the first heading — its line stays visible
        textView.setSelectedRange(NSRange(location: min(hStart, total), length: 0))
    }

    /// Set Fold All and re-render with its exact recompute recipe: `refresh()` re-derives the folded set
    /// from the live parse, then park the caret out of any now-collapsed body (`parkCaretOutOfFold`) and
    /// snap it out of a collapsed inline run it may have landed in (`selectionChanged`). Owning the recipe
    /// here keeps the sequence — and refresh's IME chokepoint — with the state it drives, instead of in
    /// DocumentActions' menu glue.
    func setFoldAll(_ on: Bool) {
        allSectionsFolded = on
        refresh()
        parkCaretOutOfFold()   // park on the enclosing heading if the caret landed in a now-folded body
        selectionChanged()     // snap the caret out of a collapsed (hidden) inline run if it landed in one
    }

    /// Drop all per-section folds — called on every text edit, since their UTF-16 keys would otherwise go
    /// stale against the shifted text. (Fold All re-derives from the live parse, so it is unaffected.)
    func clearSectionFolds() {
        guard !foldedHeadingStarts.isEmpty else { return }
        foldedHeadingStarts.removeAll()
    }
}
