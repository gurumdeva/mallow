// RenderModel — the SINGLE definition of how source characters render at the glyph level, shared by
// the three places that must agree on it:
//
//   1. RENDERING   — EditorLayoutDelegate substitutes glyphs/properties from these rules.
//   2. MEASUREMENT — TableRendering measures cell/separator widths by simulating the SAME rules in
//                    CoreText (hidden chars contribute nothing; a table `|` advances as one space).
//   3. ANCHORING   — MarkdownTextView.decorationAnchors skips glyphs carrying these properties when
//                    hunting for the first VISIBLE glyph of a range.
//
// History (why this type exists): each of these used to hardcode its own copy of the rules, and every
// desync shipped as a cross-feature regression — hidden markers that measured zero-width but rendered
// with full advances (ghost-wide pills, drifting table columns), and tests that laid out different
// glyphs than the app. If a rule changes (a new substitution, a different hiding property), change it
// HERE and the three consumers follow; adding a substitution the measurement can't see is now a visible
// diff in one file instead of a silent drift across three.

import AppKit

enum RenderModel {
    /// The glyph property that hides a syntax marker. Paired with `hiddenAction` below via the
    /// control-character delegate route, it makes the glyph invisible AND truly zero-width.
    /// (`.null` alone only suppresses DRAWING — the glyph keeps its font advance; that ghost width
    /// was the root cause of the v1.2.0 pill/table regressions.)
    static let hiddenGlyphProperty: NSLayoutManager.GlyphProperty = .controlCharacter

    /// The control-character action that zeroes a hidden glyph's advance.
    static let hiddenAction: NSLayoutManager.ControlCharacterAction = .zeroAdvancement

    /// The glyph property for the task-box FALLBACK (font lacks ☐/☑ → hide the inner char instead of
    /// leaking the raw bracket content). Deliberately `.null`, NOT the zero-advance hidden property:
    /// the fallback char is not in `hiddenChars`, so the control-character route never sees it — it
    /// stays invisible but keeps its advance, preserving the box's caret slot.
    static let taskFallbackProperty: NSLayoutManager.GlyphProperty = .null

    /// True if `property` marks a glyph that contributes no visible ink — the set decoration anchoring
    /// must skip. (Hidden markers are `.controlCharacter`; the task fallback is `.null`.)
    static func isInvisible(_ property: NSLayoutManager.GlyphProperty) -> Bool {
        property.contains(.controlCharacter) || property.contains(.null)
    }

    /// What a source character CONTRIBUTES TO LAYOUT WIDTH under the substitution rules, for
    /// measurement code that simulates rendering in CoreText (TableRendering's spanWidth/visibleWidth):
    ///   - a hidden char contributes nothing (zero advance),
    ///   - a table `|` advances as exactly one SPACE (the delegate substitutes a space glyph),
    ///   - everything else advances as itself.
    /// Returns the stand-in string to measure, or nil for "contributes nothing".
    ///
    /// NOTE for future substitutions: if the delegate ever substitutes MORE kinds (it already draws
    /// `-`→`•` and `[x]`→☑ via `bulletMarks`/`taskBoxes`), any of those appearing INSIDE a table cell
    /// must gain a stand-in here too, or cell measurement drifts from rendering — the exact historical
    /// bug class. Bullets/task boxes cannot appear inside GFM table cells today (they are list-item
    /// constructs), which is why the two-rule model below is complete for the table pass.
    static func measurementStandIn(char: unichar, isHidden: Bool, pipesAsSpaces: Bool) -> String? {
        if isHidden { return nil }
        if pipesAsSpaces && char == 124 { return " " }   // '|' renders as a space glyph
        return nil                                        // no substitution — measure the char itself
    }
}
