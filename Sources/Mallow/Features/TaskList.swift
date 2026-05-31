// TaskList — GFM task-list checkbox rendering + click-to-toggle for the SwiftUI editor.
//
// GFM task lists are parsed by the engine as ordinary `List` blocks whose items start with a literal
// `[ ]` / `[x]` / `[X]` checkbox right after the bullet (`- [ ] do thing`). EditorViewModel already
// keeps that box VISIBLE as part of the list marker (its private `MarkerGrammar.skipTaskBox` walks
// past it) — so it currently shows as the three raw characters `[`, ` `, `]`.
//
// This file adds two contributions, mirroring the existing `-`→`•` bullet substitution exactly:
//
//   1. Detection (`TaskBoxScanner`): a PURE scanner that walks each list item's line-leading marker
//      prefix (indent → nested `>` → bullet → `[ ]`) and returns, for every checkbox, the UTF-16
//      index of its INNER character (the ` `/`x`/`X` between the brackets) and whether it is checked.
//      It deliberately re-derives the same walk `MarkerGrammar` does, because `MarkerGrammar` is
//      `private` to EditorViewModel.swift and cannot be imported here.
//
//   2. Glyph substitution plan: the editor renders the box as a single checkbox glyph by
//        • HIDING the two bracket chars `[` (boxStart) and `]` (boxStart+2)  — add them to hiddenChars
//        • SUBSTITUTING the inner char (boxStart+1) with ☐ U+2610 / ☑ U+2611 — like the bullet glyph
//      That is 3 source chars → 2 hidden + 1 substituted = a 1:1 char↔glyph mapping with NO collapse
//      of count, so every caret/selection offset downstream stays byte-exact (the same invariant the
//      `•` substitution relies on). Off the caret's own line only: on the caret line the raw `[ ]`
//      shows for editing, identical to how bullets/`#`/`**` reveal there.
//
//   3. Click toggle (`Coordinator.toggleTaskBoxAt`): given a clicked character index, if it lands on
//      (or adjacent to) a checkbox, flip the inner char ` ` ↔ `x` through the SAME undoable text path
//      the engine commands use (`shouldChangeText` / `replaceCharacters` / `didChangeText`), then
//      `refresh()`. ⌘Z reverts a toggle like any edit.
//
// These contributions are wired into EditorViewModel, the glyph delegate, and the click recognizer.
// NOTHING here edits existing files.

import AppKit
import CoreText

// MARK: - Detection (pure)

/// A pure scanner over the buffer that finds GFM task-list checkboxes inside `List` blocks and reports
/// each one's inner-character UTF-16 index + checked state. It owns no editor state; feed it the source
/// string and the parsed blocks. Mirrors EditorViewModel's private `MarkerGrammar` marker walk so the
/// boxes it finds are exactly the ones the marker pass keeps visible (no drift between the two walks).
///
/// All indices are UTF-16 (NSString domain), consistent with `hiddenChars` / `bulletMarks`.
struct TaskBoxScanner {
    let s: String          // the live source (textView.string)
    let ns: NSString       // same string as NSString, for character(at:) — caller may pass `s as NSString`

    init(_ s: String) {
        self.s = s
        self.ns = s as NSString
    }

    /// Marker whitespace: ASCII space (32) or tab (9). (Same predicate as `MarkerGrammar.isMarkerSpace`.)
    private func isMarkerSpace(_ c: unichar) -> Bool { c == 32 || c == 9 }

    /// If a checkbox `[ ]` / `[x] `/ `[X]` opens at UTF-16 index `start` (must be followed by a marker
    /// space, so it is a real task box and not e.g. `[link]`), return its layout:
    ///   - `box`     = index of `[`            (= `start`)            → HIDE
    ///   - `inner`   = index of the inner char (= `start + 1`)        → SUBSTITUTE with ☐/☑
    ///   - `close`   = index of `]`            (= `start + 2`)        → HIDE
    ///   - `checked` = inner char is `x`/`X`
    /// Returns nil when `start` does not open a checkbox. This is the per-box analogue of
    /// `MarkerGrammar.skipTaskBox`, but it RECORDS the indices instead of just skipping them.
    private func taskBoxAt(_ start: Int, _ lineHi: Int)
        -> (box: Int, inner: Int, close: Int, checked: Bool)? {
        // Need `[ X ] <space>` → at least 4 chars ([ , inner, ], space) available before lineHi.
        guard start + 3 < lineHi, ns.character(at: start) == 91 /* [ */ else { return nil }
        let inner = ns.character(at: start + 1)
        let isSpace = inner == 32
        let isChecked = inner == 120 || inner == 88   // x / X
        guard isSpace || isChecked,
              ns.character(at: start + 2) == 93 /* ] */,
              isMarkerSpace(ns.character(at: start + 3)) else { return nil }
        return (box: start, inner: start + 1, close: start + 2, checked: isChecked)
    }

    /// Walk a single line's leading marker prefix exactly like `MarkerGrammar.markerPrefixEnd`
    /// (indent → nested `>` → bullet `-`/`*`/`+` OR ordered `N.`/`N)`), and if a task box opens right
    /// after the bullet/number, return its layout. Returns nil for non-task list lines / paragraphs.
    ///
    /// `lineLo` / `lineHi` are the UTF-16 bounds of the line (clamped to the block in the caller).
    private func taskBoxOnLine(_ lineLo: Int, _ lineHi: Int)
        -> (box: Int, inner: Int, close: Int, checked: Bool)? {
        var i = lineLo
        while i < lineHi && isMarkerSpace(ns.character(at: i)) { i += 1 }   // indent
        while i < lineHi {
            let c = ns.character(at: i)
            if c == 62 /* > */ {                         // blockquote prefix (may nest: `> > `, `> - `)
                i += 1
                if i < lineHi && isMarkerSpace(ns.character(at: i)) { i += 1 }
                continue
            }
            if c == 45 || c == 42 || c == 43 /* - * + */,
               i + 1 < lineHi, isMarkerSpace(ns.character(at: i + 1)) {
                return taskBoxAt(i + 2, lineHi)          // box (if any) sits right after `- `
            }
            if c >= 48 && c <= 57 /* digit */ {          // ordered list: `N.` / `N)` then a box
                var j = i
                while j < lineHi && ns.character(at: j) >= 48 && ns.character(at: j) <= 57 { j += 1 }
                if j < lineHi, ns.character(at: j) == 46 || ns.character(at: j) == 41 /* . ) */,
                   j + 1 < lineHi, isMarkerSpace(ns.character(at: j + 1)) {
                    return taskBoxAt(j + 2, lineHi)
                }
                return nil                               // bare number = content, not a marker
            }
            return nil                                   // first non-quote char isn't a list marker
        }
        return nil
    }

    /// Scan the half-open UTF-16 range `[lo, hi)` (a single List block's span, clamped) line by line,
    /// collecting every checkbox as `innerIndex → checked`. The KEY is the inner char's UTF-16 index
    /// (the char to substitute with ☐/☑ and the char a toggle rewrites); the close/open brackets are at
    /// `inner-1` / `inner+1`, so the caller can derive them without a richer struct.
    func boxes(in lo: Int, _ hi: Int) -> [Int: Bool] {
        var found: [Int: Bool] = [:]
        let total = ns.length
        let rangeHi = min(hi, total)
        var lineStart = max(0, lo)
        while lineStart < rangeHi {
            let line = ns.lineRange(for: NSRange(location: lineStart, length: 0))
            let lineHi = min(line.location + line.length, rangeHi)
            if let b = taskBoxOnLine(line.location, lineHi) {
                found[b.inner] = b.checked
            }
            if line.length == 0 { break }                // guard against a zero-length tail loop
            lineStart = line.location + line.length
        }
        return found
    }

    /// Convenience: scan ALL `List` blocks in one parse and return the merged `innerIndex → checked`
    /// map. `byteToUTF16` bridges each block's engine BYTE range to UTF-16 (same as recomputeHidden).
    /// EditorViewModel should call this from `recomputeHidden` and store the result in `vm.taskBoxes`,
    /// dropping any box on the caret's own line (so the raw `[ ]` is editable there) — see notes below.
    func allBoxes(_ blocks: [PBlock]) -> [Int: Bool] {
        var out: [Int: Bool] = [:]
        for block in blocks where block.kindTag == "List" {
            let bLo = byteToUTF16(s, block.range.start)
            let bHi = byteToUTF16(s, block.range.end)
            for (inner, checked) in boxes(in: bLo, bHi) { out[inner] = checked }
        }
        return out
    }
}

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
        let s = textView.string
        let ns = s as NSString
        let total = ns.length
        guard total > 0 else { return false }

        // Re-scan the clicked line's checkboxes. We only need this one line, so bound the scan to it
        // (cheap, and avoids depending on the VM's cached parse). The scanner's box keys are inner-char
        // indices; the line walk guarantees they are genuine task boxes, not arbitrary `[` chars.
        let probe = max(0, min(charIndex, total - 1))
        let line = ns.lineRange(for: NSRange(location: probe, length: 0))
        let lineBoxes = TaskBoxScanner(s).boxes(in: line.location, line.location + line.length)
        guard !lineBoxes.isEmpty else { return false }

        // A click resolves to an insertion index; accept a hit on the inner char or either bracket so the
        // whole rendered box (`[`, inner, `]`) is a live target. innerIndex is what we rewrite.
        // candidates maps a clicked index → the inner index it would belong to.
        func innerFor(_ idx: Int) -> Int? {
            if lineBoxes[idx] != nil { return idx }          // landed exactly on the inner char
            if lineBoxes[idx - 1] != nil { return idx - 1 }  // landed on `]` (inner is idx-1)
            if lineBoxes[idx + 1] != nil { return idx + 1 }  // landed on `[` (inner is idx+1)
            return nil
        }
        guard let inner = innerFor(charIndex),
              let isChecked = lineBoxes[inner],
              inner >= 0, inner < total else { return false }

        // Flip the single inner char: ' ' → 'x' (check) or 'x'/'X' → ' ' (uncheck).
        let replacement = isChecked ? " " : "x"
        let editRange = NSRange(location: inner, length: 1)

        // Undoable replace over just the inner char — same pattern as EditorViewModel.replace(with:):
        // go through shouldChangeText / replaceCharacters / didChangeText so ⌘Z reverts the toggle and
        // the existing undo stack is preserved (NEVER assign textView.string — that drops undo).
        guard textView.shouldChangeText(in: editRange, replacementString: replacement) else { return false }
        textView.textStorage?.replaceCharacters(in: editRange, with: replacement)
        textView.didChangeText()

        // Keep the caret stable next to the box (a 1:1 single-char swap doesn't shift later offsets).
        textView.setSelectedRange(NSRange(location: inner + 1, length: 0))

        // Recompute parse → style → hidden → glyphs so the box redraws as ☐/☑ immediately. (Note:
        // textDidChange would also fire from didChangeText and call refresh; calling it here as well is
        // harmless and makes the toggle self-contained, but the lead may rely on the delegate instead.)
        doc.vm.refresh()
        doc.revision &+= 1
        return true
    }
}

// MARK: - Click recognizer target (optional helper for makeNSView)

/// A tiny click-gesture target the representable can attach to the text view in `makeNSView`, so a
/// single click on a checkbox toggles it. Kept as a standalone NSObject (not the Coordinator) so it can
/// be retained by the gesture recognizer without a retain cycle through the delegate; it holds a weak
/// ref to the text view and resolves the clicked character via `characterIndexForInsertion(at:)`.
///
/// Wiring (see notes): in `makeNSView`, after setting up the text view, create one of these and add an
/// `NSClickGestureRecognizer(target:action:)` to `textView`. The recognizer fires BEFORE the text view
/// consumes the click for caret placement when `delaysPrimaryMouseButtonEvents`/order is set up right;
/// if a box is hit we toggle and (optionally) the lead can decide whether to also let the click set the
/// caret. The simplest robust approach is to only toggle and otherwise let the event pass through.
final class TaskBoxClickTarget: NSObject {
    weak var textView: MarkdownTextView?
    weak var coordinator: MarkdownEditor.Coordinator?

    init(textView: MarkdownTextView, coordinator: MarkdownEditor.Coordinator) {
        self.textView = textView
        self.coordinator = coordinator
    }

    /// Action for an `NSClickGestureRecognizer` attached to the text view. Maps the click point to a
    /// character index and asks the coordinator to toggle a box there.
    @objc func handleClick(_ gr: NSClickGestureRecognizer) {
        guard let textView, let coordinator else { return }
        // Click point in the text view's coordinate space → the nearest insertion character index.
        let p = gr.location(in: textView)
        let idx = textView.characterIndexForInsertion(at: p)
        _ = coordinator.toggleTaskBoxAt(idx)
    }
}
