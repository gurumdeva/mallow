// TableRendering — a markdown-as-truth treatment for GFM tables that lays out a REAL aligned grid.
//
// The engine (Inkstone) emits a GFM table as ONE block (`kindTag == "Table"`) whose `range` spans the
// whole table and whose `inlines` carry the cell text runs — AND, now, a `cells` array giving each
// cell's row, column, source byte range, and column alignment. That cell structure is what makes a
// proper grid possible without rewriting the buffer (the source pipe text stays the source):
//
//   • Each column's width is the widest cell in it, measured from the VISIBLE glyphs (markers hidden,
//     CJK/emoji at their true advance) — not assumed one monospace cell wide. Monospace can't align
//     Hangul (글리프 너비가 셀 폭과 다름); measuring per cell and padding to the column width can.
//   • Every cell is padded to its column's width with `.kern` (a DISPLAY attribute — the source bytes
//     stay untouched, editing is normal), distributed per the column's alignment (left/center/right).
//     So the raw `|` separators land at the SAME x in every row: straight columns.
//   • The grid lines are drawn by `MarkdownTextView.drawBackground` at x-positions COMPUTED from those
//     same column widths (`TableGrid.interiorEdges`), anchored to the table's probed left edge — so the
//     rules and the text share one column model and can't drift (the old approach probed each row's `|`
//     glyph, which is ragged for CJK because the rows didn't truly align).
//
// The `|` bars themselves are rendered as spaces and the `|---|` delimiter row collapsed by the
// view-model's hide pass (EditorViewModel.recomputeHidden / TablePipeScanner) — markers never show,
// the bytes are untouched. This file only styles + measures + kerns the table block's own UTF-16 range
// and returns the grid geometry; it runs AFTER recomputeHidden so it can read the hidden set when
// measuring visible widths (a cell with inline `code`/**bold** measures only what the reader sees).

import AppKit

/// Geometry the text view needs to draw one table's grid: the block's UTF-16 range (for the card +
/// per-row rules) and the interior column-rule x-offsets, measured from the table's left text edge.
struct TableGrid {
    let blockRange: NSRange
    /// x-offset of each interior column rule from the table's first glyph (left edge). One per column
    /// boundary, i.e. `columnCount - 1` entries. The view adds the probed left-edge x to place them.
    let interiorEdges: [CGFloat]
    /// Total laid-out width of the table from its first glyph to its last (the outer pipes' spaces
    /// included). The view sizes the card to this so it hugs the table instead of spanning the page.
    let totalWidth: CGFloat
}

enum TableRendering {

    /// Style + align one `kindTag == "Table"` block, returning its `TableGrid` (or nil if the block is
    /// empty / out of bounds). Applies the mono font + tidy paragraph style, re-asserts inline emphasis,
    /// then kerns each cell so its column has a uniform width (so the separators line up), and computes
    /// the interior column-rule offsets from those widths.
    ///
    /// - Parameters:
    ///   - block:   the Table PBlock — its `range` is a source BYTE range and `cells` the grid structure.
    ///   - map:     the byte→UTF-16 lookup restyle built once (O(1) range conversion).
    ///   - storage: the text storage to mutate (fonts + alignment kern).
    ///   - hidden:  the view-model's hidden-glyph set (markers rendered zero-width) — so a cell's visible
    ///              width excludes any hidden `**`/`` ` ``/`](url)` it contains.
    @discardableResult
    static func style(_ block: PBlock, map: [Int], storage: NSTextStorage, hidden: Set<Int>) -> TableGrid? {
        let ns = storage.string as NSString
        let total = ns.length
        guard let blockRange = block.range.utf16Range(map: map, clampedTo: total) else { return nil }

        // 1) Build the cell grid from the engine's cells (UTF-16). Each row has the header's column count
        //    (the engine pads short rows with empty cells), so this is a rectangular [row][col] table.
        let colCount = (block.cells.map(\.col).max() ?? -1) + 1
        let fullRowCount = (block.cells.map(\.row).max() ?? -1) + 1
        guard colCount > 0, fullRowCount > 0 else {
            return TableGrid(blockRange: blockRange, interiorEdges: [], totalWidth: 0)
        }

        var cell = Array(repeating: Array(repeating: NSRange(location: blockRange.location, length: 0),
                                          count: colCount), count: fullRowCount)
        var align = [String](repeating: "None", count: colCount)
        for c in block.cells where c.row < fullRowCount && c.col < colCount {
            let (lo, hi) = c.range.utf16Bounds(map: map, clampedTo: total)
            cell[c.row][c.col] = NSRange(location: lo, length: max(0, hi - lo))
            align[c.col] = c.align   // per-column (every cell in the column shares the delimiter alignment)
        }

        // 2) Drop trailing "phantom" rows. A paragraph line directly under a table (no blank line between)
        //    is folded by the GFM parser into the SAME table block as extra cell-rows whose source line has
        //    NO pipe (e.g. a following line "para here" → a row c0="para here", c1=""). Left in, it stretches
        //    a column to the paragraph's width and draws the card + grid straight through the prose. A real
        //    GFM row always has pipes on its source line, so keep only the leading run of pipe-bearing rows
        //    and shrink the styled/drawn range to that last real row's line — the trailing paragraph then
        //    renders as ordinary body text below the table.
        var rowCount = fullRowCount
        while rowCount > 1, !lineHasPipe(ns, rowProbe(cell, rowCount - 1, total)) {
            rowCount -= 1
        }
        var tableRange = blockRange
        if rowCount < fullRowCount {
            let lastLine = ns.lineRange(for: rowProbe(cell, rowCount - 1, total))
            let end = min(lastLine.location + lastLine.length, blockRange.location + blockRange.length)
            if end > blockRange.location {
                tableRange = NSRange(location: blockRange.location, length: end - blockRange.location)
            }
        }
        let bHi = tableRange.location + tableRange.length

        // 3) Mono font + tidy paragraph style across the (real) table range. Equal-width digits/Latin plus
        //    the per-cell kern below give straight columns; the engine's inline runs are re-asserted on top.
        let mono = NSFont.monospacedSystemFont(ofSize: tableFontSize, weight: .regular)
        storage.addAttribute(.paragraphStyle, value: tableParagraphStyle, range: tableRange)
        storage.addAttribute(.font, value: mono, range: tableRange)

        // Re-assert inline emphasis on top of the mono base (setting one .font over the block wiped the
        // base pass's bold/italic). Inline code/link keep their colour/background from the base pass.
        let fm = NSFontManager.shared
        for inline in block.inlines {
            let (ilo, ihi) = inline.range.utf16Bounds(map: map, clampedTo: total)
            guard ihi > ilo, ilo >= tableRange.location, ihi <= bHi else { continue }
            let bold = inline.marks.contains("Strong"), italic = inline.marks.contains("Emphasis")
            guard bold || italic else { continue }
            var f = mono
            if bold { f = fm.convert(f, toHaveTrait: .boldFontMask) }
            if italic { f = fm.convert(f, toHaveTrait: .italicFontMask) }
            storage.addAttribute(.font, value: f, range: NSRange(location: ilo, length: ihi - ilo))
        }

        // 4) Column widths: the widest VISIBLE cell per column, plus a uniform gap so content never kisses
        //    a rule. Width is measured (CTLine typographic bounds) so it matches what the layout lays out.
        var width = Array(repeating: [CGFloat](repeating: 0, count: colCount), count: rowCount)
        var colSlot = [CGFloat](repeating: 0, count: colCount)
        for r in 0 ..< rowCount {
            for c in 0 ..< colCount {
                let w = visibleWidth(cell[r][c], storage: storage, hidden: hidden)
                width[r][c] = w
                colSlot[c] = max(colSlot[c], w)
            }
        }
        let gap = (" " as NSString).size(withAttributes: [.font: mono]).width   // one mono space of breathing room
        for c in 0 ..< colCount { colSlot[c] += gap }

        // 5) Pad each cell to its column width via `.kern`, distributed by the column's alignment so the
        //    separators land at one x per column. Left/None → pad after the last char; right → after the
        //    first char (pushes content right); center → split. Empty (padded short-row) cells are skipped.
        for r in 0 ..< rowCount {
            for c in 0 ..< colCount {
                let range = cell[r][c]
                guard range.length > 0 else { continue }
                let extra = colSlot[c] - width[r][c]
                guard extra > 0.5 else { continue }
                let first = NSRange(location: range.location, length: 1)
                let last = NSRange(location: range.location + range.length - 1, length: 1)
                switch align[c] {
                case "Right":
                    storage.addAttribute(.kern, value: extra, range: first)
                case "Center" where range.length > 1:
                    storage.addAttribute(.kern, value: extra / 2, range: first)
                    storage.addAttribute(.kern, value: extra / 2, range: last)
                default:   // None / Left (and single-char Center): pad trailing
                    storage.addAttribute(.kern, value: extra, range: last)
                }
            }
        }

        // 6) Interior column-rule offsets + total width, from the table's left text edge. A separator `|`
        //    (rendered as a space of width `gap`) sits between consecutive columns; OUTER leading/trailing
        //    `|` (when present, the common GFM shape) shift/extend the table by one space each. The view
        //    anchors the rules and the card to the probed left edge.
        let hasLeadingPipe = tableRange.location < total && ns.character(at: tableRange.location) == 124  // |
        let hasTrailingPipe = lastContentChar(ns, tableRange) == 124
        var edges: [CGFloat] = []
        var x: CGFloat = hasLeadingPipe ? gap : 0   // left edge of cell 0's slot
        for c in 0 ..< colCount {
            x += colSlot[c]                          // cell c spans up to here
            if c < colCount - 1 {
                edges.append(x + gap / 2)            // rule at the centre of the separator's space
                x += gap
            }
        }
        let totalWidth = x + (hasTrailingPipe ? gap : 0)
        return TableGrid(blockRange: tableRange, interiorEdges: edges, totalWidth: totalWidth)
    }

    /// A zero-length probe range at the start of row `r`'s first cell (clamped in-bounds) — used to ask,
    /// via `lineHasPipe`, which source line that row sits on.
    private static func rowProbe(_ cell: [[NSRange]], _ r: Int, _ total: Int) -> NSRange {
        NSRange(location: min(max(0, cell[r][0].location), total), length: 0)
    }

    /// True if the source LINE containing `probe` has a `|` — i.e. it's a genuine GFM table row, not a
    /// paragraph the parser lazily folded into the table block (those have no pipe on their line).
    private static func lineHasPipe(_ ns: NSString, _ probe: NSRange) -> Bool {
        let line = ns.lineRange(for: probe)
        return ns.range(of: "|", options: [], range: line).location != NSNotFound
    }

    /// The last non-whitespace character code in `range` (skipping trailing spaces/tabs/newlines), or 0
    /// if none — used to detect a GFM table's trailing outer `|`.
    private static func lastContentChar(_ ns: NSString, _ range: NSRange) -> unichar {
        var i = range.location + range.length - 1
        while i >= range.location {
            let ch = ns.character(at: i)
            if ch != 32 && ch != 9 && ch != 10 && ch != 13 { return ch }
            i -= 1
        }
        return 0
    }

    /// The laid-out width of `range`'s VISIBLE glyphs (skipping any in `hidden`), via CoreText typographic
    /// bounds on the styled substring — so it equals what `NSLayoutManager` advances when laying the cell
    /// out (the basis for kerning each cell to its column width). Returns 0 for an empty/all-hidden range.
    private static func visibleWidth(_ range: NSRange, storage: NSTextStorage, hidden: Set<Int>) -> CGFloat {
        guard range.length > 0 else { return 0 }
        let sub = storage.attributedSubstring(from: range)
        var anyHidden = false
        for i in range.location ..< (range.location + range.length) where hidden.contains(i) {
            anyHidden = true; break
        }
        let measured: NSAttributedString
        if anyHidden {
            // Drop the hidden marker chars so a cell with inline `code`/**bold** measures only the visible
            // text (the layout draws those markers zero-width).
            let vis = NSMutableAttributedString()
            for k in 0 ..< range.length where !hidden.contains(range.location + k) {
                vis.append(sub.attributedSubstring(from: NSRange(location: k, length: 1)))
            }
            measured = vis
        } else {
            measured = sub
        }
        guard measured.length > 0 else { return 0 }
        let line = CTLineCreateWithAttributedString(measured)
        return CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
    }

    // MARK: - metrics

    /// Table mono size — matches the inline-code shrink (0.92em of the 16pt body), so a table reads at the
    /// same weight as inline code, a touch smaller than body text. Renders at 1× zoom (this file has no
    /// access to the per-window `zoomFactor`); the measurement + grid offsets are all at this size.
    private static let tableFontSize: CGFloat = 16 * 0.92

    /// A tidy paragraph style for the table block: a small left inset (so it sits off the margin inside
    /// its card, matching code blocks). NOTE: no `lineHeightMultiple` — each row's vertical breathing room
    /// comes from the layout delegate (`shouldSetLineFragmentRect`), which pads each table row top and
    /// bottom and centers the text, so cells aren't cramped against the row rules.
    private static let tableParagraphStyle: NSParagraphStyle = {
        let p = NSMutableParagraphStyle()
        p.firstLineHeadIndent = 12
        p.headIndent = 12
        return p
    }()
}
