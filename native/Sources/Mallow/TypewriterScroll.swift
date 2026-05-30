// TypewriterScroll — View ▸ Typewriter Scrolling (⌃⌘T). When on, the caret's line is kept pinned to
// the vertical centre of the scroll view: centred once the moment it's enabled, then re-centred on
// every selection change. This is the AppKit analogue of the Tauri typewriter plugin (coordsAtPos +
// scrollTop += delta in src/editor/EditorController.ts): there we read the caret's screen coords and
// nudge the scroller by the gap to the viewport midpoint; here we read the caret glyph's bounding
// rect from the layout manager and scroll the clip view by the same gap.
//
// Markdown-as-truth is unaffected — this only scrolls; it never touches the buffer. Like the
// reference, we skip while an IME has marked (composing) text so we don't fight the candidate window.
//
// Wiring lives on EditorController (the responder in the menu chain). The on/off flag is a stored
// property the integrator adds in WindowFactory/EditorController (see sharedChanges), since an
// extension can't add stored state; textViewDidChangeSelection calls back in here while on.

import AppKit

extension EditorController {
    // MARK: menu action

    /// View ▸ Typewriter Scrolling toggle. Flips the per-window flag + the menu checkmark, and on
    /// enable centres the caret line immediately so "this line" jumps to the middle right away
    /// (matching the reference's setTypewriter → centerCaretNow; it doesn't wait for the next move).
    @objc func toggleTypewriter(_ sender: Any?) {
        typewriterOn.toggle()
        (sender as? NSMenuItem)?.state = typewriterOn ? .on : .off
        if typewriterOn { centerCaretLine() }
    }

    // MARK: centring (called on enable, and from textViewDidChangeSelection while on)

    /// Scroll so the caret's line sits at the scroll view's vertical centre. No-op when off, while an
    /// IME is composing (marked text), or when the caret rect can't be resolved yet (e.g. just after a
    /// buffer swap) — all mirroring the reference's guards. Only scrolls when the gap is ≥ 1pt so a
    /// caret already near centre doesn't jitter.
    func centerCaretLine() {
        guard typewriterOn else { return }
        // Skip during IME marked text — scrolling now would jump the candidate window (view.composing).
        guard !textView.hasMarkedText() else { return }
        guard let layoutManager = textView.layoutManager,
              let container = textView.textContainer,
              let clip = textView.enclosingScrollView?.contentView else { return }

        // Caret glyph rect in text-container space → text-view space (add the container origin). Using
        // the insertion point's glyph range gives the caret's line position even on an empty line.
        let caretCharRange = textView.selectedRange()
        let glyphRange = layoutManager.glyphRange(forCharacterRange: caretCharRange,
                                                  actualCharacterRange: nil)
        var caretRect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: container)
        // boundingRect is empty at the very end of the text / on a trailing empty line; fall back to
        // that line's fragment rect so the last line still centres. Skip the fallback on an empty doc
        // (no glyphs) — boundingRect's extra-line-fragment rect at location 0 is already correct there.
        if caretRect.isEmpty, layoutManager.numberOfGlyphs > 0 {
            let g = min(glyphRange.location, layoutManager.numberOfGlyphs - 1)
            caretRect = layoutManager.lineFragmentRect(forGlyphAt: g, effectiveRange: nil)
        }
        let origin = textView.textContainerOrigin
        let caretMidY = caretRect.midY + origin.y

        // Target: put caretMidY at the centre of the currently visible rectangle, then clamp to the
        // document so we never scroll past the top/bottom (AppKit analogue of scrollTop += delta).
        let visible = clip.bounds                 // visible rect in document (text-view) coordinates
        let desiredOriginY = caretMidY - visible.height / 2
        guard let documentHeight = textView.enclosingScrollView?.documentView?.frame.height else { return }
        let maxOriginY = max(0, documentHeight - visible.height)
        let clampedY = min(max(0, desiredOriginY), maxOriginY)

        // Don't nudge if we're already essentially centred (mirrors the |delta| < 1 short-circuit).
        guard abs(clampedY - visible.origin.y) >= 1 else { return }

        var target = visible.origin
        target.y = clampedY
        clip.scroll(to: target)
        textView.enclosingScrollView?.reflectScrolledClipView(clip)
    }
}
