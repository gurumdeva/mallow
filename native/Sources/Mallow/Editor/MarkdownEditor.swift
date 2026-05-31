// MarkdownEditor — the SwiftUI editing surface: an NSScrollView + MarkdownTextView wrapped in an
// NSViewRepresentable. The text engine stays AppKit because the live-preview syntax hiding (NSLayout-
// Manager glyph substitution), the custom caret, the decoration drawing, and CJK IME all need TextKit —
// none of which SwiftUI's TextEditor exposes. Everything AROUND the editor (chrome, popovers, menus,
// window lifecycle) is pure SwiftUI; this representable is the single AppKit island.
//
// The per-document state lives in `EditorDocument` (the text view + the EditorViewModel pipeline). The
// Coordinator is the NSTextViewDelegate + NSLayoutManagerDelegate — the same two delegate roles the old
// EditorController played for the editor — and bumps the document's `revision` so the chrome re-renders.

import SwiftUI
import AppKit
import CoreText

struct MarkdownEditor: NSViewRepresentable {
    let doc: EditorDocument

    func makeCoordinator() -> Coordinator { Coordinator(doc: doc) }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = doc.textView
        textView.delegate = context.coordinator
        // Touching layoutManager forces TextKit 1, where the glyph-generation delegate fires (the hide-
        // syntax + bullet substitution pipeline depends on it).
        textView.layoutManager?.delegate = context.coordinator

        // Vertically-growing text view inside a scroll view (the classic NSTextView-in-NSScrollView setup).
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = true
        scroll.backgroundColor = mallowBG
        scroll.borderType = .noBorder
        scroll.documentView = textView

        // First render: parse + style + hide once the view is in the hierarchy.
        DispatchQueue.main.async { doc.vm.refresh() }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        // SwiftUI-driven state that should reflect into the editor lands here later (zoom, focus mode).
        // The text itself is owned by the NSTextView, so there is nothing to push on a normal re-render.
    }

    // MARK: - Coordinator (text + layout delegates)

    final class Coordinator: NSObject, NSTextViewDelegate, NSLayoutManagerDelegate {
        let doc: EditorDocument
        let behaviors = EditorBehaviors()   // debounced autosave + typewriter caret-centering (one per window)
        private var vm: EditorViewModel { doc.vm }

        init(doc: EditorDocument) { self.doc = doc }

        func textDidChange(_ notification: Notification) {
            vm.refresh()
            doc.revision &+= 1   // chrome re-renders title/dirty
            behaviors.textChanged(doc)   // schedule debounced autosave
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            vm.selectionChanged()
            behaviors.selectionChanged(doc)   // recenter the caret line when typewriter mode is on
        }

        /// Mark hidden-syntax glyphs as `.null` (zero-width) and substitute a `•` glyph for unordered-list
        /// dashes — both read from the view-model's sets. 1:1 char↔glyph so caret/selection offsets stay
        /// exact. (Ported verbatim from the old EditorController so the live-preview behaviour is identical.)
        func layoutManager(_ lm: NSLayoutManager,
                           shouldGenerateGlyphs glyphs: UnsafePointer<CGGlyph>,
                           properties props: UnsafePointer<NSLayoutManager.GlyphProperty>,
                           characterIndexes: UnsafePointer<Int>,
                           font: NSFont,
                           forGlyphRange glyphRange: NSRange) -> Int {
            let hidden = vm.hiddenChars
            let bullets = vm.bulletMarks
            if hidden.isEmpty && bullets.isEmpty { return 0 }  // 0 = no override, default glyph generation
            let bulletGlyph = bullets.isEmpty ? CGGlyph(0) : Self.bulletGlyph(for: font)
            var newGlyphs = [CGGlyph](repeating: 0, count: glyphRange.length)
            var newProps = [NSLayoutManager.GlyphProperty](repeating: .null, count: glyphRange.length)
            var changed = false
            for i in 0 ..< glyphRange.length {
                let ch = characterIndexes[i]
                if hidden.contains(ch) {
                    newGlyphs[i] = glyphs[i]; newProps[i] = .null; changed = true
                } else if bulletGlyph != 0, bullets.contains(ch) {
                    newGlyphs[i] = bulletGlyph; newProps[i] = props[i]; changed = true
                } else {
                    newGlyphs[i] = glyphs[i]; newProps[i] = props[i]
                }
            }
            if !changed { return 0 }
            newGlyphs.withUnsafeBufferPointer { gptr in
                lm.setGlyphs(gptr.baseAddress!, properties: &newProps,
                             characterIndexes: characterIndexes, font: font, forGlyphRange: glyphRange)
            }
            return glyphRange.length
        }

        /// The `•` (U+2022) glyph id for `font`, or 0 if the font lacks it (→ keep the literal dash).
        private static func bulletGlyph(for font: NSFont) -> CGGlyph {
            var ch: UniChar = 0x2022
            var glyph = CGGlyph(0)
            CTFontGetGlyphsForCharacters(font as CTFont, &ch, &glyph, 1)
            return glyph
        }
    }
}
