// DecorationRenderer — the PURE geometry behind the editor's block/inline decorations (code-block card,
// GFM table card+grid, blockquote bar, inline-code pill, thematic rule). Extracted from
// `MarkdownTextView.drawBackground` so the geometry — every rect, every rule coordinate — can be computed
// (and headless-tested) without a live drawing context. The painter (`drawBackground`) keeps ONLY the
// color-set + fill/stroke calls; it holds no geometry. This closes the "decoration rects are computable
// only by drawing, so tests must re-derive them" gap in the modifiability review.
//
// All rects/points are returned in VIEW coordinates (the text-container origin is already folded in).
// A renderer is a per-draw value: construct it with the current layout objects, call the geometry
// methods with the view's decoration ranges, then fill/stroke what comes back — in the exact order and
// colors drawBackground used before this extraction (behavior is byte-for-byte preserved).

import AppKit

/// One GFM table's decoration geometry: the rounded card, the y of each horizontal rule (header +
/// row separators, already pixel-snapped and spanning `card.minX…card.maxX`), and the x of each interior
/// column rule (already snapped, filtered to inside the card, spanning `card.minY…card.maxY`).
struct TableDecoration {
    let card: NSRect
    let horizontalRuleYs: [CGFloat]
    let verticalRuleXs: [CGFloat]
}

struct DecorationRenderer {
    let lm: NSLayoutManager
    let tc: NSTextContainer
    let ts: NSTextStorage
    /// The text-container origin in view coordinates (`textView.textContainerOrigin`).
    let origin: CGPoint
    /// Font used when a glyph's own font can't be read (the view's font, else the body system font).
    let fallbackFont: NSFont
    /// Width for decorations that track the WINDOW (code card + thematic rule); the table card ignores it
    /// and owns its own scrolled width. Already clamped to the viewport by the caller.
    let decoWidth: CGFloat

    // MARK: - Vertical anchors (shared by code card / quote bar / inline-code pill)

    /// Vertical anchors (view coords) for a block decoration spanning `cr`, measured from the actual
    /// glyphs — NOT from `boundingRect`, whose full LINE-FRAGMENT rects include the airy
    /// `lineHeightMultiple` leading above each line AND the font's ascent/descent slack. Returns the
    /// first content line's CAP top (the visible letter tops, not the much-higher font ascender), the
    /// last content line's BASELINE, and the last line's descender bottom. Zero-height lines (folded
    /// sections + the hidden ``` fence lines) are skipped, so the top is the first REAL code line.
    func decorationAnchors(forCharacterRange cr: NSRange) -> (capTop: CGFloat, baseline: CGFloat, descBottom: CGFloat)? {
        let gr = lm.glyphRange(forCharacterRange: cr, actualCharacterRange: nil)
        guard gr.length > 0 else { return nil }
        var capTop = CGFloat.greatestFiniteMagnitude
        var lastBaseline = -CGFloat.greatestFiniteMagnitude
        var descBottom = -CGFloat.greatestFiniteMagnitude
        lm.enumerateLineFragments(forGlyphRange: gr) { fragRect, _, _, lineGlyphRange, _ in
            guard fragRect.height > 0 else { return }   // skip folded / collapsed-fence (zero-height) lines
            // Measure from the first glyph that is BOTH inside `cr` AND visible. Two reasons it may not be
            // `gr`'s first glyph: (1) `glyphRange(forCharacterRange:)` snaps a range that starts on a hidden
            // (zero-width) glyph — a blockquote's `>` marker, an inline-code backtick — back to the
            // previous visible glyph, which can be the char (or whole line) BEFORE `cr`; (2) a hidden glyph's
            // `location(forGlyphAt:)` reports the line-fragment TOP as the baseline, not the real text
            // baseline, which would push `capTop` a line-leading above the text. Advancing past both gives
            // the true first-letter baseline, so the bar/pill hugs the text instead of towering above it.
            // Skip glyphs the render model marks invisible (hidden markers + the task-box fallback) —
            // the property choices live in RenderModel so this can't drift from what the delegate sets.
            let lineEnd = lineGlyphRange.location + lineGlyphRange.length
            var g = max(lineGlyphRange.location, gr.location)
            while g < lineEnd {
                guard lm.characterIndexForGlyph(at: g) < cr.location
                    || RenderModel.isInvisible(lm.propertyForGlyph(at: g)) else { break }
                g += 1
            }
            guard g < lineEnd else { return }                              // nothing visible inside cr on this line
            let ci = lm.characterIndexForGlyph(at: g)
            guard ci < cr.location + cr.length else { return }             // first visible glyph is past cr
            let font = (ci < ts.length ? ts.attribute(.font, at: ci, effectiveRange: nil) as? NSFont : nil)
                ?? fallbackFont
            let baseline = fragRect.minY + lm.location(forGlyphAt: g).y   // baseline in container coords
            capTop = min(capTop, baseline - font.capHeight)               // visible letter tops
            if baseline > lastBaseline {
                lastBaseline = baseline
                descBottom = baseline - font.descender                    // descender < 0 → adds |descent|
            }
        }
        guard capTop < lastBaseline else { return nil }   // no measurable content line
        return (capTop, lastBaseline, descBottom)
    }

    // MARK: - Code-block cards

    /// The rounded card behind each code block — the card's vertical padding (cap line → top edge,
    /// baseline → bottom edge) matches the text's horizontal inset, so breathing room is even on all four
    /// sides (`cardPadding` == the code paragraph style's left head-indent). Width tracks the window.
    func codeCardRects(_ ranges: [NSRange]) -> [NSRect] {
        let cardPadding = mallowCodeParagraphStyle.headIndent   // = the 12pt left text inset
        var out: [NSRect] = []
        for r in ranges {
            guard let a = decorationAnchors(forCharacterRange: r) else { continue }
            let top = a.capTop - cardPadding, bottom = a.baseline + cardPadding
            out.append(NSRect(x: origin.x, y: origin.y + top, width: decoWidth - 8, height: bottom - top))
        }
        return out
    }

    // MARK: - GFM table cards + grid rules

    /// Card + grid geometry for each table. The card spans the table's non-collapsed line fragments (the
    /// `|---|` delimiter row is zero-height, so it's skipped). Horizontal rules anchor to SOURCE-row
    /// starts (`grid.rowStartChars`), so a long last column that WRAPS into several fragments still gets
    /// exactly ONE rule at its row's top. Column rules come from `grid.interiorEdges` — x offsets from the
    /// table's left text edge sharing the SAME column-width model the cell kern uses (so rules and text
    /// can't drift), anchored to the table's first glyph (its left edge).
    func tableDecorations(_ grids: [TableGrid]) -> [TableDecoration] {
        var out: [TableDecoration] = []
        for grid in grids {
            let r = grid.blockRange
            let gr = lm.glyphRange(forCharacterRange: r, actualCharacterRange: nil)
            guard gr.length > 0 else { continue }
            var rows: [NSRect] = []
            lm.enumerateLineFragments(forGlyphRange: gr) { frag, _, _, _, _ in
                if frag.height > 0 { rows.append(frag) }   // skip the collapsed delimiter row
            }
            guard let first = rows.first, let last = rows.last else { continue }
            // The table's left edge, probed from its first glyph — anchors the card AND the column rules,
            // so both absorb the container/line insets and share one column model (no drift).
            let leftGlyph = lm.glyphRange(forCharacterRange: NSRange(location: r.location, length: 1),
                                          actualCharacterRange: nil)
            let leftX = origin.x + lm.boundingRect(forGlyphRange: leftGlyph, in: tc).minX
            // Card hugs the table's actual width (not the page width), so a narrow table doesn't trail a
            // wide empty card. Clamp the width so it can't overrun the text container.
            let width = min(grid.totalWidth, tc.size.width - (leftX - origin.x) - 4)
            let card = NSRect(x: leftX, y: origin.y + first.minY, width: width, height: last.maxY - first.minY)
            var hRuleYs: [CGFloat] = []
            for rc in grid.rowStartChars {
                let g = lm.glyphRange(forCharacterRange: NSRange(location: rc, length: 1),
                                      actualCharacterRange: nil)
                guard g.length > 0 else { continue }
                let y = (origin.y + lm.lineFragmentRect(forGlyphAt: g.location, effectiveRange: nil).minY)
                    .rounded() + 0.5
                hRuleYs.append(y)
            }
            var vRuleXs: [CGFloat] = []
            for edge in grid.interiorEdges {   // vertical column rules at the computed interior offsets
                let x = (leftX + edge).rounded() + 0.5
                guard x > card.minX + 1, x < card.maxX - 1 else { continue }
                vRuleXs.append(x)
            }
            out.append(TableDecoration(card: card, horizontalRuleYs: hRuleYs, verticalRuleXs: vRuleXs))
        }
        return out
    }

    // MARK: - Blockquote bars

    /// A 3pt left bar per blockquote, spanning cap line → baseline (the height of the quoted text).
    func quoteBarRects(_ ranges: [NSRange]) -> [NSRect] {
        var out: [NSRect] = []
        for r in ranges {
            guard let a = decorationAnchors(forCharacterRange: r) else { continue }
            out.append(NSRect(x: origin.x + 6, y: origin.y + a.capTop,
                              width: 3, height: max(1, a.baseline - a.capTop)))
        }
        return out
    }

    // MARK: - Inline-code pills

    /// One rounded pill PER line fragment an inline-code run occupies (a wrapped span gets a pill on each
    /// visual line, each hugging its own cap→baseline). 3.5pt horizontal padding is DRAWN, not laid out —
    /// the hidden backticks are zero-width, so the box hugs the text exactly and a drawn pad gives air
    /// without shifting layout.
    func inlineCodePillRects(_ ranges: [NSRange]) -> [NSRect] {
        var out: [NSRect] = []
        for r in ranges {
            let gr = lm.glyphRange(forCharacterRange: r, actualCharacterRange: nil)
            guard gr.length > 0 else { continue }
            lm.enumerateLineFragments(forGlyphRange: gr) { _, _, _, fragGlyphRange, _ in
                let lineGlyphs = NSIntersectionRange(gr, fragGlyphRange)
                guard lineGlyphs.length > 0 else { return }
                let lineChars = lm.characterRange(forGlyphRange: lineGlyphs, actualGlyphRange: nil)
                guard let a = self.decorationAnchors(forCharacterRange: lineChars) else { return }
                let box = lm.boundingRect(forGlyphRange: lineGlyphs, in: tc)
                out.append(NSRect(x: origin.x + box.minX - InlineCodeStyle.pillPadX,
                                  y: origin.y + a.capTop - InlineCodeStyle.pillPadY,
                                  width: box.width + 2 * InlineCodeStyle.pillPadX,
                                  height: (a.baseline - a.capTop) + 2 * InlineCodeStyle.pillPadY))
            }
        }
        return out
    }

    // MARK: - Thematic rules

    /// A 1px hairline centered on each thematic-break line (its source dashes are hidden). Width tracks
    /// the window. Empty when the document has no glyphs yet.
    func ruleLineRects(_ ranges: [NSRange]) -> [NSRect] {
        let glyphCount = lm.numberOfGlyphs
        guard glyphCount > 0 else { return [] }
        var out: [NSRect] = []
        for r in ranges {
            let gi = min(lm.glyphIndexForCharacter(at: r.location), glyphCount - 1)
            var eff = NSRange()
            let line = lm.lineFragmentRect(forGlyphAt: gi, effectiveRange: &eff)
            let y = (origin.y + line.midY).rounded() + 0.5   // crisp 1px hairline
            out.append(NSRect(x: origin.x, y: y, width: decoWidth - 8, height: 1))
        }
        return out
    }
}
