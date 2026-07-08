// ViewportGeometry — the ONE owner of the text-container width formulas. Two writers set the
// container width (the Restyler each style pass, and the Coordinator's resize observer live during a
// window drag); before this type each carried its own copy of the same arithmetic, and they agreed
// only by parallel maintenance — the classic drift seed. Both now call here.
//
// The width model (table-rendering v2): the container normally fills the viewport exactly (prose wraps
// at the window edge); when a table is wider than the viewport the container grows to fit it and the
// editor scrolls horizontally, while prose keeps its viewport wrap via absolute tailIndents. So the
// container width is always `max(viewport, widest-scrolling-table)`.

import AppKit

enum ViewportGeometry {
    /// The container width that exactly FILLS a viewport whose clip view is `clipWidth` wide:
    /// the clip minus the editor's symmetric horizontal `textContainerInset`.
    static func viewportContainerWidth(clipWidth: CGFloat, insetWidth: CGFloat) -> CGFloat {
        max(0, clipWidth - 2 * insetWidth)
    }

    /// Convenience: the viewport-filling container width for `textView`, read from its enclosing
    /// scroll view's clip. Returns 0 when the view isn't in a scroll view yet (first pass, or a
    /// headless test) — callers choose their own fallback for that case.
    static func viewportContainerWidth(for textView: NSTextView) -> CGFloat {
        let clip = textView.enclosingScrollView?.contentView.bounds.width ?? 0
        return clip > 0 ? viewportContainerWidth(clipWidth: clip, insetWidth: textView.textContainerInset.width) : 0
    }

    /// The width to actually give the container: fills the viewport, but never below what a
    /// horizontally-scrolling table needs (0 when no table scrolls).
    static func containerWidth(viewport: CGFloat, tableNeed: CGFloat) -> CGFloat {
        max(viewport, tableNeed)
    }
}
