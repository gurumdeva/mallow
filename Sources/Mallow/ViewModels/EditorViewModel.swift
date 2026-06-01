// EditorViewModel — the editor's brain (the logic the old EditorController god-object mixed with
// window/menu plumbing). It owns the document state (file path, saved baseline, the cached parse,
// focus mode) and all the engine-driven work: parsing, live-preview styling, hide-syntax glyph
// computation, focus dimming, and command application. It drives an injected MarkdownTextView's
// storage; the EditorController owns the window/views and forwards delegate + menu events here.

import AppKit

final class EditorViewModel {
    private weak var textView: MarkdownTextView?

    var filePath: String?
    private(set) var baseline = ""
    private var blocks: [PBlock] = []           // cached parse (one parse per text change)
    private(set) var hiddenChars = Set<Int>()   // UTF-16 indices of collapsed syntax glyphs (read by the layout-manager delegate)
    private(set) var bulletMarks = Set<Int>()   // UTF-16 indices of unordered `- ` dashes to render as `•` (glyph delegate)
    private(set) var taskBoxes = [Int: Bool]()  // UTF-16 index of a task `[ ]`/`[x]` inner char → isChecked (glyph delegate ☐/☑)
    private(set) var tablePipes = Set<Int>()    // UTF-16 indices of GFM table `|` to render as a space (glyph delegate)
    var focusMode = false                        // dim every block but the caret's
    var keepOnTop = false                         // pin this window above other apps (transient, per-window)
    var typewriterOn = false                      // View ▸ Typewriter Scrolling: keep the caret line centered (per-window)
    var zoomFactor: CGFloat = 1                   // text zoom (View ▸ Zoom); per-window, resets each launch

    private var lastCaretLoc = 0                  // previous caret UTF-16 location — gives the hidden-run snap its direction
    private var isAdjustingSelection = false      // guards the re-entrant setSelectedRange in `snapCaretOutOfHiddenRuns`

    private let baseSize: CGFloat = 16   // Mallow body size; SANS (mono only for code)
    private let fm = NSFontManager.shared
    // Computed (not a stored lazy) so it always reflects the current zoomFactor.
    private var baseFont: NSFont { NSFont.systemFont(ofSize: baseSize * zoomFactor, weight: .regular) }

    init(textView: MarkdownTextView) {
        self.textView = textView
        baseline = textView.string
    }

    // MARK: derived state for the chrome

    var isDirty: Bool { inkIsDirty(textView?.string ?? "", baseline) }
    var displayName: String { (filePath as NSString?)?.lastPathComponent ?? L.t("doc.untitled") }
    /// `displayName` without a trailing `.md` (export filename / document title). Suffix-only — a blind
    /// `.replacingOccurrences(of:".md")` would mangle names like "notes.md.md" or "a.md.txt".
    var baseName: String {
        let n = displayName
        return n.lowercased().hasSuffix(".md") ? String(n.dropLast(3)) : n
    }

    func setPath(_ path: String?) { filePath = path }
    func markSaved(path: String, content: String) { filePath = path; baseline = content }

    // MARK: pipeline — parse once, then style + compute hidden syntax + focus.

    func refresh() {
        guard let textView else { return }
        blocks = inkParseBlocks(textView.string)
        restyle()
        recomputeHidden()
        applyFocus()
    }

    /// The caret moved. Hidden syntax is caret-independent (markers are always hidden), so the only
    /// work is (a) keeping the caret/selection out of a hidden run's interior, and (b) focus mode
    /// re-dimming around the new caret block. Text is unchanged → the cached parse stands.
    func selectionChanged() {
        if isAdjustingSelection { return }   // re-entrant call from the snap's own setSelectedRange
        snapCaretOutOfHiddenRuns()
        if focusMode { restyle(); applyFocus() }
    }

    // MARK: caret / selection vs hidden syntax
    //
    // Hidden markers are zero-width glyphs, so a click or drag can land the caret (or a selection
    // endpoint) *inside* a hidden run — e.g. between the `(` and `)` of a link's `](url)` — where
    // every position shares one x and is visually indistinguishable. That makes the caret feel
    // stuck and a selection's range disagree with what's highlighted. Since markers don't exist as
    // far as the cursor is concerned, an endpoint never rests in a run's interior:
    //   • a bare caret jumps out to the run edge in its direction of travel (so ← / → step over a
    //     whole marker in one press), and
    //   • a selection grows to fully contain any partially-covered run (so selecting a link is
    //     atomic — the whole `[text](url)` — and the highlight matches the visible text exactly).
    private func snapCaretOutOfHiddenRuns() {
        guard let textView, !textView.hasMarkedText() else { return }  // never fight an IME composition
        // Don't mutate the selection in the middle of a live mouse-drag — NSTextView is tracking the
        // drag and re-deriving the range from the mouse each frame, so changing it here would fight
        // the tracking loop. The drag's end (mouseUp / a click's mouseDown) and arrow keys/shift-
        // select still snap; only the intermediate drag frames are skipped.
        if NSApp.currentEvent?.type == .leftMouseDragged { return }
        let total = (textView.string as NSString).length
        let sel = textView.selectedRange()
        let fixed = snappedSelection(sel, total: total)
        if fixed != sel {
            isAdjustingSelection = true
            textView.setSelectedRange(fixed)
            isAdjustingSelection = false
        }
        lastCaretLoc = textView.selectedRange().location
    }

    /// Pure geometry for `snapCaretOutOfHiddenRuns` (see it for the why). A boundary is "interior"
    /// to a hidden run only when the chars on BOTH sides are hidden — so a run's outer edges, where
    /// the caret meets visible text, stay valid landing spots. A bare caret's escape direction
    /// comes from `lastCaretLoc`; a range grows each interior endpoint outward to the run edge.
    private func snappedSelection(_ sel: NSRange, total: Int) -> NSRange {
        let hidden = hiddenChars
        if hidden.isEmpty { return sel }
        func interior(_ b: Int) -> Bool { b > 0 && b < total && hidden.contains(b) && hidden.contains(b - 1) }
        func runEnd(_ b: Int) -> Int { var e = b; while e < total, hidden.contains(e) { e += 1 }; return e }
        func runStart(_ b: Int) -> Int { var s = b; while s > 0, hidden.contains(s - 1) { s -= 1 }; return s }
        if sel.length == 0 {
            let b = sel.location
            guard interior(b) else { return sel }
            return NSRange(location: b >= lastCaretLoc ? runEnd(b) : runStart(b), length: 0)
        }
        var lo = sel.location, hi = sel.location + sel.length
        if interior(lo) { lo = runStart(lo) }
        if interior(hi) { hi = runEnd(hi) }
        return NSRange(location: lo, length: hi - lo)
    }

    // MARK: focus mode

    /// Overlay a dim foreground on everything outside the caret's block. No-op if off / between blocks.
    func applyFocus() {
        guard focusMode, let textView, let storage = textView.textStorage else { return }
        let s = textView.string
        let nsLen = (s as NSString).length
        let caretChar = utf16ToChar(s, textView.selectedRange().location)
        let caretByte = inkCharToByte(s, caretChar)
        let json = inkFocusDecoration(s, caretByte)
        guard let deco = try? JSONDecoder().decode(PDecoration.self, from: Data(json.utf8)) else {
            return  // "null" — caret between blocks; leave the document fully styled
        }
        let lo = max(0, byteToUTF16(s, deco.range.start))
        let hi = min(byteToUTF16(s, deco.range.end), nsLen)
        let dim = NSColor.tertiaryLabelColor
        storage.beginEditing()
        if lo > 0 { storage.addAttribute(.foregroundColor, value: dim,
                                         range: NSRange(location: 0, length: lo)) }
        if hi < nsLen { storage.addAttribute(.foregroundColor, value: dim,
                                             range: NSRange(location: hi, length: nsLen - hi)) }
        storage.endEditing()
    }

    private func font(for marks: [String]) -> NSFont {
        var f = marks.contains("Code")   // inline code shrinks to 0.92em (CSS) in mono
            ? NSFont.monospacedSystemFont(ofSize: baseSize * 0.92 * zoomFactor, weight: .regular) : baseFont
        if marks.contains("Strong") { f = fm.convert(f, toHaveTrait: .boldFontMask) }
        if marks.contains("Emphasis") { f = fm.convert(f, toHaveTrait: .italicFontMask) }
        return f
    }

    func restyle() {
        guard let textView else { return }
        let s = textView.string
        guard let storage = textView.textStorage else { return }
        let nsLen = (s as NSString).length

        func nsRange(_ r: PRange) -> NSRange? { r.utf16Range(in: s, clampedTo: nsLen) }

        var quotes: [NSRange] = []   // blockquote ranges → 3px left bar drawn by the text view
        var rules: [NSRange] = []    // thematic-break ranges → 1px rule drawn by the text view
        var codeCards: [NSRange] = [] // code-block ranges → rounded elevated card drawn by the text view
        var tableCards: [NSRange] = [] // GFM table ranges → rounded surface card (monospace cells, dimmed pipes)

        storage.beginEditing()
        storage.setAttributes([.font: baseFont, .foregroundColor: NSColor.labelColor,
                               .paragraphStyle: mallowBodyParagraphStyle],
                              range: NSRange(location: 0, length: nsLen))
        for block in blocks {
            switch block.kindTag {
            case "Heading":
                if let level = block.headingLevel, let nr = nsRange(block.range) {
                    let hz: CGFloat = (level == 1 ? 28 : level == 2 ? 22 : level == 3 ? 18 : 16) * zoomFactor  // Mallow sizes × zoom
                    storage.addAttribute(.font, value: NSFont.boldSystemFont(ofSize: hz), range: nr)
                }
                continue  // heading text is uniform — no inline pass
            case "CodeBlock":
                if let nr = nsRange(block.range) {
                    storage.addAttribute(.font,   // code is uniform monospace
                        value: NSFont.monospacedSystemFont(ofSize: baseSize * zoomFactor, weight: .regular), range: nr)
                    storage.addAttribute(.paragraphStyle, value: mallowCodeParagraphStyle, range: nr)
                    codeCards.append(nr)   // drawn as a rounded elevated card (corners + right inset the attribute can't give)
                }
                continue  // uniform mono — no inline pass
            case "BlockQuote":
                if let nr = nsRange(block.range) {
                    storage.addAttribute(.foregroundColor, value: mallowDim, range: nr)         // #98989d, not white-α
                    storage.addAttribute(.paragraphStyle, value: mallowQuoteParagraphStyle, range: nr)
                    quotes.append(nr)
                }
            case "ThematicBreak":
                if let nr = nsRange(block.range) { rules.append(nr) }   // dashes hidden; a rule is drawn instead
            case "Table":
                if let nr = TableRendering.style(block, source: s, storage: storage) { tableCards.append(nr) }
                continue   // TableRendering owns the cell font + dimmed pipes; skip the generic inline pass
            default:
                break
            }
            for inline in block.inlines {
                guard let nr = nsRange(inline.range) else { continue }
                storage.addAttribute(.font, value: font(for: inline.marks), range: nr)
                if inline.marks.contains("Strikethrough") {
                    storage.addAttribute(.strikethroughStyle,
                                         value: NSUnderlineStyle.single.rawValue, range: nr)
                }
                if inline.marks.contains("Code") {
                    storage.addAttribute(.backgroundColor, value: mallowElevated, range: nr)   // solid #2c2c2e pill
                }
                if inline.kindTag == "Link" {
                    storage.addAttribute(.foregroundColor, value: NSColor.linkColor, range: nr)
                    storage.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: nr)
                }
            }
        }

        // Frontmatter: a leading `--- … ---` YAML block. The engine mis-parses it (line-1 thematic break,
        // and the closing `---` turns the keys into a setext H2), so without this it renders as a bold
        // heading with a rule above it. It's metadata, not content — restyle the whole block as a quiet,
        // body-size dim block and drop the stray rule. Its `---` fences are already collapsed by the hide
        // passes (thematic-break + block-gap), and the bytes are untouched (markdown-as-truth).
        if let fmRange = frontmatterRange(s, nsLen: nsLen) {
            storage.addAttribute(.font, value: baseFont, range: fmRange)
            storage.addAttribute(.foregroundColor, value: mallowDim, range: fmRange)
            rules.removeAll { NSIntersectionRange($0, fmRange).length > 0 }
        }

        storage.endEditing()
        textView.codeCards = codeCards     // hand the decoration ranges to the view's draw pass
        textView.tableCards = tableCards
        textView.quoteBars = quotes
        textView.ruleLines = rules
        textView.needsDisplay = true
    }

    /// The UTF-16 range of a leading YAML frontmatter block (`---` on line 1 … a closing `---` line),
    /// fences inclusive, or nil if the document doesn't open with one. Only a fence at the very start
    /// counts (that's what YAML frontmatter is); a `---` elsewhere is a normal thematic break.
    private func frontmatterRange(_ s: String, nsLen: Int) -> NSRange? {
        let ns = s as NSString
        guard nsLen >= 3 else { return nil }
        func isFence(_ r: NSRange) -> Bool {
            ns.substring(with: r).trimmingCharacters(in: .whitespacesAndNewlines) == "---"
        }
        let first = ns.lineRange(for: NSRange(location: 0, length: 0))
        guard first.location == 0, isFence(first) else { return nil }   // must open with `---`
        var lineStart = first.location + first.length
        while lineStart < nsLen {
            let line = ns.lineRange(for: NSRange(location: lineStart, length: 0))
            if isFence(line) { return NSRange(location: 0, length: line.location + line.length) }
            if line.length == 0 { break }
            lineStart = line.location + line.length
        }
        return nil   // no closing fence → it's not a frontmatter block
    }

    /// Which block kinds have hideable syntax (the `**`, `#`, `- `, `> ` gaps collapsed by
    /// `hideBlockGaps`). `fileprivate` so the hide-pass collector below can read it.
    fileprivate static func hideable(_ tag: String) -> Bool {
        tag == "Paragraph" || tag == "Heading" || tag == "List" || tag == "BlockQuote"
    }

    func recomputeHidden() {
        guard let textView else { return }
        let s = textView.string
        let ns = s as NSString
        let total = ns.length
        // Markdown is the source of truth, but its syntax NEVER shows in the editor — you write and edit
        // clean styled text and change structure through commands (⌘B, Style ▸ H1…), not by touching raw
        // markers. So the hidden set is purely a function of the parse; it does NOT depend on the caret
        // (which is why `selectionChanged` no longer recomputes it). Pass order is irrelevant — each pass
        // only inserts into the same set.
        var collector = HiddenSyntaxCollector(s: s, ns: ns, total: total)
        collector.hideBlockGaps(blocks)        // the `#`/`**`/`> ` marker gaps in paragraphs/headings/lists/quotes
        collector.hideInlineCodeFences(blocks) // the ` backtick runs around inline code
        collector.hideThematicBreaks(blocks)   // the --- / *** / ___ source (a rule is drawn instead)
        collector.hideCodeBlockFences(blocks)  // the ``` opening/closing fence lines

        // Unordered-list dashes render as `•`, and GFM task `[ ]`/`[x]` as ☐/☑ — glyph substitution, also
        // unconditional (the raw `- ` / `[ ]` never shows). Task brackets collapse; the inner char carries
        // the ☐/☑ glyph (drawn by the layout-manager delegate).
        var bullets = Set<Int>()
        let grammar = MarkerGrammar(ns: ns)
        for block in blocks where block.kindTag == "List" {
            let (bLo, bHi) = block.range.utf16Bounds(in: s, clampedTo: total)
            for d in grammar.bulletDashes(bLo, bHi) { bullets.insert(d) }
        }
        bulletMarks = bullets

        var boxes = [Int: Bool]()
        for (inner, checked) in TaskBoxScanner(s).allBoxes(blocks) {
            boxes[inner] = checked
            collector.hidden.insert(inner - 1)   // [
            collector.hidden.insert(inner + 1)   // ]
            // A task item shows ONLY its ☐/☑ — hide the `- `/`* `/`N. ` bullet marker before the box so it
            // never renders as "• ☐ text". KEEP any leading indent visible so a nested task stays indented
            // (matching nested bullets). The box `[` is at inner-1, so the marker is [firstNonIndent, inner-1).
            // Hidden wins over the bullet glyph in the layout delegate, so this also suppresses the • without
            // touching bulletMarks.
            let box = inner - 1
            var mStart = ns.lineRange(for: NSRange(location: box, length: 0)).location
            while mStart < box, ns.character(at: mStart) == 32 || ns.character(at: mStart) == 9 { mStart += 1 }
            for i in mStart ..< box { collector.hidden.insert(i) }
        }
        taskBoxes = boxes

        // GFM tables: a true grid needs engine cell ranges, but the philosophy is "no raw markers". So
        // render every `|` as a space and hide the `|---|` delimiter row (see TablePipeScanner) — monospace
        // keeps the columns aligned, the bars just don't show.
        let table = TablePipeScanner(ns: ns, total: total).scan(blocks, source: s)
        tablePipes = table.pipes
        for h in table.hide { collector.hidden.insert(h) }

        hiddenChars = collector.hidden
        if let lm = textView.layoutManager {
            let full = NSRange(location: 0, length: total)
            lm.invalidateGlyphs(forCharacterRange: full, changeInLength: 0, actualCharacterRange: nil)
            lm.invalidateLayout(forCharacterRange: full, actualCharacterRange: nil)
        }
    }

    // MARK: commands — toggle a mark / set a heading via the engine, then re-render.

    /// Inline-mark toggles that WRAP the selection in a delimiter. On a bare caret these would wrap
    /// an empty selection — inserting a delimiter pair (`****`, `` `` ``) the parser can't see as a
    /// mark, so the hide-pass never collapses it and the raw markers SHOW (and would persist in the
    /// saved file). For these, a caret with no selection formats the WORD under the caret instead.
    private static let wrappingCommands: Set<String> =
        ["toggle_strong", "toggle_emphasis", "toggle_strikethrough", "toggle_inline_code"]

    func apply(_ command: String) {
        guard let textView else { return }
        let s = textView.string
        let r = textView.selectedRange()
        var anchor = utf16ToChar(s, r.location)
        var head = utf16ToChar(s, r.location + r.length)
        // A wrapping toggle on a bare caret formats the word under it (never inserts an empty,
        // un-hideable delimiter pair). Caret not on a word (whitespace / blank line) → nothing to
        // format, so no-op rather than leave stray markers.
        if anchor == head, Self.wrappingCommands.contains(command) {
            guard let (lo, hi) = wordScalarRange(s, caret: anchor) else { return }
            anchor = lo; head = hi
        }
        guard let edit = try? JSONDecoder().decode(
            IEditResult.self, from: Data(inkCommand(command, s, anchor, head).utf8)
        ) else { return }
        replace(with: edit)
    }

    /// The Unicode-scalar range `[from, to)` of the word the caret sits in or touches, or nil when
    /// the caret isn't adjacent to any word scalar (whitespace / blank line). Scalar-indexed to
    /// match the engine (Inkstone `char` = Unicode scalar). A "word scalar" is any alphanumeric, so
    /// markdown delimiters (`*`, `` ` ``, `[`) are boundaries and a caret inside a styled word
    /// expands to exactly that word's text.
    private func wordScalarRange(_ s: String, caret: Int) -> (Int, Int)? {
        let scalars = Array(s.unicodeScalars)
        let n = scalars.count
        let c = max(0, min(caret, n))
        func isWord(_ u: Unicode.Scalar) -> Bool { CharacterSet.alphanumerics.contains(u) }
        var lo = c, hi = c
        while lo > 0, isWord(scalars[lo - 1]) { lo -= 1 }   // grow left over word scalars
        while hi < n, isWord(scalars[hi]) { hi += 1 }       // grow right over word scalars
        return lo < hi ? (lo, hi) : nil
    }

    func applyHeading(_ level: UInt8) {
        guard let textView else { return }
        let s = textView.string
        let r = textView.selectedRange()
        let anchor = utf16ToChar(s, r.location)
        let head = utf16ToChar(s, r.location + r.length)
        guard let edit = try? JSONDecoder().decode(
            IEditResult.self, from: Data(inkSetHeading(s, anchor, head, level).utf8)
        ) else { return }
        replace(with: edit)
    }

    private func replace(with edit: IEditResult) {
        guard let textView else { return }
        // Undoable replace — NOT `textView.string = …` (that registers no undo AND wipes the existing
        // undo stack). Route through the text view's edit path so ⌘Z reverts an engine command (bold,
        // heading, list, …) like any typing, and prior typing-undo history is preserved.
        let full = NSRange(location: 0, length: (textView.string as NSString).length)
        textView.replaceCharactersUndoably(in: full, with: edit.text)
        let a = charToUTF16(edit.text, edit.selection.anchor)
        let h = charToUTF16(edit.text, edit.selection.head)
        textView.setSelectedRange(NSRange(location: min(a, h), length: abs(h - a)))
        refresh()
    }
}

// MARK: - Hide-syntax grammar + passes (extracted from EditorViewModel.recomputeHidden)

/// The line-leading marker grammar over an NSString: where a list bullet / ordered number / nested
/// blockquote prefix ends, and (for lists) the exact set of marker chars to KEEP visible. Pure — it
/// only reads the buffer; it never decides what to hide. The marker must stay visible so a delimiter
/// opening the first inline (e.g. `- **bold**`) still collapses while the `- ` does not.
private struct MarkerGrammar {
    let ns: NSString

    func isMarkerSpace(_ c: unichar) -> Bool { c == 32 || c == 9 }

    /// If `start` opens a task-list checkbox `[ ] ` / `[x] ` / `[X] `, return the index past it (so the
    /// box stays visible as part of the marker); otherwise return `start` unchanged.
    func skipTaskBox(_ start: Int, _ lineHi: Int) -> Int {
        guard start + 3 < lineHi, ns.character(at: start) == 91 /* [ */ else { return start }
        let inner = ns.character(at: start + 1)
        guard inner == 32 || inner == 120 || inner == 88 /* space/x/X */,
              ns.character(at: start + 2) == 93 /* ] */,
              isMarkerSpace(ns.character(at: start + 3)) else { return start }
        return start + 4
    }

    /// The index where the line's leading marker prefix ends (indent + bullet/number/quote markers,
    /// incl. a task-box). A bare number with no `.`/`)` delimiter is content, not a marker.
    func markerPrefixEnd(_ lineLo: Int, _ lineHi: Int) -> Int {
        var i = lineLo
        while i < lineHi && isMarkerSpace(ns.character(at: i)) { i += 1 }  // indent
        while i < lineHi {
            let c = ns.character(at: i)
            if c == 62 /* > */ {  // blockquote (may nest: `> > `, `> - `)
                i += 1
                if i < lineHi && isMarkerSpace(ns.character(at: i)) { i += 1 }
                continue
            }
            if c == 45 || c == 42 || c == 43 /* - * + */,
               i + 1 < lineHi, isMarkerSpace(ns.character(at: i + 1)) {
                return skipTaskBox(i + 2, lineHi)  // bullet ends the marker
            }
            if c >= 48 && c <= 57 /* digit */ {  // ordered: N. / N)
                var j = i
                while j < lineHi && ns.character(at: j) >= 48 && ns.character(at: j) <= 57 { j += 1 }
                if j < lineHi, ns.character(at: j) == 46 || ns.character(at: j) == 41 /* . ) */,
                   j + 1 < lineHi, isMarkerSpace(ns.character(at: j + 1)) {
                    return skipTaskBox(j + 2, lineHi)
                }
                return i  // a bare number is content, not a marker
            }
            return i
        }
        return min(i, lineHi)
    }

    /// The set of UTF-16 indices in `[bLo, bHi)` that are line-leading marker chars (kept visible).
    func leadingMarkers(_ bLo: Int, _ bHi: Int) -> Set<Int> {
        var keep = Set<Int>()
        var lineStart = bLo
        while lineStart < bHi {
            let line = ns.lineRange(for: NSRange(location: lineStart, length: 0))
            let lineHi = min(line.location + line.length, bHi)
            var i = line.location
            let markerEnd = markerPrefixEnd(line.location, lineHi)
            while i < markerEnd { keep.insert(i); i += 1 }
            if line.length == 0 { break }
            lineStart = line.location + line.length
        }
        return keep
    }

    /// UTF-16 indices of unordered-bullet chars (`-`/`*`/`+`) in `[bLo, bHi)`, for glyph substitution
    /// (`- ` kept as source, drawn as `•`). Mirrors markerPrefixEnd's prefix walk but records the bullet
    /// char itself; ordered (`1.`) and the blockquote `>` are not bullets (the `>` prefix is skipped).
    func bulletDashes(_ bLo: Int, _ bHi: Int) -> Set<Int> {
        var dashes = Set<Int>()
        var lineStart = bLo
        while lineStart < bHi {
            let line = ns.lineRange(for: NSRange(location: lineStart, length: 0))
            let lineHi = min(line.location + line.length, bHi)
            var i = line.location
            while i < lineHi && isMarkerSpace(ns.character(at: i)) { i += 1 }   // indent
            while i < lineHi {
                let c = ns.character(at: i)
                if c == 62 /* > */ {   // skip nested blockquote prefix(es)
                    i += 1
                    if i < lineHi && isMarkerSpace(ns.character(at: i)) { i += 1 }
                    continue
                }
                if (c == 45 || c == 42 || c == 43), i + 1 < lineHi, isMarkerSpace(ns.character(at: i + 1)) {
                    dashes.insert(i)
                }
                break   // the first non-quote marker char decides the line
            }
            if line.length == 0 { break }
            lineStart = line.location + line.length
        }
        return dashes
    }
}

/// Accumulates the UTF-16 indices of syntax glyphs to collapse, for one `recomputeHidden` run. Holds the
/// source and exposes the four hide-passes; each pass only inserts into `hidden`, so they may run in any
/// order. A char is collapsed unless it's a newline — markers are ALWAYS hidden, the editor never shows
/// raw syntax (the app's markdown-as-truth philosophy). The result is purely a function of the parse.
private struct HiddenSyntaxCollector {
    let s: String
    let ns: NSString
    let total: Int
    let grammar: MarkerGrammar
    var hidden = Set<Int>()

    init(s: String, ns: NSString, total: Int) {
        self.s = s
        self.ns = ns
        self.total = total
        self.grammar = MarkerGrammar(ns: ns)
    }

    /// Collapse char `i` to zero width. Newlines are left alone — they keep the paragraph layout intact.
    private mutating func hideChar(_ i: Int) {
        guard i >= 0, i < total else { return }
        if ns.character(at: i) != 10 /* not a newline */ { hidden.insert(i) }
    }

    /// Collapse every char in `[lo, hi)` not in `keep` (the kept line-leading list markers).
    private mutating func collapse(_ lo: Int, _ hi: Int, keep: Set<Int>) {
        var i = max(0, lo)
        let end = min(hi, total)
        while i < end {
            if !keep.contains(i) { hideChar(i) }
            i += 1
        }
    }

    /// Syntax chars are those inside a hideable block but NOT covered by any inline run (the `**`, `#`,
    /// `- `, `> ` gaps). Lists keep their leading bullet/number visible (it's redrawn as `•`); blockquotes
    /// hide the `>` (the drawn bar replaces it); every other gap collapses.
    mutating func hideBlockGaps(_ blocks: [PBlock]) {
        for block in blocks where EditorViewModel.hideable(block.kindTag) {
            let (bLo, bHi) = block.range.utf16Bounds(in: s, clampedTo: total)
            let covered = block.inlines
                .map { $0.range.utf16Bounds(in: s, clampedTo: total) }
                .sorted { $0.lo < $1.lo }
            let keep = (block.kindTag == "List") ? grammar.leadingMarkers(bLo, bHi) : Set<Int>()
            var cursor = bLo
            for (lo, hi) in covered {
                if lo > cursor { collapse(cursor, lo, keep: keep) }
                cursor = max(cursor, hi)
            }
            if cursor < bHi { collapse(cursor, bHi, keep: keep) }
        }
    }

    /// Inline code's source range includes its backtick fences; collapse the leading/trailing ` runs so
    /// only the code text shows (rendered on its pill).
    mutating func hideInlineCodeFences(_ blocks: [PBlock]) {
        for block in blocks {
            for inline in block.inlines where inline.kindTag == "Code" {
                let (lo, hi) = inline.range.utf16Bounds(in: s, clampedTo: total)
                var i = lo
                while i < hi && ns.character(at: i) == 96 /* ` */ { hideChar(i); i += 1 }
                var j = hi - 1
                while j >= i && ns.character(at: j) == 96 { hideChar(j); j -= 1 }
            }
        }
    }

    /// Thematic breaks: collapse the --- / *** / ___ source so only the drawn rule shows.
    mutating func hideThematicBreaks(_ blocks: [PBlock]) {
        for block in blocks where block.kindTag == "ThematicBreak" {
            let (lo, hi) = block.range.utf16Bounds(in: s, clampedTo: total)
            var i = lo
            while i < hi { hideChar(i); i += 1 }
        }
    }

    /// Code-block fences: hide the ``` / ```lang opening + closing lines so only the code shows on its
    /// tint (a rounded card is drawn instead). Code content is untouched.
    mutating func hideCodeBlockFences(_ blocks: [PBlock]) {
        for block in blocks where block.kindTag == "CodeBlock" {
            let (bLo, bHi) = block.range.utf16Bounds(in: s, clampedTo: total)
            var lineStart = bLo
            while lineStart < bHi {
                let line = ns.lineRange(for: NSRange(location: lineStart, length: 0))
                let lineHi = min(line.location + line.length, bHi)
                var i = line.location
                while i < lineHi && grammar.isMarkerSpace(ns.character(at: i)) { i += 1 }   // skip indent
                let isFence = i + 2 < lineHi
                    && ns.character(at: i) == 96 && ns.character(at: i + 1) == 96 && ns.character(at: i + 2) == 96
                if isFence { var j = line.location; while j < lineHi { hideChar(j); j += 1 } }
                if line.length == 0 { break }
                lineStart = line.location + line.length
            }
        }
    }
}

/// The "no raw table markers" scan over GFM `Table` blocks (a true cell-bordered grid needs engine cell
/// ranges, absent today). Pure over the NSString; for every table it collects the UTF-16 indices of each
/// `|` bar on a content row (→ rendered as a space, keeping monospace columns aligned) and of every char
/// on the `|---|` delimiter row (→ hidden). Mirrors `TaskBoxScanner`: detection only, no mutation.
private struct TablePipeScanner {
    let ns: NSString
    let total: Int

    /// `pipes` = bar indices to render as spaces; `hide` = delimiter-row chars to collapse. `source`
    /// bridges each block's engine byte range to UTF-16.
    func scan(_ blocks: [PBlock], source: String) -> (pipes: Set<Int>, hide: Set<Int>) {
        var pipes = Set<Int>(), hide = Set<Int>()
        for block in blocks where block.kindTag == "Table" {
            let (bLo, bHi) = block.range.utf16Bounds(in: source, clampedTo: total)
            var lineStart = bLo
            var foundDelimiter = false
            while lineStart < bHi {
                let line = ns.lineRange(for: NSRange(location: lineStart, length: 0))
                let lineHi = min(line.location + line.length, bHi)
                var linePipes: [Int] = []
                var sawDash = false, onlySeparatorChars = true, sawNonSpace = false
                var i = line.location
                while i < lineHi {
                    switch ns.character(at: i) {
                    case 124: linePipes.append(i); sawNonSpace = true       // |
                    case 45:  sawDash = true; sawNonSpace = true            // -
                    case 58:  sawNonSpace = true                            // :
                    case 32, 9, 10, 13: break                               // ws / line terminator
                    default:  onlySeparatorChars = false; sawNonSpace = true
                    }
                    i += 1
                }
                // GFM delimiter row = the FIRST row made of only `| - :` + ws with ≥1 dash (it always sits
                // directly under the header, before any body row). Matched by SHAPE, not a fixed line
                // index, so a stray leading line in the block range can't throw it off; hide that row whole.
                if !foundDelimiter, sawDash, sawNonSpace, onlySeparatorChars {
                    var j = line.location
                    while j < lineHi { if ns.character(at: j) != 10 { hide.insert(j) }; j += 1 }
                    foundDelimiter = true
                } else {
                    for p in linePipes { pipes.insert(p) }
                }
                if line.length == 0 { break }
                lineStart = line.location + line.length
            }
        }
        return (pipes, hide)
    }
}
