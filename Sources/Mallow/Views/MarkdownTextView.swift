// MarkdownTextView — the editing surface (View layer). A bare NSTextView subclass plus the shared
// configuration: markdown-as-truth means every "smart" auto-substitution is OFF (they would rewrite
// the bytes the parser reads), the native find bar is on, and the geometry matches Mallow.

import AppKit
import UniformTypeIdentifiers

final class MarkdownTextView: NSTextView {
    // Decoration ranges the view-model recomputes each refresh (UTF-16). Blockquote ranges get a 3px
    // left bar; thematic-break ranges get a 1px horizontal rule (their source dashes are hidden), the
    // two block decorations NSTextView can't express as text attributes. Redraw when they change.
    var codeCards: [NSRange] = [] { didSet { needsDisplay = true } }
    var tableGrids: [TableGrid] = [] { didSet { needsDisplay = true } }   // GFM tables → card + aligned grid
    var quoteBars: [NSRange] = [] { didSet { needsDisplay = true } }
    var ruleLines: [NSRange] = [] { didSet { needsDisplay = true } }
    var inlineCodeRuns: [NSRange] = [] { didSet { needsDisplay = true } }   // `code` spans → rounded pill

    // Defeat "Add period with double-space" — a global text-input default (NSAutomaticPeriodSubstitution-
    // Enabled) with no per-view or app-domain override. On the 2nd space the system calls
    // insertText(". ", replacing the just-typed space at {loc,1}); that inserts a "." the user never
    // typed, which is wrong for a markdown-as-truth editor. When we see that exact shape, keep the
    // literal double space instead. (Manually typed "." comes in as "." with no replacement, so this
    // guard is specific to the substitution and never touches real periods.)
    override func insertText(_ string: Any, replacementRange: NSRange) {
        // Smart typography (our rule-based port; the OS substitutions stay OFF). Fires only for a single
        // typed trigger char (" ' - .); the multi-char glyphs (… – —) consume the already-typed
        // preceding chars by widening the replacement range backward.
        if let s = (string as? String) ?? (string as? NSAttributedString)?.string {
            let loc = replacementRange.location == NSNotFound ? selectedRange().location : replacementRange.location
            if let replacement = SmartTypography.substitution(for: s, in: self.string, at: loc) {
                let extra: Int
                switch replacement {
                case "\u{2026}": extra = 2                 // … consumed ".."
                case "\u{2013}", "\u{2014}": extra = 1     // – / — consumed one preceding hyphen / en-dash
                default: extra = 0                          // “ ” ‘ ’
                }
                // Typing over a non-empty selection must still REPLACE it. For a plain quote (extra == 0)
                // keep the original `replacementRange` (NSNotFound when typed → AppKit replaces the
                // selection with the curly quote); inserting at a length-0 range would leave the selected
                // text in place and just prepend the quote. The backward-consuming glyphs (… – —) only make
                // sense mid-word, so with a selection active fall through to the normal selection-replacing
                // insert below rather than consume chars behind the selection.
                if selectedRange().length > 0 {
                    if extra == 0 {
                        super.insertText(replacement, replacementRange: replacementRange)
                        return
                    }
                    // extra > 0 with a selection → fall through to the normal insert below.
                } else if loc - extra >= 0 {
                    super.insertText(replacement, replacementRange: NSRange(location: loc - extra, length: extra))
                    return
                }
            }
        }
        if let s = (string as? String) ?? (string as? NSAttributedString)?.string,
           s == ". ",
           replacementRange.length == 1, replacementRange.location != NSNotFound,
           let ts = textStorage, replacementRange.location < ts.length,
           (ts.string as NSString).character(at: replacementRange.location) == 32 /* space */ {
            super.insertText(" ", replacementRange: NSRange(location: replacementRange.location + 1, length: 0))
            return
        }
        super.insertText(string, replacementRange: replacementRange)
    }

    // The airy line-height multiple inflates each line fragment, so the default insertion point spans
    // that whole height — a too-tall caret. Constrain it to the glyph box at the caret (so it matches
    // the text, and grows on heading lines). The glyph does NOT sit at the fragment's vertical center
    // with airy spacing, so the caret must be pinned to the actual TEXT BASELINE (via the layout
    // manager), not centered in the fragment — centering left it visibly above the text.
    override func drawInsertionPoint(in rect: NSRect, color: NSColor, turnedOn flag: Bool) {
        var r = rect
        let len = textStorage?.length ?? 0
        let loc = selectedRange().location
        let font = (len == 0 ? nil
                    : textStorage?.attribute(.font, at: min(loc, len - 1), effectiveRange: nil) as? NSFont)
            ?? (typingAttributes[.font] as? NSFont) ?? self.font ?? NSFont.systemFont(ofSize: 16)
        let glyphHeight = font.ascender - font.descender   // ascent + |descent| — the visible glyph box
        if r.height > glyphHeight + 1 {
            var newY = rect.minY + (r.height - glyphHeight) / 2   // sane default: centered in the fragment
            if let lm = layoutManager, len > 0 {
                // `location(forGlyphAt:)`.y is the baseline's offset from the line-fragment top; the caret
                // rect's top IS that fragment top, so the baseline in view coords is rect.minY + that.
                // Span the caret from one ascender above the baseline down through the descender.
                let g = lm.glyphIndexForCharacter(at: min(loc, len - 1))
                let baselineY = rect.minY + lm.location(forGlyphAt: g).y
                newY = baselineY - font.ascender
            }
            // CLAMP the caret inside `rect` — the exact region AppKit invalidates when the caret moves. On an
            // EMPTY line the nearest glyph (`min(loc, len-1)`) is the prior line's trailing newline, whose
            // fragment differs from this `rect`, so the baseline math escapes `rect` and the caret is drawn
            // outside it. A move then never erases that out-of-rect caret → a stale "ghost" caret stacked on
            // the blank lines (reported after typing, Enter↵↵, then ↑↑). Clamping keeps every caret erasable.
            // The upper bound can't fall below rect.minY today (the branch guard ensures glyphHeight <
            // rect.height), but max(rect.minY, …) keeps the clamp correct — never above rect.minY — even if
            // a future line-height multiple < 1 ever made the fragment shorter than the glyph box.
            r.origin.y = min(max(newY, rect.minY), max(rect.minY, rect.maxY - glyphHeight))
            r.size.height = glyphHeight
        }
        super.drawInsertionPoint(in: r, color: color, turnedOn: flag)
    }

    // ImageInsert: accept dragged image files / image data so a Finder drag or an app dropping image
    // bytes lands here (NSTextView already accepts plain text). Registered once the view is in a window.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        registerForDraggedTypes([.fileURL, .png, .tiff])
    }

    /// Vertical anchors (text-container coords) for a block decoration spanning `cr`, measured from the
    /// actual glyphs — NOT from `boundingRect`, whose full LINE-FRAGMENT rects include the airy
    /// `lineHeightMultiple` leading above each line AND the font's ascent/descent slack. Returns the
    /// first content line's CAP top (the visible letter tops, not the much-higher font ascender), the
    /// last content line's BASELINE, and the last line's descender bottom. Zero-height lines (folded
    /// sections + the hidden ``` fence lines) are skipped, so the top is the first REAL code line.
    private func decorationAnchors(forCharacterRange cr: NSRange) -> (capTop: CGFloat, baseline: CGFloat, descBottom: CGFloat)? {
        guard let lm = layoutManager, let ts = textStorage else { return nil }
        let gr = lm.glyphRange(forCharacterRange: cr, actualCharacterRange: nil)
        guard gr.length > 0 else { return nil }
        var capTop = CGFloat.greatestFiniteMagnitude
        var lastBaseline = -CGFloat.greatestFiniteMagnitude
        var descBottom = -CGFloat.greatestFiniteMagnitude
        lm.enumerateLineFragments(forGlyphRange: gr) { fragRect, _, _, lineGlyphRange, _ in
            guard fragRect.height > 0 else { return }   // skip folded / collapsed-fence (zero-height) lines
            // Measure from the first glyph that is BOTH inside `cr` AND visible. Two reasons it may not be
            // `gr`'s first glyph: (1) `glyphRange(forCharacterRange:)` snaps a range that starts on a hidden
            // (`.null`, zero-width) glyph — a blockquote's `>` marker, an inline-code backtick — back to the
            // previous visible glyph, which can be the char (or whole line) BEFORE `cr`; (2) a `.null` glyph's
            // `location(forGlyphAt:)` reports the line-fragment TOP as the baseline, not the real text
            // baseline, which would push `capTop` a line-leading above the text. Advancing past both gives
            // the true first-letter baseline, so the bar/pill hugs the text instead of towering above it.
            let lineEnd = lineGlyphRange.location + lineGlyphRange.length
            var g = max(lineGlyphRange.location, gr.location)
            while g < lineEnd,
                  lm.characterIndexForGlyph(at: g) < cr.location || lm.propertyForGlyph(at: g).contains(.null) {
                g += 1
            }
            guard g < lineEnd else { return }                              // nothing visible inside cr on this line
            let ci = lm.characterIndexForGlyph(at: g)
            guard ci < cr.location + cr.length else { return }             // first visible glyph is past cr
            let font = (ci < ts.length ? ts.attribute(.font, at: ci, effectiveRange: nil) as? NSFont : nil)
                ?? self.font ?? NSFont.systemFont(ofSize: 16)
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

    // Draw the block decorations under the text: the blockquote bar and the thematic-break rule.
    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        guard let lm = layoutManager, let tc = textContainer else { return }
        let origin = textContainerOrigin

        // Code blocks: a rounded elevated card behind the code (corners + a right inset the
        // text-attribute background can't give). The card's vertical padding (cap line → top edge,
        // baseline → bottom edge) matches the text's horizontal inset, so the breathing room is even on
        // all four sides. `cardPadding` == the code paragraph style's left head-indent.
        let cardPadding = mallowCodeParagraphStyle.headIndent   // = the 12pt left text inset
        mallowElevated.setFill()
        for r in codeCards {
            guard let a = decorationAnchors(forCharacterRange: r) else { continue }
            let top = a.capTop - cardPadding, bottom = a.baseline + cardPadding
            let card = NSRect(x: origin.x, y: origin.y + top, width: tc.size.width - 8, height: bottom - top)
            NSBezierPath(roundedRect: card, xRadius: 6, yRadius: 6).fill()
        }
        // GFM tables: an elevated card + a 1px grid (outer border + a rule under each row + a rule at each
        // interior column boundary). Rows are the line fragments (the `|---|` delimiter row is collapsed to
        // zero height, so it's skipped). The column rules come from TableRendering's computed
        // `interiorEdges` — x-offsets from the table's left text edge that share the SAME column-width model
        // the cell kern uses, so rules and text can't drift (the old per-row `|`-glyph probe was ragged for
        // CJK). They're anchored to the table's first glyph (its probed left edge).
        for grid in tableGrids {
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
            mallowElevated.setFill()
            NSBezierPath(roundedRect: card, xRadius: 6, yRadius: 6).fill()
            mallowBorderColor.setStroke()
            let border = NSBezierPath(roundedRect: card.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6)
            border.lineWidth = 1
            border.stroke()
            let rules = NSBezierPath()
            rules.lineWidth = 1
            for i in 0 ..< (rows.count - 1) {   // a rule under every row but the last (header rule + row separators)
                let y = (origin.y + rows[i].maxY).rounded() + 0.5
                rules.move(to: NSPoint(x: card.minX, y: y))
                rules.line(to: NSPoint(x: card.maxX, y: y))
            }
            for edge in grid.interiorEdges {   // vertical column rules at the computed interior offsets
                let x = (leftX + edge).rounded() + 0.5
                guard x > card.minX + 1, x < card.maxX - 1 else { continue }
                rules.move(to: NSPoint(x: x, y: card.minY))
                rules.line(to: NSPoint(x: x, y: card.maxY))
            }
            rules.stroke()
        }

        // Blockquote: a 3pt left bar spanning cap line → baseline, i.e. the height of the quoted text.
        mallowFaint.setFill()
        for r in quoteBars {
            guard let a = decorationAnchors(forCharacterRange: r) else { continue }
            let bar = NSRect(x: origin.x + 6, y: origin.y + a.capTop,
                             width: 3, height: max(1, a.baseline - a.capTop))
            NSBezierPath(roundedRect: bar, xRadius: 1.5, yRadius: 1.5).fill()
        }

        // Inline `code`: a small rounded pill hugging the run (cap → baseline + 2pt), drawn here rather than
        // via a `.backgroundColor` attribute — that fills the whole airy line fragment, leaving a tall gap
        // above the text. boundingRect gives the horizontal extent; decorationAnchors the tight vertical.
        mallowElevated.setFill()
        for r in inlineCodeRuns {
            let gr = lm.glyphRange(forCharacterRange: r, actualCharacterRange: nil)
            guard gr.length > 0 else { continue }
            // Draw one pill PER line fragment the run occupies. A long inline-code span that WRAPS must get
            // a pill on each visual line; the old single `boundingRect` union spanned the whole wrap as one
            // tall rectangle that bled over the lines between. Each fragment hugs its own cap→baseline.
            lm.enumerateLineFragments(forGlyphRange: gr) { _, _, _, fragGlyphRange, _ in
                let lineGlyphs = NSIntersectionRange(gr, fragGlyphRange)
                guard lineGlyphs.length > 0 else { return }
                let lineChars = lm.characterRange(forGlyphRange: lineGlyphs, actualGlyphRange: nil)
                guard let a = self.decorationAnchors(forCharacterRange: lineChars) else { return }
                let box = lm.boundingRect(forGlyphRange: lineGlyphs, in: tc)
                let pill = NSRect(x: origin.x + box.minX - 2, y: origin.y + a.capTop - 2,
                                  width: box.width + 4, height: (a.baseline - a.capTop) + 4)
                NSBezierPath(roundedRect: pill, xRadius: 3, yRadius: 3).fill()
            }
        }

        mallowBorderColor.setFill()
        let glyphCount = lm.numberOfGlyphs
        for r in ruleLines where glyphCount > 0 {
            let gi = min(lm.glyphIndexForCharacter(at: r.location), glyphCount - 1)
            var eff = NSRange()
            let line = lm.lineFragmentRect(forGlyphAt: gi, effectiveRange: &eff)
            let y = (origin.y + line.midY).rounded() + 0.5   // crisp 1px hairline
            NSRect(x: origin.x, y: y, width: tc.size.width - 8, height: 1).fill()
        }
    }

    // Merged paste override for two features:
    //   • ImageInsert: a paste holding image(s) becomes an inline data-URI markdown image.
    //   • ClipboardExtras (c): a single http(s) URL pasted over a selection wraps it as [sel](url).
    // Try the image embed first, then the URL-wrap; otherwise fall through to the normal text paste.
    // The controller (our delegate) does the work so VM refresh / chrome stay there.
    override func paste(_ sender: Any?) {
        // Image-embed + URL-wrap paste via the editor coordinator (PasteHandlers); falls through to the
        // standard text paste when neither applies.
        if (delegate as? MarkdownEditor.Coordinator)?.handlePaste() == true { return }
        super.paste(sender)
    }

    // ImageInsert: a drop that carries image(s) is embedded at the drop point; otherwise (dragged
    // text, internal moves) defer to NSTextView's default handling.
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        if (delegate as? MarkdownEditor.Coordinator)?.handleDrop(sender) == true { return true }
        return super.performDragOperation(sender)
    }

    // ImageInsert: advertise a copy operation for image drags so the cursor shows the (+) badge and
    // the drop is accepted; non-image drags keep NSTextView's behavior.
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        if (delegate as? MarkdownEditor.Coordinator)?.acceptsImageDrag(sender) == true { return .copy }
        return super.draggingEntered(sender)
    }
}

/// Shared text-view configuration applied to every window's editor.
func configureTextView(_ textView: MarkdownTextView) {
    textView.autoresizingMask = [.width]
    textView.isRichText = true
    textView.allowsUndo = true
    textView.isAutomaticQuoteSubstitutionEnabled = false
    textView.isAutomaticDashSubstitutionEnabled = false
    textView.isAutomaticTextReplacementEnabled = false
    textView.isAutomaticSpellingCorrectionEnabled = false
    textView.isAutomaticLinkDetectionEnabled = false
    textView.isAutomaticDataDetectionEnabled = false
    textView.isContinuousSpellCheckingEnabled = false
    textView.isGrammarCheckingEnabled = false
    textView.usesFindBar = true  // native find/replace bar (⌘F) — mature, IME-aware, free
    // Mallow geometry: generous side margins; top inset clears the 52px titlebar overlay (+24 pad).
    textView.textContainerInset = NSSize(width: 88, height: 76)
    textView.drawsBackground = true
    textView.backgroundColor = mallowBG
    textView.insertionPointColor = mallowText
    // Airy line spacing (Tauri line-height 1.8). Set as default + typing style so text typed between
    // refreshes already has the rhythm; restyle() reasserts it as the base paragraph attribute.
    textView.defaultParagraphStyle = mallowBodyParagraphStyle
    textView.typingAttributes[.paragraphStyle] = mallowBodyParagraphStyle
}

// MARK: - Undoable mutation seam
//
// Every programmatic edit MUST go through the text view's undoable path so ⌘Z reverts it like typing
// and the existing undo stack is preserved — NEVER `textView.string = …` (registers no undo AND wipes
// the stack). Two idioms exist: a low-level `replaceCharacters` (engine commands, task toggle, reload)
// and the high-level `insertText(_:replacementRange:)` (paste). Both are guarded by `shouldChangeText`
// and centralized here so call sites stop re-implementing (and re-documenting) the contract.
extension MarkdownTextView {
    /// Replace `range` with `text` via shouldChangeText → `textStorage.replaceCharacters` → didChangeText.
    /// Returns false if a delegate vetoed the change. The caller owns the post-edit caret / refresh /
    /// revision bump.
    @discardableResult
    func replaceCharactersUndoably(in range: NSRange, with text: String) -> Bool {
        guard shouldChangeText(in: range, replacementString: text) else { return false }
        textStorage?.replaceCharacters(in: range, with: text)
        didChangeText()
        return true
    }

    /// Insert `text` over `range` via the high-level `insertText(_:replacementRange:)` (which registers
    /// undo and fires textDidChange itself), guarded by shouldChangeText. Returns false if vetoed.
    @discardableResult
    func insertTextUndoably(_ text: String, replacing range: NSRange) -> Bool {
        guard shouldChangeText(in: range, replacementString: text) else { return false }
        insertText(text, replacementRange: range)
        return true
    }
}
