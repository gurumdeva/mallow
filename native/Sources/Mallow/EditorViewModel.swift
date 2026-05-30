// EditorViewModel — the editor's brain (the logic the old EditorController god-object mixed with
// window/menu plumbing). It owns the document state (file path, saved baseline, the cached parse,
// focus mode) and all the engine-driven work: parsing, live-preview styling, hide-syntax glyph
// computation, focus dimming, and command application. It drives an injected MarkdownTextView's
// storage; the EditorController owns the window/views and forwards delegate + menu events here.

import AppKit
import CInkstone

final class EditorViewModel {
    private weak var textView: MarkdownTextView?

    var filePath: String?
    private(set) var baseline = ""
    private var blocks: [PBlock] = []           // cached parse (one parse per text change)
    private(set) var hiddenChars = Set<Int>()   // UTF-16 indices of collapsed syntax glyphs (read by the layout-manager delegate)
    var focusMode = false                        // dim every block but the caret's
    var keepOnTop = false                         // pin this window above other apps (transient, per-window)
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

    var isDirty: Bool { inkstone_is_dirty(textView?.string ?? "", baseline) }
    var displayName: String { (filePath as NSString?)?.lastPathComponent ?? L.t("doc.untitled") }

    func setPath(_ path: String?) { filePath = path }
    func markSaved(path: String, content: String) { filePath = path; baseline = content }

    // MARK: pipeline — parse once, then style + compute hidden syntax + focus.

    func refresh() {
        guard let textView else { return }
        blocks = (try? JSONDecoder().decode([PBlock].self,
                                            from: Data(inkParse(textView.string).utf8))) ?? []
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
        let caretByte = inkstone_char_to_byte(s, caretChar)
        let json = inkTake(inkstone_focus_decoration(s, caretByte))
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
                    storage.addAttribute(.backgroundColor, value: mallowElevated, range: nr)   // solid #2c2c2e card
                    storage.addAttribute(.paragraphStyle, value: mallowCodeParagraphStyle, range: nr)
                }
            case "BlockQuote":
                if let nr = nsRange(block.range) {
                    storage.addAttribute(.foregroundColor, value: mallowDim, range: nr)         // #98989d, not white-α
                    storage.addAttribute(.paragraphStyle, value: mallowQuoteParagraphStyle, range: nr)
                    quotes.append(nr)
                }
            case "ThematicBreak":
                if let nr = nsRange(block.range) { rules.append(nr) }   // dashes hidden; a rule is drawn instead
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
        textView.quoteBars = quotes        // hand the decoration ranges to the view's draw pass
        textView.ruleLines = rules
        textView.needsDisplay = true
    }

    /// Syntax chars are those inside a hideable block but NOT covered by any inline run (the `**`,
    /// `#`, `- `, `> ` gaps). Collapse them, except newlines and the line the caret is on.
    private static func hideable(_ tag: String) -> Bool {
        tag == "Paragraph" || tag == "Heading" || tag == "List" || tag == "BlockQuote"
    }

    func recomputeHidden() {
        guard let textView else { return }
        let s = textView.string
        let ns = s as NSString
        let total = ns.length
        let caretLine = total > 0 ? ns.lineRange(for: textView.selectedRange())
                                  : NSRange(location: 0, length: 0)
        var hidden = Set<Int>()

        func hideChar(_ i: Int) {
            guard i >= 0, i < total else { return }
            let onCaretLine = i >= caretLine.location && i < caretLine.location + caretLine.length
            if !onCaretLine && ns.character(at: i) != 10 /* not a newline */ { hidden.insert(i) }
        }
        func collapse(_ lo: Int, _ hi: Int, keep: Set<Int>) {
            var i = max(0, lo)
            let end = min(hi, total)
            while i < end {
                if !keep.contains(i) { hideChar(i) }
                i += 1
            }
        }

        // List/BlockQuote: the line-leading marker must STAY visible — keep ONLY the marker itself
        // (matched by grammar), so a delimiter opening the first inline (e.g. `- **bold**`) still
        // collapses.
        func isMarkerSpace(_ c: unichar) -> Bool { c == 32 || c == 9 }
        func skipTaskBox(_ start: Int, _ lineHi: Int) -> Int {
            guard start + 3 < lineHi, ns.character(at: start) == 91 /* [ */ else { return start }
            let inner = ns.character(at: start + 1)
            guard inner == 32 || inner == 120 || inner == 88 /* space/x/X */,
                  ns.character(at: start + 2) == 93 /* ] */,
                  isMarkerSpace(ns.character(at: start + 3)) else { return start }
            return start + 4
        }
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

        for block in blocks where Self.hideable(block.kindTag) {
            let bLo = byteToUTF16(s, block.range.start)
            let bHi = min(byteToUTF16(s, block.range.end), total)
            let covered = block.inlines
                .map { (byteToUTF16(s, $0.range.start), byteToUTF16(s, $0.range.end)) }
                .sorted { $0.0 < $1.0 }
            // Lists keep their leading bullet/number; blockquotes hide the `>` (the drawn bar replaces it).
            let keep = (block.kindTag == "List") ? leadingMarkers(bLo, bHi) : Set<Int>()
            var cursor = bLo
            for (lo, hi) in covered {
                if lo > cursor { collapse(cursor, lo, keep: keep) }
                cursor = max(cursor, hi)
            }
            if cursor < bHi { collapse(cursor, bHi, keep: keep) }
        }

        // Inline code's source range includes its backtick fences; collapse the leading/trailing
        // ` runs so only the code text shows (revealed on the caret line like other syntax).
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

        // Thematic breaks: collapse the --- / *** / ___ source so only the drawn rule shows (revealed
        // again when the caret is on that line, like every other hidden marker).
        for block in blocks where block.kindTag == "ThematicBreak" {
            let lo = byteToUTF16(s, block.range.start)
            let hi = min(byteToUTF16(s, block.range.end), total)
            var i = lo
            while i < hi { hideChar(i); i += 1 }
        }

        // Code-block fences: hide the ``` / ```lang opening + closing lines so only the code shows on
        // its tint (the fence lines reveal again when the caret is on them). Code content is untouched.
        for block in blocks where block.kindTag == "CodeBlock" {
            let bLo = byteToUTF16(s, block.range.start)
            let bHi = min(byteToUTF16(s, block.range.end), total)
            var lineStart = bLo
            while lineStart < bHi {
                let line = ns.lineRange(for: NSRange(location: lineStart, length: 0))
                let lineHi = min(line.location + line.length, bHi)
                var i = line.location
                while i < lineHi && isMarkerSpace(ns.character(at: i)) { i += 1 }   // skip indent
                let isFence = i + 2 < lineHi
                    && ns.character(at: i) == 96 && ns.character(at: i + 1) == 96 && ns.character(at: i + 2) == 96
                if isFence { var j = line.location; while j < lineHi { hideChar(j); j += 1 } }
                if line.length == 0 { break }
                lineStart = line.location + line.length
            }
        }

        hiddenChars = hidden
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
            IEditResult.self, from: Data(inkTake(inkstone_set_heading(s, anchor, head, level)).utf8)
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
