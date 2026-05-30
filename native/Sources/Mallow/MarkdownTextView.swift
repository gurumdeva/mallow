// MarkdownTextView — the editing surface (View layer). A bare NSTextView subclass plus the shared
// configuration: markdown-as-truth means every "smart" auto-substitution is OFF (they would rewrite
// the bytes the parser reads), the native find bar is on, and the geometry matches Mallow.

import AppKit
import UniformTypeIdentifiers

final class MarkdownTextView: NSTextView {
    // Decoration ranges the view-model recomputes each refresh (UTF-16). Blockquote ranges get a 3px
    // left bar; thematic-break ranges get a 1px horizontal rule (their source dashes are hidden), the
    // two block decorations NSTextView can't express as text attributes. Redraw when they change.
    var quoteBars: [NSRange] = [] { didSet { needsDisplay = true } }
    var ruleLines: [NSRange] = [] { didSet { needsDisplay = true } }

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
        if let controller = delegate as? EditorController {
            if controller.insertImagesFromPasteboard(NSPasteboard.general) { return }
            if controller.handleURLWrapPaste() { return }
        }
        super.paste(sender)
    }

    // ImageInsert: a drop that carries image(s) is embedded at the drop point; otherwise (dragged
    // text, internal moves) defer to NSTextView's default handling.
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        if let controller = delegate as? EditorController,
           controller.insertImagesFromDrag(sender) {
            return true
        }
        return super.performDragOperation(sender)
    }

    // ImageInsert: advertise a copy operation for image drags so the cursor shows the (+) badge and
    // the drop is accepted; non-image drags keep NSTextView's behavior.
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        if sender.draggingPasteboard.canReadObject(forClasses: [NSURL.self],
                                                   options: [.urlReadingFileURLsOnly: true,
                                                             .urlReadingContentsConformToTypes: [UTType.image.identifier]])
            || sender.draggingPasteboard.canReadItem(withDataConformingToTypes: [UTType.image.identifier]) {
            return .copy
        }
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
