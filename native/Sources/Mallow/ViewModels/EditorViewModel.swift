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
    var focusMode = false                        // dim every block but the caret's
    var keepOnTop = false                         // pin this window above other apps (transient, per-window)
    var typewriterOn = false                      // View ▸ Typewriter Scrolling: keep the caret line centered (per-window)
    var zoomFactor: CGFloat = 1                   // text zoom (View ▸ Zoom); per-window, resets each launch

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

    /// As the caret moves, re-reveal the caret's line. Text is unchanged → reuse the cached parse.
    func selectionChanged() {
        recomputeHidden()
        if focusMode { restyle(); applyFocus() }
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

        func nsRange(_ r: PRange) -> NSRange? {
            let lo = byteToUTF16(s, r.start), hi = byteToUTF16(s, r.end)
            guard hi > lo, hi <= nsLen else { return nil }
            return NSRange(location: lo, length: hi - lo)
        }

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
        storage.endEditing()
        textView.codeCards = codeCards     // hand the decoration ranges to the view's draw pass
        textView.tableCards = tableCards
        textView.quoteBars = quotes
        textView.ruleLines = rules
        textView.needsDisplay = true
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
        let caretLine = total > 0 ? ns.lineRange(for: textView.selectedRange())
                                  : NSRange(location: 0, length: 0)

        // Build the collector (source + caret context), run the four hide-passes into it, then read the
        // accumulated set back out. Pass order is irrelevant (each pass only inserts into the same set).
        var collector = HiddenSyntaxCollector(s: s, ns: ns, total: total, caretLine: caretLine)
        collector.hideBlockGaps(blocks)        // marker/`#`/`**` gaps in paragraphs/headings/lists/quotes
        collector.hideInlineCodeFences(blocks) // the ` backtick runs around inline code
        collector.hideThematicBreaks(blocks)   // the --- / *** / ___ source (a rule is drawn instead)
        collector.hideCodeBlockFences(blocks)  // the ``` opening/closing fence lines

        // Unordered-list dashes to render as `•` (kept in the source; substituted as a glyph off the
        // caret line, where the literal `- ` shows for editing).
        var bullets = Set<Int>()
        let grammar = MarkerGrammar(ns: ns)
        for block in blocks where block.kindTag == "List" {
            let bLo = byteToUTF16(s, block.range.start)
            let bHi = min(byteToUTF16(s, block.range.end), total)
            for d in grammar.bulletDashes(bLo, bHi)
            where !(d >= caretLine.location && d < caretLine.location + caretLine.length) {
                bullets.insert(d)
            }
        }
        bulletMarks = bullets

        // GFM task-list checkboxes: render `[ ]`/`[x]` as ☐/☑ — hide the two brackets and substitute the
        // inner char (glyph delegate). Off the caret's own line, where the raw `[ ]` shows for editing.
        var boxes = [Int: Bool]()
        for (inner, checked) in TaskBoxScanner(s).allBoxes(blocks)
        where !(inner >= caretLine.location && inner < caretLine.location + caretLine.length) {
            boxes[inner] = checked
            collector.hidden.insert(inner - 1)   // [
            collector.hidden.insert(inner + 1)   // ]
        }
        taskBoxes = boxes

        hiddenChars = collector.hidden
        if let lm = textView.layoutManager {
            let full = NSRange(location: 0, length: total)
            lm.invalidateGlyphs(forCharacterRange: full, changeInLength: 0, actualCharacterRange: nil)
            lm.invalidateLayout(forCharacterRange: full, actualCharacterRange: nil)
        }
    }

    // MARK: commands — toggle a mark / set a heading via the engine, then re-render.

    func apply(_ command: String) {
        guard let textView else { return }
        let s = textView.string
        let r = textView.selectedRange()
        let anchor = utf16ToChar(s, r.location)
        let head = utf16ToChar(s, r.location + r.length)
        guard let edit = try? JSONDecoder().decode(
            IEditResult.self, from: Data(inkCommand(command, s, anchor, head).utf8)
        ) else { return }
        replace(with: edit)
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
        if textView.shouldChangeText(in: full, replacementString: edit.text) {
            textView.textStorage?.replaceCharacters(in: full, with: edit.text)
            textView.didChangeText()
        }
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

/// Accumulates the UTF-16 indices of syntax glyphs to collapse, for one `recomputeHidden` run. Holds
/// the source + caret context and exposes the four hide-passes; each pass only inserts into `hidden`,
/// so they may run in any order. A char is collapsed unless it's a newline or on the caret's own line
/// (which stays fully revealed for editing) — see `hideChar`.
private struct HiddenSyntaxCollector {
    let s: String
    let ns: NSString
    let total: Int
    let caretLine: NSRange
    let grammar: MarkerGrammar
    var hidden = Set<Int>()

    init(s: String, ns: NSString, total: Int, caretLine: NSRange) {
        self.s = s
        self.ns = ns
        self.total = total
        self.caretLine = caretLine
        self.grammar = MarkerGrammar(ns: ns)
    }

    /// Collapse char `i`, except newlines and any char on the caret's current line.
    private mutating func hideChar(_ i: Int) {
        guard i >= 0, i < total else { return }
        let onCaretLine = i >= caretLine.location && i < caretLine.location + caretLine.length
        if !onCaretLine && ns.character(at: i) != 10 /* not a newline */ { hidden.insert(i) }
    }

    /// Collapse every char in `[lo, hi)` not in `keep` (the kept line-leading markers).
    private mutating func collapse(_ lo: Int, _ hi: Int, keep: Set<Int>) {
        var i = max(0, lo)
        let end = min(hi, total)
        while i < end {
            if !keep.contains(i) { hideChar(i) }
            i += 1
        }
    }

    /// Syntax chars are those inside a hideable block but NOT covered by any inline run (the `**`, `#`,
    /// `- `, `> ` gaps). Lists keep their leading bullet/number; blockquotes hide the `>` (the drawn
    /// bar replaces it).
    mutating func hideBlockGaps(_ blocks: [PBlock]) {
        for block in blocks where EditorViewModel.hideable(block.kindTag) {
            let bLo = byteToUTF16(s, block.range.start)
            let bHi = min(byteToUTF16(s, block.range.end), total)
            let covered = block.inlines
                .map { (byteToUTF16(s, $0.range.start), byteToUTF16(s, $0.range.end)) }
                .sorted { $0.0 < $1.0 }
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
    /// only the code text shows (revealed on the caret line like other syntax).
    mutating func hideInlineCodeFences(_ blocks: [PBlock]) {
        for block in blocks {
            for inline in block.inlines where inline.kindTag == "Code" {
                let lo = byteToUTF16(s, inline.range.start)
                let hi = min(byteToUTF16(s, inline.range.end), total)
                var i = lo
                while i < hi && ns.character(at: i) == 96 /* ` */ { hideChar(i); i += 1 }
                var j = hi - 1
                while j >= i && ns.character(at: j) == 96 { hideChar(j); j -= 1 }
            }
        }
    }

    /// Thematic breaks: collapse the --- / *** / ___ source so only the drawn rule shows (revealed
    /// again when the caret is on that line, like every other hidden marker).
    mutating func hideThematicBreaks(_ blocks: [PBlock]) {
        for block in blocks where block.kindTag == "ThematicBreak" {
            let lo = byteToUTF16(s, block.range.start)
            let hi = min(byteToUTF16(s, block.range.end), total)
            var i = lo
            while i < hi { hideChar(i); i += 1 }
        }
    }

    /// Code-block fences: hide the ``` / ```lang opening + closing lines so only the code shows on its
    /// tint (the fence lines reveal again when the caret is on them). Code content is untouched.
    mutating func hideCodeBlockFences(_ blocks: [PBlock]) {
        for block in blocks where block.kindTag == "CodeBlock" {
            let bLo = byteToUTF16(s, block.range.start)
            let bHi = min(byteToUTF16(s, block.range.end), total)
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
