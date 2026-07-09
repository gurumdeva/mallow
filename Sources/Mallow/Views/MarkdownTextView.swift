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

    /// The text-container width a wide table needs (points), or 0 if every table fits the viewport. The
    /// Restyler sets it each pass; the resize observer reads it so the container never shrinks below a
    /// horizontally-scrolling table while the window is being dragged (before the debounced restyle runs).
    var tableContainerWidth: CGFloat = 0

    /// Grammar context for smart typography, wired by EditorViewModel from its CACHED engine parse:
    /// true when the UTF-16 location sits inside a code block or the frontmatter region. The rule
    /// table's own heuristics only know ``` fences at column 0 and LF `---` frontmatter — the parse
    /// additionally knows `~~~` fences, indented code, and CRLF frontmatter, where substitution used
    /// to silently corrupt code/YAML (engine-review E4/E10). Union semantics: suppression applies when
    /// EITHER this closure or the built-in heuristics say "inside". nil (headless view without a VM) →
    /// heuristics only, the old behavior.
    var typographySuppressed: ((Int) -> Bool)?

    /// The width of a container that exactly fills the viewport (points), set by the Restyler each pass; 0
    /// when unknown. Block decorations that should track the WINDOW — the code-block card and the thematic
    /// rule — clamp their width to this so they don't stretch across the extra-wide container a horizontally
    /// scrolling table creates (their text already wraps at the viewport). The TABLE card intentionally does
    /// NOT clamp — it owns the scrolled region.
    var viewportContainerWidth: CGFloat = 0

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
            // Parse-informed suppression FIRST (cheap closure, consulted only when a substitution is
            // possible): inside a code block / frontmatter the source bytes are sacred — no curling.
            if let replacement = SmartTypography.substitution(for: s, in: self.string, at: loc),
               typographySuppressed?(loc) != true {
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
            ?? (typingAttributes[.font] as? NSFont) ?? self.font ?? NSFont.systemFont(ofSize: mallowBodySize)
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

    // Draw the block/inline decorations under the text. This is now a THIN painter: all geometry lives
    // in `DecorationRenderer` (pure, headless-testable); here we only set colors and fill/stroke the
    // rects it returns, in the same order + colors as before the extraction.
    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        guard let lm = layoutManager, let tc = textContainer, let ts = textStorage else { return }
        // Width for decorations that track the WINDOW (code card, thematic rule): the container can be wider
        // than the viewport when a wide table scrolls horizontally, but those blocks' text wraps at the
        // viewport, so their card/rule must too. Clamp to the viewport width (fall back to the container when
        // it's unknown — no wide table ⇒ they're equal, so this is byte-identical to before).
        let decoWidth = viewportContainerWidth > 0 ? min(tc.size.width, viewportContainerWidth) : tc.size.width
        let renderer = DecorationRenderer(
            lm: lm, tc: tc, ts: ts, origin: textContainerOrigin,
            fallbackFont: self.font ?? NSFont.systemFont(ofSize: mallowBodySize), decoWidth: decoWidth)

        // Code blocks: a rounded elevated card behind the code.
        mallowElevated.setFill()
        for card in renderer.codeCardRects(codeCards) {
            NSBezierPath(roundedRect: card, xRadius: 6, yRadius: 6).fill()
        }

        // GFM tables: an elevated card + a 1px grid (outer border + a horizontal rule at each row boundary +
        // a rule at each interior column boundary). Colors are re-set per table exactly as before.
        for table in renderer.tableDecorations(tableGrids) {
            mallowElevated.setFill()
            NSBezierPath(roundedRect: table.card, xRadius: 6, yRadius: 6).fill()
            mallowBorderColor.setStroke()
            let border = NSBezierPath(roundedRect: table.card.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6)
            border.lineWidth = 1
            border.stroke()
            let rules = NSBezierPath()
            rules.lineWidth = 1
            for y in table.horizontalRuleYs {
                rules.move(to: NSPoint(x: table.card.minX, y: y))
                rules.line(to: NSPoint(x: table.card.maxX, y: y))
            }
            for x in table.verticalRuleXs {
                rules.move(to: NSPoint(x: x, y: table.card.minY))
                rules.line(to: NSPoint(x: x, y: table.card.maxY))
            }
            rules.stroke()
        }

        // Blockquote: a 3pt left bar spanning cap line → baseline, i.e. the height of the quoted text.
        mallowFaint.setFill()
        for bar in renderer.quoteBarRects(quoteBars) {
            NSBezierPath(roundedRect: bar, xRadius: 1.5, yRadius: 1.5).fill()
        }

        // Inline `code`: a small rounded pill hugging the run (one per wrapped line fragment).
        mallowElevated.setFill()
        for pill in renderer.inlineCodePillRects(inlineCodeRuns) {
            NSBezierPath(roundedRect: pill, xRadius: 3, yRadius: 3).fill()
        }

        // Thematic breaks: a 1px hairline centered on each rule line.
        mallowBorderColor.setFill()
        for line in renderer.ruleLineRects(ruleLines) {
            line.fill()
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
    // First-paint typography: the Mallow body font/color as VIEW DEFAULTS, so any frame that renders
    // BEFORE the Restyler's first style pass (file open paints raw markdown once — see the first-paint
    // gate in MarkdownEditor.makeNSView) is already at the right size and color, not the tiny NSTextView
    // default font that used to flash on large documents. restyle() re-asserts these as attributes.
    let bodyFont = NSFont.systemFont(ofSize: mallowBodySize, weight: .regular)
    textView.font = bodyFont
    textView.textColor = mallowBodyTextColor
    textView.typingAttributes[.font] = bodyFont
    textView.typingAttributes[.foregroundColor] = mallowBodyTextColor
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
