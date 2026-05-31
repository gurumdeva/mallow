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
//   • the pipe `|` characters and the whole header-separator row (`---|:--:|`) dimmed — de-emphasised,
//     NOT hidden (markdown-as-truth keeps every byte visible & editable).
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
    ///   - source:  the full document string (`textView.string`) — the indexing base for byteToUTF16.
    ///   - storage: the text storage to mutate (the same `textView.textStorage` restyle() edits).
    /// - Returns: the block's UTF-16 NSRange for the background card, or nil when there's nothing to draw.
    @discardableResult
    static func style(_ block: PBlock, source: String, storage: NSTextStorage) -> NSRange? {
        let ns = storage.string as NSString
        let total = ns.length

        // Block range, byte → UTF-16, clamped to the storage. (byteToUTF16 indexes `source`; storage and
        // source are the same buffer in restyle(), so the offsets line up.)
        let lo = byteToUTF16(source, block.range.start)
        let hi = min(byteToUTF16(source, block.range.end), total)
        guard hi > lo else { return nil }
        let blockRange = NSRange(location: lo, length: hi - lo)

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
            let ilo = byteToUTF16(source, inline.range.start)
            let ihi = min(byteToUTF16(source, inline.range.end), total)
            guard ihi > ilo, ilo >= lo, ihi <= hi else { continue }
            let bold = inline.marks.contains("Strong")
            let italic = inline.marks.contains("Emphasis")
            guard bold || italic else { continue }   // plain cell text already has the mono base
            var f = mono
            if bold { f = fm.convert(f, toHaveTrait: .boldFontMask) }
            if italic { f = fm.convert(f, toHaveTrait: .italicFontMask) }
            storage.addAttribute(.font, value: f, range: NSRange(location: ilo, length: ihi - ilo))
        }

        // 2) Dim the structure: every pipe `|`, and the whole header-separator row, get a quiet
        //    foreground. Parsed from the source substring purely in Swift (the model has no cell info).
        dimStructure(blockRange: blockRange, source: source, ns: ns, storage: storage)

        // The block's NSRange — the caller appends it to the table-card decoration list (see file footer /
        // integration notes), which MarkdownTextView.drawBackground renders as a subtle elevated card.
        return blockRange
    }

    // MARK: - structure dimming (pipes + separator row), parsed from the source substring

    /// Apply `mallowDim` to every `|` and to the entire separator row inside `blockRange`. Walks the
    /// block line-by-line over the NSString (UTF-16 indices, so it composes with the engine's offsets),
    /// identifying the separator row by its shape (only `|`, `-`, `:`, and spaces, and at least one `-`).
    private static func dimStructure(blockRange: NSRange, source: String, ns: NSString, storage: NSTextStorage) {
        let blockEnd = blockRange.location + blockRange.length
        var lineStart = blockRange.location
        var lineIndex = 0
        while lineStart < blockEnd {
            let line = ns.lineRange(for: NSRange(location: lineStart, length: 0))
            let lineEnd = min(line.location + line.length, blockEnd)

            // Classify this row by scanning its chars once: collect pipe positions and test whether the
            // row is a separator (GFM: the 2nd row, made only of | - : and whitespace, with ≥1 dash).
            var pipePositions: [Int] = []
            var sawDash = false
            var sawOnlySeparatorChars = true
            var sawNonSpace = false
            var i = line.location
            while i < lineEnd {
                let c = ns.character(at: i)
                switch c {
                case 124: // '|'
                    pipePositions.append(i)
                    sawNonSpace = true
                case 45:  // '-'
                    sawDash = true
                    sawNonSpace = true
                case 58:  // ':'
                    sawNonSpace = true
                case 32, 9: // space / tab
                    break
                case 10, 13: // newline / CR (line terminator — ignore)
                    break
                default:
                    sawOnlySeparatorChars = false
                    sawNonSpace = true
                }
                i += 1
            }

            // The separator row: dim the whole row (its source is pure structure, e.g. `|---|:--:|`).
            // Guarded to the 2nd line of the block (GFM requires the delimiter row directly under the
            // header) AND the shape test, so a body cell that happens to hold only dashes isn't dimmed.
            let isSeparatorRow = lineIndex == 1 && sawDash && sawNonSpace && sawOnlySeparatorChars
            if isSeparatorRow, lineEnd > line.location {
                storage.addAttribute(.foregroundColor, value: mallowDim,
                                     range: NSRange(location: line.location, length: lineEnd - line.location))
            } else {
                // Otherwise just dim the individual pipe glyphs so the column rules stay quiet while the
                // cell text keeps its normal colour.
                for p in pipePositions {
                    storage.addAttribute(.foregroundColor, value: mallowDim,
                                         range: NSRange(location: p, length: 1))
                }
            }

            if line.length == 0 { break }   // guard against a zero-length final line looping forever
            lineStart = line.location + line.length
            lineIndex += 1
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
    /// as a compact unit. Built once.
    private static let tableParagraphStyle: NSParagraphStyle = {
        let p = NSMutableParagraphStyle()
        p.lineHeightMultiple = 1.3
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
// 3. recomputeHidden() / hideable() — NO change needed. Markdown-as-truth keeps the pipes visible; we
//    only de-emphasise them (dim foreground), we do not collapse them. Table is intentionally absent
//    from `hideable(_:)`, which is correct — leave it out.
