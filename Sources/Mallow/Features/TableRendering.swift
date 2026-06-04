// TableRendering — a pragmatic, markdown-as-truth treatment for GFM tables.
//
// The engine emits a GFM table as ONE block (`kindTag == "Table"`) with a byte `range` spanning the
// whole table and `inlines` carrying the cell text runs (with marks) — but NO cell/column structure.
// A real NSTextTable grid would require restructuring the buffer (splitting the pipe text into table
// cells), which a markdown-as-truth editor must not do: the source stays the source. So instead of
// rewriting bytes we make the raw pipe table *read* as a structured, aligned block:
//
//   • a monospace font across the block, so equal-width glyphs line the `|` columns up (best-effort —
//     CJK / emoji are wider than one cell, so alignment is "good enough", not pixel-perfect),
//   • a tidy paragraph style (small left inset, tight leading) so it sits as a quiet block,
//   • a subtle elevated background card behind it (returned as an NSRange for the text view to draw),
//   • the pipe `|` bars rendered as spaces and the `|---|` delimiter row collapsed — so the raw table
//     markers never show (the no-visible-markers rule), while the source bytes stay untouched. That hide
//     work lives in EditorViewModel.recomputeHidden (it owns the glyph/hidden sets), NOT here.
//
// FOLLOW-UP (noted): a true aligned grid — real column widths, cell borders, per-column alignment —
// needs the engine to emit cell ranges (row/col spans) on the Table block. With only the block range +
// flat inlines available today, column structure can only be recovered by re-parsing the pipe text in
// Swift (as below), which is fragile for escaped `\|`, code-span pipes, etc. Once Inkstone exposes cell
// ranges, this can graduate to an NSTextTable / custom layout without touching the buffer.
//
// Self-contained: `TableRendering.style(_:source:storage:)` applies the font + dim attributes directly
// to the passed `NSTextStorage` and returns the block's NSRange (for the background card). It only ever
// touches the table block's own UTF-16 range and runs AFTER the base attributes in restyle(), so it
// layers on top of (does not erase) the inline styling the engine produced for the cell text.

import AppKit

enum TableRendering {

    /// Style one `kindTag == "Table"` block. Applies a monospace font + tidy paragraph style across the
    /// block, dims the pipes and the separator row, and returns the block's NSRange so the caller can
    /// append it to the text view's table-card decoration list. Returns nil if the block range is empty
    /// or out of bounds (nothing to style / draw).
    ///
    /// - Parameters:
    ///   - block:   the Table PBlock (its `range` is a source BYTE range).
    ///   - map:     the byte→UTF-16 lookup (`byteToUTF16Map`) restyle built once — O(1) range conversion
    ///              (the old O(offset) `utf16Range(in:)` here made a table-heavy doc's load O(n²)).
    ///   - storage: the text storage to mutate (the same `textView.textStorage` restyle() edits).
    /// - Returns: the block's UTF-16 NSRange for the background card, or nil when there's nothing to draw.
    @discardableResult
    static func style(_ block: PBlock, map: [Int], storage: NSTextStorage) -> NSRange? {
        let ns = storage.string as NSString
        let total = ns.length

        // Block range, byte → UTF-16 via the prebuilt map (O(1)), clamped to the storage.
        guard let blockRange = block.range.utf16Range(map: map, clampedTo: total) else { return nil }

        // 1) Monospace + a tidy paragraph style across the whole table block. Equal-width glyphs make the
        //    `|` columns line up (best-effort). This is applied as a block attribute; the engine's inline
        //    runs (bold/italic/code/links in cells) still sit on top because restyle() set them first and
        //    we only change .font/.paragraphStyle here — but to keep cell emphasis we re-bold/-italicise
        //    per inline run below rather than flattening every cell to plain mono.
        let mono = NSFont.monospacedSystemFont(ofSize: tableFontSize, weight: .regular)
        storage.addAttribute(.paragraphStyle, value: tableParagraphStyle, range: blockRange)
        storage.addAttribute(.font, value: mono, range: blockRange)

        // Re-assert inline emphasis on top of the mono base: setting one .font over the block above wiped
        // the bold/italic the base pass gave cell runs, so reapply a bold/italic MONO variant for those
        // runs. (Inline code / links keep their colour + background from the base pass — we didn't touch
        // those attributes.) Skips runs outside the block (defensive; the engine nests them inside).
        let fm = NSFontManager.shared
        for inline in block.inlines {
            let (ilo, ihi) = inline.range.utf16Bounds(map: map, clampedTo: total)
            guard ihi > ilo, ilo >= blockRange.location, ihi <= blockRange.location + blockRange.length else { continue }
            let bold = inline.marks.contains("Strong")
            let italic = inline.marks.contains("Emphasis")
            guard bold || italic else { continue }   // plain cell text already has the mono base
            var f = mono
            if bold { f = fm.convert(f, toHaveTrait: .boldFontMask) }
            if italic { f = fm.convert(f, toHaveTrait: .italicFontMask) }
            storage.addAttribute(.font, value: f, range: NSRange(location: ilo, length: ihi - ilo))
        }

        // 2) Structure (the `|` bars + the `|---|` delimiter row) is NOT styled here anymore — the
        //    view-model's hide pass renders every `|` as a space and collapses the delimiter row, so the
        //    raw table markers never show (the app's markdown-as-truth-but-no-visible-markers rule).

        // 3) Column alignment: pad each cell to its column's widest cell via `.kern` on the cell's last
        //    char, so the (now-bar-less) `|` separators line up into straight columns and the text view can
        //    rule them. Monospace alone can't align CJK (Hangul glyphs aren't one cell wide). `.kern` is a
        //    display attribute, so the source bytes stay untouched (markdown-as-truth) and editing is normal.
        alignColumns(blockRange, ns: ns, storage: storage)

        // The block's NSRange — the caller appends it to the table-card decoration list (see file footer /
        // integration notes), which MarkdownTextView.drawBackground renders as a subtle elevated card.
        return blockRange
    }

    /// Pad each table cell to its column's widest cell (via `.kern` on the cell's last character) so the
    /// `|` separators line up vertically across rows — the precondition for the text view drawing straight
    /// column rules. Best-effort: handles well-formed `|`-delimited rows (the GFM-with-outer-pipes shape);
    /// escaped `\|` and code-span pipes aren't special-cased (rare). The `|---|` delimiter row is skipped.
    private static func alignColumns(_ blockRange: NSRange, ns: NSString, storage: NSTextStorage) {
        let bHi = blockRange.location + blockRange.length
        // Per row, the cell content ranges (the text BETWEEN consecutive pipes). Delimiter row excluded.
        var rows: [[NSRange]] = []
        var lineStart = blockRange.location
        while lineStart < bHi {
            let line = ns.lineRange(for: NSRange(location: lineStart, length: 0))
            let lineHi = min(line.location + line.length, bHi)
            var pipes: [Int] = []
            var sawDash = false, sawNonSpace = false, onlySeparator = true
            var i = line.location
            while i < lineHi {
                switch ns.character(at: i) {
                case 124: pipes.append(i); sawNonSpace = true          // |
                case 45:  sawDash = true; sawNonSpace = true           // -
                case 58:  sawNonSpace = true                           // :
                case 32, 9, 10, 13: break                              // ws / terminators
                default:  onlySeparator = false; sawNonSpace = true
                }
                i += 1
            }
            let isDelimiter = sawDash && sawNonSpace && onlySeparator
            if !isDelimiter, pipes.count >= 2 {
                var cells: [NSRange] = []
                for k in 0 ..< (pipes.count - 1) {
                    let lo = pipes[k] + 1, hi = pipes[k + 1]
                    cells.append(NSRange(location: lo, length: max(0, hi - lo)))
                }
                rows.append(cells)
            }
            if line.length == 0 { break }
            lineStart = line.location + line.length
        }
        let colCount = rows.map(\.count).max() ?? 0
        guard colCount > 0 else { return }

        // Widest cell per column.
        var colWidth = [CGFloat](repeating: 0, count: colCount)
        var cellWidth: [[CGFloat]] = []
        for cells in rows {
            var ws = [CGFloat](repeating: 0, count: cells.count)
            for (c, range) in cells.enumerated() where c < colCount {
                let w = range.length > 0 ? storage.attributedSubstring(from: range).size().width : 0
                ws[c] = w
                colWidth[c] = max(colWidth[c], w)
            }
            cellWidth.append(ws)
        }
        // Pad each cell to its column width PLUS one space, via kern AFTER the cell's last char: the extra
        // space keeps even the widest cell (whose natural pad is ~0) from touching the right divider, so
        // the gap before the divider ≈ the gap after it (the next cell's `|`-space + leading space).
        let mono = NSFont.monospacedSystemFont(ofSize: tableFontSize, weight: .regular)
        let cellPad = (" " as NSString).size(withAttributes: [.font: mono]).width
        for (r, cells) in rows.enumerated() {
            for (c, range) in cells.enumerated() where c < colCount {
                let pad = colWidth[c] + cellPad - cellWidth[r][c]
                guard pad > 0.5, range.length > 0 else { continue }
                let last = NSRange(location: range.location + range.length - 1, length: 1)
                storage.addAttribute(.kern, value: pad, range: last)
            }
        }
    }

    // MARK: - metrics

    /// Table mono size — matches the inline-code shrink (0.92em of the 16pt body) so a table reads at the
    /// same weight as inline code, a touch smaller than body text. NOTE: this file has no access to the
    /// view-model's per-window `zoomFactor`, so it renders at 1× zoom. If table text should track View ▸
    /// Zoom, thread the zoomed size in via a parameter (follow-up — see integration notes).
    private static let tableFontSize: CGFloat = 16 * 0.92

    /// A tidy paragraph style for the table block: a small left inset (so it sits off the margin inside
    /// its card, matching code blocks) and tighter leading than body text (1.3 vs 1.5) so the grid reads
    /// as a compact unit. Built once. NOTE: no `lineHeightMultiple` — table rows get their vertical
    /// breathing room from the layout delegate (`shouldSetLineFragmentRect`), which pads each row TOP AND
    /// BOTTOM and centers the text, so the cells aren't cramped against the row rules (an airy
    /// `lineHeightMultiple` only adds space ABOVE the glyph, leaving the text low against the bottom rule).
    private static let tableParagraphStyle: NSParagraphStyle = {
        let p = NSMutableParagraphStyle()
        p.firstLineHeadIndent = 12
        p.headIndent = 12
        return p
    }()
}

// MARK: - Integration notes (for the EditorViewModel.restyle / MarkdownTextView lead)
//
// 1. MarkdownTextView — add a new decoration set + draw the card. Mirror `codeCards`:
//
//      var tableCards: [NSRange] = [] { didSet { needsDisplay = true } }
//
//    and inside drawBackground(in:), after the codeCards loop (so tables draw with the same elevated
//    fill but their own list — a table and a code block never share a range, and keeping them separate
//    lets either gain its own look later). EXACT snippet:
//
//      mallowElevated.setFill()
//      for r in tableCards {
//          let gr = lm.glyphRange(forCharacterRange: r, actualCharacterRange: nil)
//          guard gr.length > 0 else { continue }
//          let box = lm.boundingRect(forGlyphRange: gr, in: tc)
//          let card = NSRect(x: origin.x, y: origin.y + box.minY - 2,
//                            width: tc.size.width - 8, height: box.height + 4)
//          NSBezierPath(roundedRect: card, xRadius: 6, yRadius: 6).fill()
//      }
//
//    (Reusing `codeCards` instead would also work and needs no new property — but then a table inherits
//    the literal "code card" semantics. A dedicated set is the cleaner seam; pick one.)
//
// 2. EditorViewModel.restyle() — declare the collector next to the others (near `var codeCards …`):
//
//      var tableCards: [NSRange] = []   // GFM table ranges → subtle elevated card drawn by the text view
//
//    add a `case "Table":` to the block switch (alongside "CodeBlock" / "BlockQuote"); it runs AFTER the
//    base `setAttributes` above it, so TableRendering layers on top of the base attributes:
//
//      case "Table":
//          if let nr = TableRendering.style(block, source: s, storage: storage) {
//              tableCards.append(nr)
//          }
//          continue   // the cell font/dim is fully handled inside TableRendering — skip the generic
//                     // inline pass (it would re-flatten the mono/bold work we just did)
//
//    and after `storage.endEditing()`, hand the ranges to the view next to the existing handoffs:
//
//      textView.tableCards = tableCards
//
// 3. recomputeHidden() owns the marker hiding for tables (the glyph/hidden sets live there): it renders
//    each `|` as a space (via `tablePipes` + the glyph delegate) and collapses the `|---|` delimiter row.
//    Table stays absent from `hideable(_:)` — its hiding is that dedicated pass, not the block-gap pass.
