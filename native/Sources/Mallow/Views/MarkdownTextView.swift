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
    var quoteBars: [NSRange] = [] { didSet { needsDisplay = true } }
    var ruleLines: [NSRange] = [] { didSet { needsDisplay = true } }

    // Defeat "Add period with double-space" — a global text-input default (NSAutomaticPeriodSubstitution-
    // Enabled) with no per-view or app-domain override. On the 2nd space the system calls
    // insertText(". ", replacing the just-typed space at {loc,1}); that inserts a "." the user never
    // typed, which is wrong for a markdown-as-truth editor. When we see that exact shape, keep the
    // literal double space instead. (Manually typed "." comes in as "." with no replacement, so this
    // guard is specific to the substitution and never touches real periods.)
    override func insertText(_ string: Any, replacementRange: NSRange) {
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
    // that whole height — a too-tall caret. Constrain it to the glyph height at the caret (so it matches
    // the text, and grows on heading lines), vertically centered in the fragment.
    override func drawInsertionPoint(in rect: NSRect, color: NSColor, turnedOn flag: Bool) {
        var r = rect
        let len = textStorage?.length ?? 0
        let loc = selectedRange().location
        let font = (len == 0 ? nil
                    : textStorage?.attribute(.font, at: min(loc, len - 1), effectiveRange: nil) as? NSFont)
            ?? (typingAttributes[.font] as? NSFont) ?? self.font ?? NSFont.systemFont(ofSize: 16)
        let glyphHeight = font.ascender - font.descender + font.leading
        if r.height > glyphHeight + 1 {
            r.origin.y += (r.height - glyphHeight) / 2
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

    // Draw the block decorations under the text: the blockquote bar and the thematic-break rule.
    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        guard let lm = layoutManager, let tc = textContainer else { return }
        let origin = textContainerOrigin

        // Code blocks: a rounded elevated card behind the code (corners + a right inset the
        // text-attribute background can't give). Full content width minus the rule inset.
        mallowElevated.setFill()
        for r in codeCards {
            let gr = lm.glyphRange(forCharacterRange: r, actualCharacterRange: nil)
            guard gr.length > 0 else { continue }
            let box = lm.boundingRect(forGlyphRange: gr, in: tc)
            let card = NSRect(x: origin.x, y: origin.y + box.minY - 2,
                              width: tc.size.width - 8, height: box.height + 4)
            NSBezierPath(roundedRect: card, xRadius: 6, yRadius: 6).fill()
        }

        mallowFaint.setFill()
        for r in quoteBars {
            let gr = lm.glyphRange(forCharacterRange: r, actualCharacterRange: nil)
            guard gr.length > 0 else { continue }
            let box = lm.boundingRect(forGlyphRange: gr, in: tc)
            let bar = NSRect(x: origin.x + 6, y: origin.y + box.minY + 2,
                             width: 3, height: max(1, box.height - 4))
            NSBezierPath(roundedRect: bar, xRadius: 1.5, yRadius: 1.5).fill()
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
