// EditorLayoutDelegate — the NSLayoutManager delegate that renders Mallow's live preview at the GLYPH
// level: hidden markdown syntax becomes invisible AND zero-width, `- ` dashes render as `•`, task
// `[ ]`/`[x]` render as ☐/☑, table `|` render as spaces, folded lines collapse to zero height, and table
// rows gain vertical padding.
//
// This lives on its OWN object (installed by EditorViewModel.init) rather than on the SwiftUI
// representable's Coordinator, so the exact same glyph pipeline runs in the app AND in headless tests —
// table geometry, pill bounds, and padding invariants are measured against the real rendering. (It used
// to live on the Coordinator; headless tests then laid out UNSUBSTITUTED glyphs — visible pipes, advancing
// markers — and validated numbers the app never showed.)

import AppKit

final class EditorLayoutDelegate: NSObject, NSLayoutManagerDelegate {
    // Weak back-references: the view model OWNS this delegate, and NSLayoutManager's `delegate` is not a
    // zeroing reference — nothing here may keep vm/view alive or dangle if teardown order varies.
    private weak var vm: EditorViewModel?
    private weak var textView: MarkdownTextView?

    init(vm: EditorViewModel, textView: MarkdownTextView) {
        self.vm = vm
        self.textView = textView
    }

    /// Mark hidden-syntax glyphs as `.controlCharacter` — paired with the control-character action
    /// delegate below returning `.zeroAdvancement`, they render invisible AND truly zero-width. (The
    /// previous `.null` property only stopped the DRAWING: the glyphs kept their full font advances, so
    /// every hidden marker left a ghost gap — inline-code pills ran ~2 characters wide, `**` left holes
    /// around bold text, `#` indented headings, and table cells with markers drifted off their measured
    /// column slots.) Also substitutes a `•` glyph for unordered-list dashes. 1:1 char↔glyph so
    /// caret/selection offsets stay exact. Markers are hidden unconditionally (no caret-line reveal).
    func layoutManager(_ lm: NSLayoutManager,
                       shouldGenerateGlyphs glyphs: UnsafePointer<CGGlyph>,
                       properties props: UnsafePointer<NSLayoutManager.GlyphProperty>,
                       characterIndexes: UnsafePointer<Int>,
                       font: NSFont,
                       forGlyphRange glyphRange: NSRange) -> Int {
        guard let vm else { return 0 }
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
        // composing glyph can't be mis-hidden by a stale index that used to name a real marker
        // — its text would otherwise vanish until commit. NSNotFound when not composing → a no-op.
        let markedLo = (textView?.hasMarkedText() ?? false) ? (textView?.markedRange().location ?? NSNotFound)
                                                            : NSNotFound
        for i in 0 ..< glyphRange.length {
            let ch = characterIndexes[i]
            if ch >= markedLo {
                newGlyphs[i] = glyphs[i]; newProps[i] = props[i]   // composing region: render as typed
            } else if hidden.contains(ch) {
                newGlyphs[i] = glyphs[i]; newProps[i] = .controlCharacter; changed = true
            } else if let tg = taskGlyphs, let checked = taskBoxes[ch] {
                // Substitute ☐/☑ — or, if the font lacks the glyph (0), HIDE the inner char (.null:
                // invisible, advance kept — it's not in `hidden`, so the zero-advance path never sees it)
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

    /// Zero the advance of hidden-syntax glyphs. `shouldGenerateGlyphs` marks them `.controlCharacter`,
    /// which routes them here; `.zeroAdvancement` makes them invisible AND widthless — the actual hiding.
    /// REAL control characters (newline / tab / CR — never in `hiddenChars`, but guarded anyway so a
    /// stale set can't swallow a line break) keep their default action, as does anything not hidden.
    func layoutManager(_ lm: NSLayoutManager,
                       shouldUse action: NSLayoutManager.ControlCharacterAction,
                       forControlCharacterAt charIndex: Int) -> NSLayoutManager.ControlCharacterAction {
        guard let vm, vm.hiddenChars.contains(charIndex), let ts = lm.textStorage,
              charIndex < ts.length else { return action }
        let ch = ts.mutableString.character(at: charIndex)
        if ch == 10 || ch == 13 || ch == 9 { return action }   // \n \r \t — never zero a real break
        return .zeroAdvancement
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
        guard let vm, !vm.foldedChars.isEmpty || !vm.tableRowChars.isEmpty else { return false }
        let charStart = lm.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil).location
        // IME guard, matching the glyph delegate: foldedChars / tableRowChars are FROZEN at
        // pre-composition offsets while a composition is live, so a now-shifted VISIBLE line whose start
        // collides with a stale folded index would wrongly collapse to zero height (its text vanishes
        // mid-composition). Don't override geometry from the marked-range start onward; commit re-derives.
        if let tv = textView, tv.hasMarkedText(), charStart >= tv.markedRange().location { return false }
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
    /// width, so columns stay aligned while the bar disappears. 0 if the font lacks it.
    private static func spaceGlyph(for font: NSFont) -> CGGlyph {
        var ch: UniChar = 0x20
        var glyph = CGGlyph(0)
        CTFontGetGlyphsForCharacters(font as CTFont, &ch, &glyph, 1)
        return glyph
    }
}
