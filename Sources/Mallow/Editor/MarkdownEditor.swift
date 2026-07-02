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

        // Text view inside a scroll view, growing BOTH ways: vertically for the document, horizontally so a
        // wide table can extend past the viewport and be reached by a horizontal scroller (a too-wide table
        // scrolls, never shrinks). The Restyler owns the container width each pass — it sets it to the
        // viewport width normally (so prose fills the width and wraps at the viewport), or wider when a table
        // needs it (prose then keeps its viewport wrap via a `tailIndent`). So width does NOT track the view.
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = true
        textView.autoresizingMask = []
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)

        let scroll = NSScrollView()
        scroll.contentView = BottomOverscrollClipView()   // scroll-past-end: extend only the scroll clamp
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true               // shown only when a wide table overflows…
        scroll.autohidesScrollers = true                  // …auto-hidden otherwise (no table → looks unchanged)
        scroll.drawsBackground = true
        scroll.backgroundColor = mallowBG
        scroll.borderType = .noBorder
        scroll.documentView = textView
        // The ChromeBar overlays the editor's top (it's a ZStack overlay, outside the layout flow), so the
        // vertical scroller would otherwise run up underneath it and its top would look clipped. Inset the
        // scroller down by the bar height so the scrollbar starts cleanly below the chrome.
        scroll.scrollerInsets = NSEdgeInsets(top: ChromeBar.barHeight, left: 0, bottom: 0, right: 0)

        // Re-run the width-dependent style pass when the viewport width changes (window resize), so table
        // geometry (card, rules, kern, wrap) follows the text instead of freezing at the open-time width.
        context.coordinator.observeViewportWidth(of: scroll.contentView)

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

        deinit {
            if let o = widthObserver { NotificationCenter.default.removeObserver(o) }
            reflowWork?.cancel()
        }

        // MARK: width-change reflow
        //
        // Table geometry — per-cell `.kern`, the wrap edge, `TableGrid.totalWidth`/`interiorEdges` — is
        // computed at the current viewport width during `restyle`. When the window/viewport width changes
        // the TEXT reflows live (the container tracks the view), but that frozen geometry would go stale:
        // the card + column rules stay at the old width while the wrapped text moves, so they detach. Re-run
        // the (width-dependent) style pass on a resize, debounced so a live drag doesn't restyle per frame.
        // The parse and hidden-glyph set are width-independent, so only `restyle()` reruns — not `refresh()`.
        private var widthObserver: NSObjectProtocol?
        private var lastLayoutWidth: CGFloat = 0
        private var reflowWork: DispatchWorkItem?

        func observeViewportWidth(of clipView: NSClipView) {
            lastLayoutWidth = clipView.bounds.width
            clipView.postsFrameChangedNotifications = true
            widthObserver = NotificationCenter.default.addObserver(
                forName: NSView.frameDidChangeNotification, object: clipView, queue: .main
            ) { [weak self, weak clipView] _ in
                guard let clipView else { return }
                self?.scheduleReflow(clipView.bounds.width)
            }
        }

        private func scheduleReflow(_ clipWidth: CGFloat) {
            guard abs(clipWidth - lastLayoutWidth) > 0.5 else { return }   // a scroll or vertical-only change — ignore
            lastLayoutWidth = clipWidth
            // Immediate + cheap: keep the container filling the viewport so PROSE re-wraps live during a
            // drag — but never below a horizontally-scrolling table's width (that width holds until the
            // debounced restyle re-measures). This is just the container box; no text is re-measured here.
            let tv = doc.textView
            let viewportContainerW = max(0, clipWidth - 2 * tv.textContainerInset.width)
            tv.textContainer?.size.width = max(viewportContainerW, tv.tableContainerWidth)
            // Debounced + expensive: re-measure table kern / wrap edge / card / rules at the new width.
            reflowWork?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self, !self.doc.textView.hasMarkedText() else { return }   // never restyle mid-IME
                self.vm.restyle()
            }
            reflowWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
        }

        /// Map a click to a character index and toggle a task checkbox if it landed on one (else no-op).
        @objc func handleTaskClick(_ g: NSClickGestureRecognizer) {
            let tv = doc.textView
            let idx = tv.characterIndexForInsertion(at: g.location(in: tv))
            _ = toggleTaskBoxAt(idx)
        }

        /// Set when `textDidChange` skipped styling because a composition was live, so the caret handler
        /// below runs the deferred refresh once the composition ends — covering a commit that changes no
        /// bytes (IME finalize-on-app-switch / click-away), where textDidChange never fires again.
        private var deferredComposingRefresh = false

        func textDidChange(_ notification: Notification) {
            // Never restyle / re-hide WHILE an IME composition is live. refresh() runs a full-document
            // setAttributes — which strips the marked-text underline AppKit draws on the composing clause —
            // plus a full-document glyph+layout invalidate that stutters the candidate window on a large
            // note and re-hides syntax around the half-typed text (markers flickering in/out per jamo).
            // Every other buffer-touching path already guards on hasMarkedText(); this hot path was the gap.
            // Committing the composition normally fires textDidChange again with no marked text, so the final
            // settled text is styled then; `deferredComposingRefresh` + textViewDidChangeSelection cover the
            // case where the commit changes no bytes. Dirty flag + autosave still tick so nothing is lost.
            if doc.textView.hasMarkedText() {
                deferredComposingRefresh = true
            } else {
                deferredComposingRefresh = false
                vm.clearSectionFolds()   // per-section fold offsets would go stale against the edit; drop them
                vm.refresh()
            }
            doc.revision &+= 1   // chrome re-renders title/dirty
            behaviors.textChanged(doc)   // schedule debounced autosave
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            // If styling was deferred during a composition that has now ended (no marked text), run it now —
            // catches a commit that changed no bytes (IME finalizing on click-away / app-switch), where
            // textDidChange never re-fired to restyle.
            if deferredComposingRefresh, !doc.textView.hasMarkedText() {
                deferredComposingRefresh = false
                vm.clearSectionFolds()
                vm.refresh()
            }
            vm.selectionChanged()
            behaviors.selectionChanged(doc)   // recenter the caret line when typewriter mode is on
        }

        /// Mark hidden-syntax glyphs as `.null` (zero-width) and substitute a `•` glyph for unordered-list
        /// dashes — both read from the view-model's sets. 1:1 char↔glyph so caret/selection offsets stay
        /// exact. Markers are hidden unconditionally (no caret-line reveal); the sets are caret-independent.
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
            // During a live IME composition the hidden/bullet/task/pipe sets are FROZEN at pre-composition
            // offsets (refresh is skipped to avoid flicker), so they no longer align with indices at/after the
            // inserted marked text. Render everything from the marked-range start onward LITERALLY, so a
            // composing glyph can't be mis-hidden (`.null`) by a stale index that used to name a real marker
            // — its text would otherwise vanish until commit. NSNotFound when not composing → a no-op.
            let markedLo = doc.textView.hasMarkedText() ? doc.textView.markedRange().location : NSNotFound
            for i in 0 ..< glyphRange.length {
                let ch = characterIndexes[i]
                if ch >= markedLo {
                    newGlyphs[i] = glyphs[i]; newProps[i] = props[i]   // composing region: render as typed
                } else if hidden.contains(ch) {
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

        /// Custom line-fragment geometry for two cases, keyed by the line's first character:
        ///  (1) `vm.foldedChars` → zero height: Fold All / Fold Section collapse a heading's body to an
        ///      outline, and code-block ``` fences + the table `|---|` delimiter collapse so their cards
        ///      hug the content. The glyphs are already hidden, so nothing draws in the zero row.
        ///  (2) `vm.tableRowChars` → taller + centered: a GFM table content row gets `tableRowPad` of space
        ///      ABOVE and BELOW its text (and the text centered), so cells aren't cramped against the grid
        ///      rules. This pad is the only source of a SINGLE-line row's height (the table paragraph style
        ///      carries no `lineHeightMultiple`, which would add space only above the glyph); a tall WRAPPED
        ///      cell additionally gets `lineSpacing` BETWEEN its lines from the table paragraph style.
        func layoutManager(_ lm: NSLayoutManager,
                           shouldSetLineFragmentRect lineFragmentRect: UnsafeMutablePointer<NSRect>,
                           lineFragmentUsedRect: UnsafeMutablePointer<NSRect>,
                           baselineOffset: UnsafeMutablePointer<CGFloat>,
                           in textContainer: NSTextContainer,
                           forGlyphRange glyphRange: NSRange) -> Bool {
            guard !vm.foldedChars.isEmpty || !vm.tableRowChars.isEmpty else { return false }
            let charStart = lm.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil).location
            // IME guard, matching the glyph delegate: foldedChars / tableRowChars are FROZEN at
            // pre-composition offsets while a composition is live, so a now-shifted VISIBLE line whose start
            // collides with a stale folded index would wrongly collapse to zero height (its text vanishes
            // mid-composition). Don't override geometry from the marked-range start onward; commit re-derives.
            if doc.textView.hasMarkedText(), charStart >= doc.textView.markedRange().location { return false }
            if vm.foldedChars.contains(charStart) {
                lineFragmentRect.pointee.size.height = 0
                lineFragmentUsedRect.pointee.size.height = 0
                baselineOffset.pointee = 0
                return true
            }
            if vm.tableRowChars.contains(charStart) {
                let pad: CGFloat = 6
                lineFragmentRect.pointee.size.height += 2 * pad
                lineFragmentUsedRect.pointee.size.height += 2 * pad
                baselineOffset.pointee += pad
                return true
            }
            return false
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
