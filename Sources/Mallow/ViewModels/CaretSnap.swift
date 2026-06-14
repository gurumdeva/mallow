// CaretSnap — pure caret/selection geometry, extracted from EditorViewModel. Hidden markers are zero-width
// glyphs, so a click/drag can land an endpoint inside a hidden run's interior, where every position shares
// one x; this snaps it out (see EditorViewModel.snapCaretOutOfHiddenRuns for the full why).

import Foundation

enum CaretSnap {
    /// Snap `sel` out of any hidden-run interior. A boundary is "interior" only when the chars on BOTH sides
    /// are hidden — a run's outer edges, where the caret meets visible text, stay valid landing spots. A bare
    /// caret escapes in its direction of travel (from `lastCaret`); a range grows each interior endpoint out
    /// to the run edge (so selecting a link is atomic and the highlight matches the visible text exactly).
    static func snapped(_ sel: NSRange, total: Int, hidden: Set<Int>, lastCaret: Int) -> NSRange {
        if hidden.isEmpty { return sel }
        func interior(_ b: Int) -> Bool { b > 0 && b < total && hidden.contains(b) && hidden.contains(b - 1) }
        func runEnd(_ b: Int) -> Int { var e = b; while e < total, hidden.contains(e) { e += 1 }; return e }
        func runStart(_ b: Int) -> Int { var s = b; while s > 0, hidden.contains(s - 1) { s -= 1 }; return s }
        if sel.length == 0 {
            let b = sel.location
            guard interior(b) else { return sel }
            return NSRange(location: b >= lastCaret ? runEnd(b) : runStart(b), length: 0)
        }
        var lo = sel.location, hi = sel.location + sel.length
        if interior(lo) { lo = runStart(lo) }
        if interior(hi) { hi = runEnd(hi) }
        return NSRange(location: lo, length: hi - lo)
    }
}
