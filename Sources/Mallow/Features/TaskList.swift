// TaskList — GFM task-list checkbox rendering + click-to-toggle (shipped behavior; this header
// describes what IS wired, not a plan).
//
// GFM task lists are parsed by the engine as ordinary `List` blocks whose items start with a literal
// `[ ]` / `[x]` / `[X]` right after the bullet (`- [ ] do thing`). This file provides:
//
//   1. Detection (`MarkerGrammar.boxes(in:)` / `.taskBox(onLine:)` in HiddenSyntax.swift): the ONE
//      line-leading marker walk (indent → nested `>` → bullet → `[ ]`) returns, for every checkbox, the
//      UTF-16 index of its INNER character (the ` `/`x`/`X` between the brackets) and whether it is
//      checked. The hide pass (which box to keep visible) and this file's click-toggle (which box to
//      flip) both read that one walk, so they cannot drift. (This detection used to be a second copy —
//      TaskBoxScanner — kept in lockstep by hand; it was collapsed onto MarkerGrammar.)
//
//   2. Rendering (wired via HiddenSyntax + EditorLayoutDelegate): the two brackets are HIDDEN
//      (zero-width) and the inner char is SUBSTITUTED with ☐ U+2610 / ☑ U+2611 — 3 source chars →
//      2 hidden + 1 substituted, a 1:1 char↔glyph mapping so caret/selection offsets stay exact.
//      Markers are hidden unconditionally (no caret-line reveal).
//
//   3. Click toggle (`Coordinator.toggleTaskBoxAt`, target of the NSClickGestureRecognizer wired in
//      MarkdownEditor.makeNSView): flips the inner char ` ` ↔ `x` through the undoable text path
//      (`shouldChangeText` / `replaceCharacters` / `didChangeText`); ⌘Z reverts like any edit.

import AppKit
import CoreText

// Task-list checkbox DETECTION lives in `MarkerGrammar` (HiddenSyntax.swift): `boxes(in:)` /
// `allBoxes(_:map:)` / `taskBox(onLine:)`. It was previously a second copy here (`TaskBoxScanner`) that
// re-derived MarkerGrammar's marker walk and had to be kept in lockstep by hand; it was collapsed onto
// the one walk so the box the hide pass keeps visible can't drift from the box a click toggles.

// MARK: - Glyph substitution helper (for the layout-manager delegate)

/// The checkbox-glyph contribution for the glyph-generation delegate. Holds the two checkbox glyph ids
/// for a given font (resolved once per delegate call, like `bulletGlyph(for:)`), and answers "what
/// glyph should render at this inner-char index?". Returns 0 when the font lacks the glyph, in which
/// case the delegate must fall back to the literal character (never draw a missing-glyph box).
struct TaskBoxGlyphs {
    let empty: CGGlyph     // ☐ U+2610  (unchecked)
    let checked: CGGlyph   // ☑ U+2611  (checked)

    /// Resolve both checkbox glyph ids in `font`. SF Pro lacks ☐ (U+2610) even though it has ☑ (U+2611),
    /// so the empty box falls back through square candidates the body font DOES contain (□ U+25A1, ⬜
    /// U+2B1C). A glyph id resolves in THIS font, so a fallback only "wins" when the font has that scalar,
    /// which keeps the substituted box rendering correctly inline.
    init(font: NSFont) {
        empty = Self.firstGlyph([0x2610, 0x25A1, 0x2B1C], font)
        checked = Self.firstGlyph([0x2611, 0x2705, 0x2713], font)
    }

    private static func firstGlyph(_ scalars: [UniChar], _ font: NSFont) -> CGGlyph {
        for s in scalars {
            let g = glyph(s, font)
            if g != 0 { return g }
        }
        return 0
    }

    private static func glyph(_ scalar: UniChar, _ font: NSFont) -> CGGlyph {
        var ch = scalar
        var g = CGGlyph(0)
        CTFontGetGlyphsForCharacters(font as CTFont, &ch, &g, 1)
        return g
    }

    /// The glyph to substitute for the inner char of a box, or 0 if unavailable (→ keep literal char).
    func glyph(checked isChecked: Bool) -> CGGlyph { isChecked ? checked : empty }

    var hasGlyphs: Bool { empty != 0 && checked != 0 }
}

// MARK: - Click-to-toggle (Coordinator)

extension MarkdownEditor.Coordinator {
    /// Toggle the GFM checkbox at (or next to) character index `charIndex`. Returns true if a box was
    /// found and flipped, false otherwise (so the caller can fall through to normal click handling).
    ///
    /// `characterIndexForInsertion(at:)` returns an INSERTION index, which for a click on the glyph can
    /// land either on the inner char itself or just before/after it. We therefore probe the clicked
    /// index and its immediate neighbours, then confirm via the scanner that the candidate truly sits on
    /// a checkbox inner char (so a stray click on a literal `[` elsewhere never toggles). The rewrite is
    /// a single-char `replaceCharacters` over the inner char, routed through the undoable text path —
    /// identical to how `EditorViewModel.replace(with:)` applies an engine command — and is followed by
    /// `refresh()` so styling / hidden-syntax / glyphs recompute.
    ///
    /// All offsets are UTF-16 (NSString / NSTextView domain).
    @discardableResult
    func toggleTaskBoxAt(_ charIndex: Int) -> Bool {
        let textView = doc.textView
        // Don't mutate the buffer mid-IME-composition: a programmatic replaceCharacters while the input
        // context holds a marked range can crash (NSRangeException) or mangle the half-typed syllable.
        guard !textView.hasMarkedText() else { return false }
        let s = textView.string
        let ns = s as NSString
        let total = ns.length
        guard total > 0 else { return false }

        // Re-scan the clicked line's checkboxes. We only need this one line, so bound the scan to it
        // (cheap, and avoids depending on the VM's cached parse). The scanner's box keys are inner-char
        // indices; the line walk guarantees they are genuine task boxes, not arbitrary `[` chars.
        let probe = max(0, min(charIndex, total - 1))
        let line = ns.lineRange(for: NSRange(location: probe, length: 0))
        let lineBoxes = MarkerGrammar(ns: CharBuffer(ns)).boxes(in: line.location, line.location + line.length)
        guard !lineBoxes.isEmpty else { return false }

        // A click resolves to an insertion index; accept a hit on the inner char or either bracket so the
        // whole rendered box (`[`, inner, `]`) is a live target. innerIndex is what we rewrite.
        // candidates maps a clicked index → the inner index it would belong to.
        func innerFor(_ idx: Int) -> Int? {
            if lineBoxes[idx] != nil { return idx }          // landed exactly on the inner char
            if lineBoxes[idx - 1] != nil { return idx - 1 }  // landed on `]` (inner is idx-1)
            if lineBoxes[idx + 1] != nil { return idx + 1 }  // landed on `[` (inner is idx+1)
            // The line-leading marker prefix (indent + `- `) is hidden/zero-width and shares the rendered
            // ☐'s x, so a click on the box can resolve to a prefix index just LEFT of it. Map any on-line
            // click at or left of a box (but not out on the task text, which is right of `]`) to that box.
            return lineBoxes.keys.filter { idx <= $0 + 1 }.min()
        }
        guard let inner = innerFor(charIndex),
              let isChecked = lineBoxes[inner],
              inner >= 0, inner < total,
              // Only toggle a box the ENGINE recognized as a task marker. The line scan alone also matches a
              // literal `- [ ] …` sitting INSIDE a fenced code block (rendered verbatim, no ☐), so without
              // this a click there would silently edit the code sample. `vm.taskBoxes` excludes those.
              doc.vm.taskBoxes[inner] != nil else { return false }

        // Flip the single inner char: ' ' → 'x' (check) or 'x'/'X' → ' ' (uncheck).
        let replacement = isChecked ? " " : "x"
        let editRange = NSRange(location: inner, length: 1)

        // Undoable replace over just the inner char — same pattern as EditorViewModel.replace(with:):
        // go through shouldChangeText / replaceCharacters / didChangeText so ⌘Z reverts the toggle and
        // the existing undo stack is preserved (NEVER assign textView.string — that drops undo).
        guard textView.replaceCharactersUndoably(in: editRange, with: replacement) else { return false }

        // Keep the caret stable next to the box (a 1:1 single-char swap doesn't shift later offsets).
        textView.setSelectedRange(NSRange(location: inner + 1, length: 0))

        // Recompute parse → style → hidden → glyphs so the box redraws as ☐/☑ immediately. (Note:
        // textDidChange would also fire from didChangeText and call refresh; calling it here as well is
        // harmless and makes the toggle self-contained, but the lead may rely on the delegate instead.)
        doc.vm.refresh()
        doc.markEdited()
        return true
    }
}
