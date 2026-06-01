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

/// Scroll past end: a clip view that lets the document scroll `overscroll` points beyond its natural
/// bottom, so the last lines aren't pinned to the window's bottom edge — you can scroll them up toward
/// the middle (comfort; matches iA Writer / Typora, and lets typewriter mode centre the final lines).
/// Always on, no setting. This extends only the scroll CLAMP — it never touches the document view's
/// frame or the scroll view's content insets, so the live-preview styling and the top chrome clearance
/// are completely unaffected (the two things the frame / contentInset approaches broke). Overscroll is
/// allowed only when the document is taller than the viewport, so short notes scroll exactly as before.
final class BottomOverscrollClipView: NSClipView {
    var overscroll: CGFloat = 300
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposedBounds)
        guard let docView = documentView, docView.frame.height > rect.height else { return rect }
        // `super` already clamped `rect.origin.y` to the natural bottom (accounting for content insets).
        // If the caller proposed scrolling further down than that, allow up to `overscroll` more — and no
        // more — so the last lines rise toward the middle but never scroll fully off the top.
        let beyond = proposedBounds.origin.y - rect.origin.y
        if beyond > 0 { rect.origin.y += min(beyond, overscroll) }
        return rect
    }
}

struct MarkdownEditor: NSViewRepresentable {
    let doc: EditorDocument

    func makeCoordinator() -> Coordinator { Coordinator(doc: doc) }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = doc.textView
        textView.delegate = context.coordinator
        // Touching layoutManager forces TextKit 1, where the glyph-generation delegate fires (the hide-
        // syntax + bullet substitution pipeline depends on it).
        textView.layoutManager?.delegate = context.coordinator

        // Click a task-list ☐/☑ to toggle it. delaysPrimaryMouseButtonEvents=false so normal caret/
        // selection clicks still pass through; the handler no-ops off a checkbox.
        let taskClick = NSClickGestureRecognizer(target: context.coordinator,
                                                 action: #selector(Coordinator.handleTaskClick(_:)))
        taskClick.delaysPrimaryMouseButtonEvents = false
        textView.addGestureRecognizer(taskClick)

        // Vertically-growing text view inside a scroll view (the classic NSTextView-in-NSScrollView setup).
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)

        let scroll = NSScrollView()
        scroll.contentView = BottomOverscrollClipView()   // scroll-past-end: extend only the scroll clamp
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = true
        scroll.backgroundColor = mallowBG
        scroll.borderType = .noBorder
        scroll.documentView = textView
        // The ChromeBar overlays the editor's top (it's a ZStack overlay, outside the layout flow), so the
        // vertical scroller would otherwise run up underneath it and its top would look clipped. Inset the
        // scroller down by the bar height so the scrollbar starts cleanly below the chrome.
        scroll.scrollerInsets = NSEdgeInsets(top: ChromeBar.barHeight, left: 0, bottom: 0, right: 0)

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

        /// Map a click to a character index and toggle a task checkbox if it landed on one (else no-op).
        @objc func handleTaskClick(_ g: NSClickGestureRecognizer) {
            let tv = doc.textView
            let idx = tv.characterIndexForInsertion(at: g.location(in: tv))
            _ = toggleTaskBoxAt(idx)
        }

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
            let taskBoxes = vm.taskBoxes
            let pipes = vm.tablePipes
            if hidden.isEmpty && bullets.isEmpty && taskBoxes.isEmpty && pipes.isEmpty { return 0 }  // 0 = no override
            let bulletGlyph = bullets.isEmpty ? CGGlyph(0) : Self.bulletGlyph(for: font)
            let taskGlyphs = taskBoxes.isEmpty ? nil : TaskBoxGlyphs(font: font)
            let spaceGlyph = pipes.isEmpty ? CGGlyph(0) : Self.spaceGlyph(for: font)
            var newGlyphs = [CGGlyph](repeating: 0, count: glyphRange.length)
            var newProps = [NSLayoutManager.GlyphProperty](repeating: .null, count: glyphRange.length)
            var changed = false
            for i in 0 ..< glyphRange.length {
                let ch = characterIndexes[i]
                if hidden.contains(ch) {
                    newGlyphs[i] = glyphs[i]; newProps[i] = .null; changed = true
                } else if let tg = taskGlyphs, let checked = taskBoxes[ch] {
                    // Substitute ☐/☑ — or, if the font lacks the glyph (0), HIDE the inner char (.null)
                    // rather than leak the raw `[ ]`/`[x]` content (the brackets are already hidden).
                    let g = tg.glyph(checked: checked)
                    if g != 0 { newGlyphs[i] = g; newProps[i] = props[i] }
                    else { newGlyphs[i] = glyphs[i]; newProps[i] = .null }
                    changed = true
                } else if bulletGlyph != 0, bullets.contains(ch) {
                    newGlyphs[i] = bulletGlyph; newProps[i] = props[i]; changed = true
                } else if spaceGlyph != 0, pipes.contains(ch) {
                    newGlyphs[i] = spaceGlyph; newProps[i] = props[i]; changed = true  // table `|` → space (keeps columns aligned)
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

        /// The space (U+0020) glyph id for `font` — used to render a table `|` as a blank of the same
        /// (monospace) width, so columns stay aligned while the bar disappears. 0 if the font lacks it.
        private static func spaceGlyph(for font: NSFont) -> CGGlyph {
            var ch: UniChar = 0x20
            var glyph = CGGlyph(0)
            CTFontGetGlyphsForCharacters(font as CTFont, &ch, &glyph, 1)
            return glyph
        }
    }
}
