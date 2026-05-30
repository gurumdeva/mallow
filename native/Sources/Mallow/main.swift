// Mallow — the native macOS app (Swift/AppKit) on the Inkstone engine.
//
// Native `NSTextView` (→ macOS system IME, the make-or-break CJK requirement, for free), the
// markdown text as the source of truth, styled + structured by Inkstone's parser, edited through
// Inkstone's commands, with file I/O whose dirty decision is Inkstone's verified `safety` — all
// over the C-ABI. TRUE live preview: the markdown syntax (`**`, `#`, `- `, `> `) is collapsed to
// zero width via the layout manager and revealed only on the caret's line.
//
// Build (from native/, with the sibling inkstone repo built — see build.sh / README):
//   ( cd ../../inkstone && cargo build --features ffi --release ) && swift run Mallow

import AppKit
import UniformTypeIdentifiers
import CInkstone  // the Inkstone C-ABI (libinkstone.a) via the CInkstone systemLibrary module map

// MARK: - Inkstone FFI (libinkstone.a, declared in include/inkstone.h)

func inkTake(_ p: UnsafeMutablePointer<CChar>?) -> String {
    guard let p = p else { return "" }
    defer { inkstone_string_free(p) }
    return String(cString: p)
}
func inkParse(_ s: String) -> String { inkTake(inkstone_parse_json(s)) }
func inkCommand(_ name: String, _ s: String, _ anchor: Int, _ head: Int) -> String {
    inkTake(inkstone_apply_command(name, s, anchor, head))
}

// MARK: - Minimal JSON view-model (only what the spike needs; extra keys are ignored)

private struct PRange: Decodable { let start: Int; let end: Int }
private struct PInline: Decodable {
    let range: PRange
    let marks: [String]
    let kindTag: String   // "Text" / "Code" / "Link"
    enum CodingKeys: String, CodingKey { case kind, range, marks }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        range = try c.decode(PRange.self, forKey: .range)
        marks = try c.decode([String].self, forKey: .marks)
        // InlineKind: "Text"/"Code" as a bare string; Link as {"Link": {"href": …}}.
        if let s = try? c.decode(String.self, forKey: .kind) {
            kindTag = s
        } else if let obj = try? c.nestedContainer(keyedBy: DynamicKey.self, forKey: .kind),
                  let key = obj.allKeys.first {
            kindTag = key.stringValue
        } else {
            kindTag = "Text"
        }
    }
}

private struct DynamicKey: CodingKey {
    var stringValue: String
    var intValue: Int?
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { self.intValue = intValue; self.stringValue = String(intValue) }
}

private struct PBlock: Decodable {
    let range: PRange
    let inlines: [PInline]
    let kindTag: String     // "Paragraph" / "Heading" / "List" / "BlockQuote" / "CodeBlock" / …
    let headingLevel: Int?
    enum CodingKeys: String, CodingKey { case kind, range, inlines }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        range = try c.decode(PRange.self, forKey: .range)
        inlines = try c.decode([PInline].self, forKey: .inlines)
        // serde encodes BlockKind: unit variants as a string ("Paragraph"), data variants as a
        // single-key object ({"Heading": 2} / {"CodeBlock": {…}}). Pull the tag (+ heading level).
        if let s = try? c.decode(String.self, forKey: .kind) {
            kindTag = s
            headingLevel = nil
        } else if let obj = try? c.nestedContainer(keyedBy: DynamicKey.self, forKey: .kind),
                  let key = obj.allKeys.first {
            kindTag = key.stringValue
            headingLevel = key.stringValue == "Heading" ? try? obj.decode(Int.self, forKey: key) : nil
        } else {
            kindTag = "Other"
            headingLevel = nil
        }
    }
}
private struct ISelection: Decodable { let anchor: Int; let head: Int }
private struct IEditResult: Decodable { let text: String; let selection: ISelection }
private struct PDecoration: Decodable { let range: PRange }  // Focus-Mode block (or "null" → nil)

// MARK: - Offset bridges: Inkstone(byte for view / char for edit) ↔ NSTextView(UTF-16, NSRange)

func byteToUTF16(_ s: String, _ byte: Int) -> Int {
    let u8 = s.utf8
    guard byte >= 0,
          let i = u8.index(u8.startIndex, offsetBy: byte, limitedBy: u8.endIndex),
          let si = i.samePosition(in: s) else { return s.utf16.count }
    return si.utf16Offset(in: s)
}
func utf16ToChar(_ s: String, _ u16: Int) -> Int {
    let clamped = max(0, min(u16, s.utf16.count))
    let si = String.Index(utf16Offset: clamped, in: s)
    return s.unicodeScalars.distance(from: s.unicodeScalars.startIndex, to: si)
}
func charToUTF16(_ s: String, _ ch: Int) -> Int {
    let us = s.unicodeScalars
    guard ch >= 0,
          let i = us.index(us.startIndex, offsetBy: ch, limitedBy: us.endIndex),
          let si = i.samePosition(in: s) else { return s.utf16.count }
    return si.utf16Offset(in: s)
}

// MARK: - The editor surface

final class MarkdownTextView: NSTextView {}

final class EditorController: NSObject, NSTextViewDelegate, NSWindowDelegate, NSLayoutManagerDelegate {
    let textView: MarkdownTextView
    weak var window: NSWindow?

    private var filePath: String?
    private var baseline = ""

    private var blocks: [PBlock] = []          // cached parse (one parse per text change)
    private var hiddenChars = Set<Int>()       // UTF-16 indices of collapsed syntax glyphs
    private var focusMode = false              // dim every block but the caret's

    private let baseSize: CGFloat = 15
    private let fm = NSFontManager.shared
    private lazy var baseFont = NSFont.monospacedSystemFont(ofSize: baseSize, weight: .regular)

    init(textView: MarkdownTextView, window: NSWindow) {
        self.textView = textView
        self.window = window
        super.init()
        textView.delegate = self
        window.delegate = self
        // Accessing layoutManager forces TextKit 1, where the glyph-generation delegate fires.
        textView.layoutManager?.delegate = self
        baseline = textView.string
        refresh()
    }

    // MARK: pipeline — parse once, then style + compute hidden syntax + chrome.

    private func refresh() {
        blocks = (try? JSONDecoder().decode([PBlock].self,
                                            from: Data(inkParse(textView.string).utf8))) ?? []
        restyle()
        recomputeHidden()
        applyFocus()
        updateChrome()
    }

    // MARK: focus mode — dim every block except the one the caret is in (Inkstone decides which).

    @objc func toggleFocusMode(_ sender: Any?) {
        focusMode.toggle()
        (sender as? NSMenuItem)?.state = focusMode ? .on : .off
        restyle()                       // restore normal colors
        if focusMode { applyFocus() }   // then dim around the caret's block
    }

    /// When focus mode is on, overlay a dim foreground on everything outside the caret's block.
    /// No-op (everything stays normally styled) if off, or if the caret sits between blocks.
    private func applyFocus() {
        guard focusMode, let storage = textView.textStorage else { return }
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
        var f = marks.contains("Code")
            ? NSFont.monospacedSystemFont(ofSize: baseSize, weight: .regular) : baseFont
        if marks.contains("Strong") { f = fm.convert(f, toHaveTrait: .boldFontMask) }
        if marks.contains("Emphasis") { f = fm.convert(f, toHaveTrait: .italicFontMask) }
        return f
    }

    private func restyle() {
        let s = textView.string
        guard let storage = textView.textStorage else { return }
        let nsLen = (s as NSString).length

        func nsRange(_ r: PRange) -> NSRange? {
            let lo = byteToUTF16(s, r.start), hi = byteToUTF16(s, r.end)
            guard hi > lo, hi <= nsLen else { return nil }
            return NSRange(location: lo, length: hi - lo)
        }

        storage.beginEditing()
        storage.setAttributes([.font: baseFont, .foregroundColor: NSColor.labelColor],
                              range: NSRange(location: 0, length: nsLen))
        for block in blocks {
            // Block-level styling first, then inline runs are layered on top.
            switch block.kindTag {
            case "Heading":
                if let level = block.headingLevel, let nr = nsRange(block.range) {
                    storage.addAttribute(.font,
                                         value: NSFont.boldSystemFont(ofSize: max(baseSize, 27 - CGFloat(level) * 3)),
                                         range: nr)
                }
                continue  // heading text is uniform — no inline pass
            case "CodeBlock":
                if let nr = nsRange(block.range) {  // group the fenced block with a fill
                    storage.addAttribute(.backgroundColor, value: NSColor.quaternaryLabelColor, range: nr)
                }
            case "BlockQuote":
                if let nr = nsRange(block.range) {  // muted, quote-like
                    storage.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: nr)
                }
            case "ThematicBreak":
                if let nr = nsRange(block.range) {  // de-emphasize the bare `---`
                    storage.addAttribute(.foregroundColor, value: NSColor.tertiaryLabelColor, range: nr)
                }
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
                    storage.addAttribute(.backgroundColor, value: NSColor.quaternaryLabelColor, range: nr)
                }
                if inline.kindTag == "Link" {
                    storage.addAttribute(.foregroundColor, value: NSColor.linkColor, range: nr)
                    storage.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: nr)
                }
            }
        }
        storage.endEditing()
    }

    /// Syntax chars are those inside a hideable block but NOT covered by any inline run (the `**`,
    /// `#`, `- `, `> ` gaps). Collapse them, except newlines and the line the caret is on.
    private static func hideable(_ tag: String) -> Bool {
        tag == "Paragraph" || tag == "Heading" || tag == "List" || tag == "BlockQuote"
    }

    private func recomputeHidden() {
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

        // List/BlockQuote: the line-leading marker (bullet `- `, number `1. `, quote `> `, task
        // `- [ ] `, plus indent) must STAY visible — collapsing it would make the block look like a
        // plain paragraph. But keep ONLY the marker itself, matched by grammar: keeping up to the
        // first content char would also pin a delimiter that opens the first inline (e.g. the `**`
        // in `- **bold**` or the `[` in `- [text](url)`), since the parser's mark range excludes
        // its delimiters. So those leading delimiters must still collapse.
        func isMarkerSpace(_ c: unichar) -> Bool { c == 32 || c == 9 }  // space or tab
        func skipTaskBox(_ start: Int, _ lineHi: Int) -> Int {  // optional GFM `[ ]`/`[x]` + space
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
            let keep = (block.kindTag == "List" || block.kindTag == "BlockQuote")
                ? leadingMarkers(bLo, bHi) : Set<Int>()
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

        hiddenChars = hidden
        if let lm = textView.layoutManager {
            let full = NSRange(location: 0, length: total)
            lm.invalidateGlyphs(forCharacterRange: full, changeInLength: 0, actualCharacterRange: nil)
            lm.invalidateLayout(forCharacterRange: full, actualCharacterRange: nil)
        }
    }

    // NSLayoutManagerDelegate — mark hidden syntax glyphs as `.null` (zero-width, not drawn).
    func layoutManager(_ lm: NSLayoutManager,
                       shouldGenerateGlyphs glyphs: UnsafePointer<CGGlyph>,
                       properties props: UnsafePointer<NSLayoutManager.GlyphProperty>,
                       characterIndexes: UnsafePointer<Int>,
                       font: NSFont,
                       forGlyphRange glyphRange: NSRange) -> Int {
        if hiddenChars.isEmpty { return 0 }  // 0 = no override, use default glyph generation
        var newProps = [NSLayoutManager.GlyphProperty](repeating: .null, count: glyphRange.length)
        var changed = false
        for i in 0 ..< glyphRange.length {
            if hiddenChars.contains(characterIndexes[i]) {
                newProps[i] = .null
                changed = true
            } else {
                newProps[i] = props[i]
            }
        }
        if !changed { return 0 }
        lm.setGlyphs(glyphs, properties: &newProps,
                     characterIndexes: characterIndexes, font: font, forGlyphRange: glyphRange)
        return glyphRange.length
    }

    // MARK: commands

    func apply(_ command: String) {
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
        textView.string = edit.text
        let a = charToUTF16(edit.text, edit.selection.anchor)
        let h = charToUTF16(edit.text, edit.selection.head)
        textView.setSelectedRange(NSRange(location: min(a, h), length: abs(h - a)))
        refresh()
    }

    @objc func cmdBold(_ s: Any?) { apply("toggle_strong") }
    @objc func cmdItalic(_ s: Any?) { apply("toggle_emphasis") }
    @objc func cmdStrike(_ s: Any?) { apply("toggle_strikethrough") }
    @objc func cmdCode(_ s: Any?) { apply("toggle_inline_code") }
    @objc func cmdH1(_ s: Any?) { applyHeading(1) }
    @objc func cmdH2(_ s: Any?) { applyHeading(2) }
    @objc func cmdH3(_ s: Any?) { applyHeading(3) }
    @objc func cmdBody(_ s: Any?) { applyHeading(0) }
    @objc func cmdBullet(_ s: Any?) { apply("toggle_bullet_list") }
    @objc func cmdNumbered(_ s: Any?) { apply("toggle_ordered_list") }
    @objc func cmdQuote(_ s: Any?) { apply("toggle_blockquote") }
    @objc func cmdCodeBlock(_ s: Any?) { apply("toggle_code_block") }
    @objc func cmdDivider(_ s: Any?) { apply("insert_divider") }

    // MARK: dirty / chrome (Inkstone safety drives "is the document edited?")

    private var isDirty: Bool { inkstone_is_dirty(textView.string, baseline) }

    private func updateChrome() {
        window?.isDocumentEdited = isDirty
        window?.title = (filePath as NSString?)?.lastPathComponent ?? "Untitled"
    }

    func textDidChange(_ notification: Notification) { refresh() }

    // Re-collapse/reveal as the caret moves (reveal the caret's line). Text is unchanged, so reuse
    // the cached parse — only the hidden set + glyphs need recomputing.
    func textViewDidChangeSelection(_ notification: Notification) {
        recomputeHidden()
        if focusMode { restyle(); applyFocus() }  // re-dim around the new caret block
    }

    // MARK: file I/O

    private func load(_ content: String, path: String?) {
        textView.string = content
        textView.setSelectedRange(NSRange(location: 0, length: 0))  // caret to top, not end
        filePath = path
        baseline = content
        refresh()
    }

    /// Open a file by path — the entry point for a path passed on the command line / by Finder
    /// ("Open With" / `open -a Inkstone file.md`). Honors the unsaved-changes guard.
    func openFile(_ path: String) {
        guard confirmDiscardIfDirty(),
              let content = try? String(contentsOfFile: path, encoding: .utf8) else { return }
        load(content, path: path)
    }

    private func confirmDiscardIfDirty() -> Bool {
        guard isDirty else { return true }
        let alert = NSAlert()
        alert.messageText = "Discard unsaved changes?"
        alert.informativeText = "The current document has edits that haven't been saved."
        alert.addButton(withTitle: "Discard")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private static let markdownTypes: [UTType] = [UTType(filenameExtension: "md") ?? .plainText, .plainText]

    @objc func newDocument(_ sender: Any?) {
        guard confirmDiscardIfDirty() else { return }
        load("", path: nil)
    }
    @objc func openDocument(_ sender: Any?) {
        guard confirmDiscardIfDirty() else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = Self.markdownTypes
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url,
           let content = try? String(contentsOf: url, encoding: .utf8) {
            load(content, path: url.path)
        }
    }
    @objc func saveDocument(_ sender: Any?) {
        if let path = filePath { write(to: URL(fileURLWithPath: path)) } else { saveDocumentAs(sender) }
    }
    @objc func saveDocumentAs(_ sender: Any?) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.nameFieldStringValue = (filePath as NSString?)?.lastPathComponent ?? "Untitled.md"
        if panel.runModal() == .OK, let url = panel.url { write(to: url) }
    }
    private func write(to url: URL) {
        let content = textView.string
        do {
            try content.write(to: url, atomically: true, encoding: .utf8)
            filePath = url.path
            baseline = content
            updateChrome()
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool { confirmDiscardIfDirty() }
}

// MARK: - App bootstrap

let app = NSApplication.shared
app.setActivationPolicy(.regular)

let window = NSWindow(
    contentRect: NSRect(x: 0, y: 0, width: 760, height: 560),
    styleMask: [.titled, .closable, .resizable, .miniaturizable],
    backing: .buffered, defer: false
)
window.center()

let scroll = NSScrollView(frame: window.contentView!.bounds)
scroll.autoresizingMask = [.width, .height]
scroll.hasVerticalScroller = true

let textView = MarkdownTextView(frame: scroll.bounds)
textView.autoresizingMask = [.width]
textView.isRichText = true
textView.allowsUndo = true
// Markdown is the source of truth: every "smart" auto-substitution corrupts it.
// "--"→"—", "..."→"…", straight→curly quotes, autocorrect, and auto-linking all rewrite
// the bytes the parser reads, so they are all off. (Spellcheck/grammar squiggles also
// clash with the glyph-hiding live preview; users can re-enable via Edit ▸ Spelling.)
textView.isAutomaticQuoteSubstitutionEnabled = false
textView.isAutomaticDashSubstitutionEnabled = false
textView.isAutomaticTextReplacementEnabled = false
textView.isAutomaticSpellingCorrectionEnabled = false
textView.isAutomaticLinkDetectionEnabled = false
textView.isAutomaticDataDetectionEnabled = false
textView.isContinuousSpellCheckingEnabled = false
textView.isGrammarCheckingEnabled = false
textView.usesFindBar = true  // native find/replace bar (⌘F) — mature, IME-aware, free
textView.textContainerInset = NSSize(width: 18, height: 18)
textView.string = """
# Inkstone

A native macOS editor where **markdown is the source of truth** — parsed and
styled live by a Rust engine, with the system IME for 한글 / 日本語.

`#`, `**`, and `>` collapse away and return only on the caret's line. Try
*italic*, ~~strikethrough~~, `inline code`, or a [link](https://example.com).

## Highlights
- **Live styling** that never rewrites your text
- Lists, quotes, and code rendered in place
1. headings sized by level
2. links, code, and rules

> Markdown stays markdown — nothing is changed behind your back.

The Format menu and ⌘B / ⌘I run the engine's commands; ⌘N / O / S handle files.
"""
scroll.documentView = textView
window.contentView!.addSubview(scroll)

let controller = EditorController(textView: textView, window: window)

// Open a file path passed on the command line (Finder "Open With" / `open -a Inkstone file.md` /
// terminal). Replaces the demo text above when present.
if CommandLine.arguments.count > 1 {
    controller.openFile(CommandLine.arguments[1])
}

let mainMenu = NSMenu()

let appItem = NSMenuItem()
mainMenu.addItem(appItem)
let appMenu = NSMenu()
appMenu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
appItem.submenu = appMenu

let fileItem = NSMenuItem()
mainMenu.addItem(fileItem)
let fileMenu = NSMenu(title: "File")
func addFile(_ title: String, _ action: Selector, _ key: String, _ mods: NSEvent.ModifierFlags = .command) {
    let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
    item.keyEquivalentModifierMask = mods
    item.target = controller
    fileMenu.addItem(item)
}
addFile("New", #selector(EditorController.newDocument(_:)), "n")
addFile("Open…", #selector(EditorController.openDocument(_:)), "o")
addFile("Save", #selector(EditorController.saveDocument(_:)), "s")
addFile("Save As…", #selector(EditorController.saveDocumentAs(_:)), "s", [.command, .shift])
fileItem.submenu = fileMenu

// Edit menu — standard actions route through the responder chain to the text view (target nil).
// Find (⌘F) opens the native find bar (`usesFindBar`), which includes replace.
let editItem = NSMenuItem()
mainMenu.addItem(editItem)
let editMenu = NSMenu(title: "Edit")
func addEdit(_ title: String, _ sel: Selector, _ key: String,
            _ mods: NSEvent.ModifierFlags = .command, tag: Int = 0) {
    let item = NSMenuItem(title: title, action: sel, keyEquivalent: key)
    item.keyEquivalentModifierMask = mods
    item.tag = tag
    editMenu.addItem(item)
}
addEdit("Undo", Selector(("undo:")), "z")
addEdit("Redo", Selector(("redo:")), "z", [.command, .shift])
editMenu.addItem(.separator())
addEdit("Cut", #selector(NSText.cut(_:)), "x")
addEdit("Copy", #selector(NSText.copy(_:)), "c")
addEdit("Paste", #selector(NSText.paste(_:)), "v")
addEdit("Select All", #selector(NSText.selectAll(_:)), "a")
editMenu.addItem(.separator())
addEdit("Find…", #selector(NSTextView.performFindPanelAction(_:)), "f", tag: 1)
addEdit("Find Next", #selector(NSTextView.performFindPanelAction(_:)), "g", tag: 2)
addEdit("Find Previous", #selector(NSTextView.performFindPanelAction(_:)), "g", [.command, .shift], tag: 3)
addEdit("Use Selection for Find", #selector(NSTextView.performFindPanelAction(_:)), "e", tag: 7)
editItem.submenu = editMenu

let formatItem = NSMenuItem()
mainMenu.addItem(formatItem)
let formatMenu = NSMenu(title: "Format")
func addFmt(_ title: String, _ action: Selector, _ key: String = "",
            _ mods: NSEvent.ModifierFlags = .command) {
    let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
    if !key.isEmpty { item.keyEquivalentModifierMask = mods }
    item.target = controller
    formatMenu.addItem(item)
}
addFmt("Bold", #selector(EditorController.cmdBold(_:)), "b")
addFmt("Italic", #selector(EditorController.cmdItalic(_:)), "i")
addFmt("Strikethrough", #selector(EditorController.cmdStrike(_:)))
addFmt("Inline Code", #selector(EditorController.cmdCode(_:)))
formatMenu.addItem(.separator())
addFmt("Heading 1", #selector(EditorController.cmdH1(_:)), "1")
addFmt("Heading 2", #selector(EditorController.cmdH2(_:)), "2")
addFmt("Heading 3", #selector(EditorController.cmdH3(_:)), "3")
addFmt("Body", #selector(EditorController.cmdBody(_:)), "0")
formatMenu.addItem(.separator())
addFmt("Bullet List", #selector(EditorController.cmdBullet(_:)))
addFmt("Numbered List", #selector(EditorController.cmdNumbered(_:)))
addFmt("Quote", #selector(EditorController.cmdQuote(_:)))
addFmt("Code Block", #selector(EditorController.cmdCodeBlock(_:)))
addFmt("Divider", #selector(EditorController.cmdDivider(_:)))
formatItem.submenu = formatMenu

let viewItem = NSMenuItem()
mainMenu.addItem(viewItem)
let viewMenu = NSMenu(title: "View")
let focusItem = NSMenuItem(title: "Focus Mode",
                          action: #selector(EditorController.toggleFocusMode(_:)), keyEquivalent: "f")
focusItem.keyEquivalentModifierMask = [.command, .control]
focusItem.target = controller
viewMenu.addItem(focusItem)
viewItem.submenu = viewMenu

app.mainMenu = mainMenu

window.makeKeyAndOrderFront(nil)
app.activate(ignoringOtherApps: true)
app.run()
