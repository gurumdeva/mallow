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
    /// When the table OVERFLOWS the window (the last column wraps), this is the available width instead,
    /// so the card fills to the container's right edge rather than to the (off-screen) laid-out width.
    let totalWidth: CGFloat
    /// UTF-16 line-start index of each CONTENT row after the first (header) — i.e. the top of every row
    /// that should get a horizontal separator rule. Anchoring the rules to source-row starts (not to every
    /// line fragment) means a wrapped row spanning several fragments still gets exactly ONE rule at its top.
    let rowStartChars: [Int]
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
    ///   - availableWidth: usable text width for the table (container width minus paddings and the table
    ///              inset). When the laid-out table is wider than this, the LAST column wraps via a hanging
    ///              indent (the row grows taller) instead of overflowing the window. Pass a large value to
    ///              force the never-wrap (fits) path.
    @discardableResult
    static func style(_ block: PBlock, map: [Int], storage: NSTextStorage, hidden: Set<Int>,
                      availableWidth: CGFloat) -> TableGrid? {
        let ns = storage.string as NSString
        let total = ns.length
        guard let blockRange = block.range.utf16Range(map: map, clampedTo: total) else { return nil }

        // 1) Build the cell grid from the engine's cells (UTF-16). Each row has the header's column count
        //    (the engine pads short rows with empty cells), so this is a rectangular [row][col] table.
        let colCount = (block.cells.map(\.col).max() ?? -1) + 1
        let fullRowCount = (block.cells.map(\.row).max() ?? -1) + 1
        guard colCount > 0, fullRowCount > 0 else {
            return TableGrid(blockRange: blockRange, interiorEdges: [], totalWidth: 0, rowStartChars: [])
        }

        var cell = Array(repeating: Array(repeating: NSRange(location: blockRange.location, length: 0),
                                          count: colCount), count: fullRowCount)
        var align = [String](repeating: "None", count: colCount)
        for c in block.cells where c.row < fullRowCount && c.col < colCount {
            let (lo, hi) = c.range.utf16Bounds(map: map, clampedTo: total)
            // TRIM surrounding spaces/tabs off the engine's cell range. The engine is not consistent about
            // whether a cell range includes its padding spaces (varies row to row); untrimmed, a row whose
            // range ate a space measures one space wider than its actual content, its kern comes out one
            // space smaller, and that row's next column starts ~4pt off the others — a visible per-row
            // wobble. Trimmed, width/kern/separators all speak about pure content for every row.
            var tlo = lo, thi = hi
            while tlo < thi, ns.character(at: tlo) == 32 || ns.character(at: tlo) == 9 { tlo += 1 }
            while thi > tlo, ns.character(at: thi - 1) == 32 || ns.character(at: thi - 1) == 9 { thi -= 1 }
            cell[c.row][c.col] = NSRange(location: tlo, length: max(0, thi - tlo))
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

        // 3) Layout runs through local helpers (`measure` / `separators` / `geometry`) at the one body size —
        //    tables never scale; a table too wide to fit SCROLLS or wraps its last column (see step 5).
        let fm = NSFontManager.shared

        // `measure(at:)` — set the PROPORTIONAL body font (sans, NOT monospace) at `size` as the table base,
        // re-assert inline bold/italic on top (a single .font over the block wipes them), then measure each
        // column's widest VISIBLE cell plus a uniform gap. The columns are straightened by this measure +
        // per-cell `.kern`, so a fixed-width face was never what aligned them; sans just reads far better for
        // prose (especially Korean) and matches the body text.
        func measure(at size: CGFloat) -> (width: [[CGFloat]], colSlot: [CGFloat]) {
            let base = NSFont.systemFont(ofSize: size, weight: .regular)
            storage.addAttribute(.font, value: base, range: tableRange)
            for inline in block.inlines {
                let (ilo, ihi) = inline.range.utf16Bounds(map: map, clampedTo: total)
                guard ihi > ilo, ilo >= tableRange.location, ihi <= bHi else { continue }
                let bold = inline.marks.contains("Strong"), italic = inline.marks.contains("Emphasis")
                guard bold || italic else { continue }
                var f = base
                if bold { f = fm.convert(f, toHaveTrait: .boldFontMask) }
                if italic { f = fm.convert(f, toHaveTrait: .italicFontMask) }
                storage.addAttribute(.font, value: f, range: NSRange(location: ilo, length: ihi - ilo))
            }
            var width = Array(repeating: [CGFloat](repeating: 0, count: colCount), count: rowCount)
            var colSlot = [CGFloat](repeating: 0, count: colCount)
            for r in 0 ..< rowCount {
                for c in 0 ..< colCount {
                    let w = visibleWidth(cell[r][c], storage: storage, hidden: hidden)
                    width[r][c] = w
                    colSlot[c] = max(colSlot[c], w)
                }
            }
            // Slots carry CONTENT ONLY (widest visible cell). Inter-column breathing room is added later
            // (`slotPad`, symmetric) and centred on each rule using the REAL source separator widths
            // (`separators()`) — a fixed `gap` estimate drifts off the laid-out glyphs (the pipe/space
            // advances accumulate), which is what left text kissing the rules.
            return (width, colSlot)
        }

        // `separators` — the rendered widths of the source runs BETWEEN cells, and the outer `| `…` |`, taken
        // from row 0. Each `|` is measured as a space (the table glyph substitution advances it as one), so a
        // rule can be centred in the ACTUAL gap between two columns. Every row shares one column model (cells
        // are kerned to `colSlot`), so row 0's separators position the rules for all rows; `lead`/`trail`
        // double as the card's left/right inner padding.
        func separators() -> (lead: CGFloat, sep: [CGFloat], trail: CGFloat) {
            let line = ns.lineRange(for: NSRange(location: min(cell[0][0].location, total), length: 0))
            var trailEnd = line.location + line.length
            while trailEnd > line.location {   // exclude the row's trailing newline(s) from the trailing pad
                let ch = ns.character(at: trailEnd - 1)
                if ch == 10 || ch == 13 { trailEnd -= 1 } else { break }
            }
            let lead = spanWidth(line.location, cell[0][0].location, storage: storage, hidden: hidden)
            var sep = [CGFloat](repeating: 0, count: max(0, colCount - 1))
            for c in 0 ..< max(0, colCount - 1) {
                let lo = cell[0][c].location + cell[0][c].length
                sep[c] = spanWidth(lo, max(lo, cell[0][c + 1].location), storage: storage, hidden: hidden)
            }
            let last = cell[0][colCount - 1]
            let trail = spanWidth(min(last.location + last.length, trailEnd), trailEnd,
                                  storage: storage, hidden: hidden)
            return (lead, sep, trail)
        }

        // `geometry` — interior column-rule offsets, the LAST column's left edge, and the laid-out width, all
        // from the table's left text edge. Columns carry content + a `slotPad` of trailing room; the measured
        // source separators sit between them. Each rule is placed so BOTH neighbouring cells get equal padding
        // of `(sep + slotPad)/2` (the widest cell's content ends `slotPad` before its slot end, so the rule
        // offset `(sep − slotPad)/2` from the slot end centres it in the visual gap).
        func geometry(_ colSlot: [CGFloat], _ s: (lead: CGFloat, sep: [CGFloat], trail: CGFloat))
            -> (edges: [CGFloat], lastColLeftX: CGFloat, laidOutWidth: CGFloat) {
            var edges: [CGFloat] = []
            var x = s.lead                                   // cell 0's content starts one leading `| ` in
            var lastColLeftX = x
            for c in 0 ..< colCount {
                if c == colCount - 1 { lastColLeftX = x }    // last column begins here (before its own slot)
                x += colSlot[c]                              // cell c's slot spans up to here
                if c < colCount - 1 {
                    edges.append(x + (s.sep[c] - slotPad) / 2)   // rule centred → equal padding on both sides
                    x += s.sep[c]
                }
            }
            return (edges, lastColLeftX, x + s.trail)
        }

        // 4) Measure + lay out ONCE at the body size. Tables never scale — every table in a document reads at
        //    the same 15pt (a table too wide to fit SCROLLS, it doesn't shrink), so sizes can't look "제각각".
        let (width, colSlotRaw) = measure(at: tableFontSize)
        var colSlot = colSlotRaw
        // Symmetric breathing room: give every column but the last a `slotPad` of trailing room (the last
        // column's right side is the card's inner edge, handled by `trail`). Combined with centred rules
        // (see `geometry`) this yields even padding on both sides of every rule.
        for c in 0 ..< max(0, colCount - 1) { colSlot[c] += slotPad }
        let sep = separators()
        let (edges, lastColLeftX, laidOutWidth) = geometry(colSlot, sep)

        // 5) Decide how the table meets the viewport — all at full size (see the file-header decision tree):
        //      fits                          → plain, no wrap  (byte-identical to a narrow table today)
        //      overflows, last col has room  → WRAP the last column inside the viewport (the row grows taller)
        //      overflows, non-last too wide  → keep natural width; the editor SCROLLS horizontally
        //    `slot` is the last column's laid width when wrapping; `minLast`/`lastCap` keep a wrap neither
        //    uselessly narrow nor absurdly wide. `availableWidth` is the viewport room for `laidOutWidth`.
        let lastNatural = colSlot[colCount - 1]
        let remainder = availableWidth - lastColLeftX        // viewport room to the right of the last column's left edge
        let wrapLast: Bool
        let slot: CGFloat
        if colCount < 2 || availableWidth <= 0 || laidOutWidth <= availableWidth {
            wrapLast = false; slot = lastNatural                          // fits — no wrap, no scroll
        } else if remainder >= minLast {
            wrapLast = true;  slot = min(lastNatural, remainder)          // wrap the last column within the viewport
        } else {
            wrapLast = lastNatural > lastCap                              // non-last cols exceed viewport → horizontal scroll;
            slot = min(lastNatural, lastCap)                             // cap a giant last cell so it wraps rather than sprawls
        }

        // 6) Paragraph style: the 12pt inset; and when the last column wraps, a hanging `headIndent` to its
        //    left edge PLUS an absolute `tailIndent` at its right edge — so it wraps INSIDE its own column
        //    (bounded), the row grows taller, and the wrap edge is explicit state, not "wherever the container
        //    happens to end" (which drifts on resize). Ordinary text layout — selection / ⌘F / focus / editing
        //    are unaffected; the source bytes are untouched.
        let para = NSMutableParagraphStyle()
        para.firstLineHeadIndent = tableInset
        para.headIndent = wrapLast ? tableInset + lastColLeftX : tableInset
        para.tailIndent = wrapLast ? tableInset + lastColLeftX + slot : 0
        // Breathing room BETWEEN the wrapped lines of a tall cell. `lineSpacing` adds gap only between lines
        // of the SAME paragraph, so a single-line row is untouched (its height still comes purely from the
        // layout delegate's ±6pt row pad) — only a wrapped multi-line cell opens up.
        para.lineSpacing = 5
        storage.addAttribute(.paragraphStyle, value: para, range: tableRange)

        // 8) Pad each cell to its column width via `.kern`, distributed by the column's alignment so the
        //    separators land at one x per column. Left/None → pad after the last char; right → after the
        //    first char (pushes content right); center → split. Empty (padded short-row) cells are skipped.
        //    When wrapping, the LAST column is skipped (left un-kerned) so it can flow + wrap; its hanging
        //    indent + tailIndent (step 6) bound the continuation lines to its column.
        for r in 0 ..< rowCount {
            for c in 0 ..< colCount {
                if wrapLast && c == colCount - 1 { continue }
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

        // 9) Row-start char indices (header excluded) for the grid's horizontal rules — anchored to SOURCE
        //    rows so a wrapped row that spans several line fragments still gets exactly ONE rule at its top.
        var rowStartChars: [Int] = []
        for r in 1 ..< rowCount {
            rowStartChars.append(ns.lineRange(for: NSRange(location: cell[r][0].location, length: 0)).location)
        }

        // Card width = the table's TRUE laid-out width so the card EXACTLY bounds the table at any width — a
        // wrapped last column contributes its bounded `slot`, otherwise the natural laid width. (No more
        // clamping to availableWidth, which detached the card from a shrunk/wrapped table.)
        let totalWidth = wrapLast ? (lastColLeftX + slot) : laidOutWidth   // wrap: right edge = the tailIndent (bounded slot)
        return TableGrid(blockRange: tableRange, interiorEdges: edges,
                         totalWidth: totalWidth, rowStartChars: rowStartChars)
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

    /// The rendered width of source characters `[lo, hi)` as the layout advances them: each table `|` is
    /// measured as a SPACE (the glyph substitution draws it as one), and any `hidden` marker char drops to
    /// zero width. Used to measure the real inter-cell separators so a grid rule can sit at the true centre
    /// of the gap between two columns (a fixed estimate drifts off the glyphs).
    private static func spanWidth(_ lo: Int, _ hi: Int, storage: NSTextStorage, hidden: Set<Int>) -> CGFloat {
        guard hi > lo else { return 0 }
        let sub = storage.attributedSubstring(from: NSRange(location: lo, length: hi - lo))
        let out = NSMutableAttributedString()
        for k in 0 ..< (hi - lo) where !hidden.contains(lo + k) {
            let piece = sub.attributedSubstring(from: NSRange(location: k, length: 1))
            if piece.string == "|", piece.length > 0 {
                out.append(NSAttributedString(string: " ",
                                              attributes: piece.attributes(at: 0, effectiveRange: nil)))
            } else {
                out.append(piece)
            }
        }
        guard out.length > 0 else { return 0 }
        return CGFloat(CTLineGetTypographicBounds(CTLineCreateWithAttributedString(out), nil, nil, nil))
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

    /// Table text size — the proportional body font at a hair under body size (15 vs 16pt), so a table reads
    /// like the surrounding prose but stays a touch denser. Renders at 1× zoom (this file has no access to
    /// the per-window `zoomFactor`); the measurement + grid offsets are all at this size.
    private static let tableFontSize: CGFloat = 15

    /// Bounds on a wrapping last column's width (points). Below `minLast` a wrap is too narrow to read, so
    /// the table scrolls horizontally instead; above `lastCap` a single long cell would sprawl, so it wraps.
    private static let minLast: CGFloat = 110
    private static let lastCap: CGFloat = 420

    /// Trailing breathing room (points) added to every non-last column slot. With centred rules (see
    /// `geometry`) each interior rule ends up with `(separator + slotPad)/2` of padding on BOTH sides, so
    /// cell text never kisses a rule. The last column has none (its right side is the card's inner edge).
    private static let slotPad: CGFloat = 6

    /// The table block's left inset (points): the table sits this far off the margin inside its card,
    /// matching code blocks. Applied as each row paragraph's `firstLineHeadIndent`; when a long LAST column
    /// wraps, the hanging `headIndent` is this inset plus that column's left edge (so wrapped lines align
    /// under their column). Internal so the Restyler can subtract it when computing the table's available
    /// width. NOTE: no `lineHeightMultiple` — each row's vertical breathing room comes from the layout
    /// delegate (`shouldSetLineFragmentRect`), which pads each table row top and bottom and centers the text.
    static let tableInset: CGFloat = 12
}
