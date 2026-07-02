// Restyler — live-preview styling, extracted from EditorViewModel. Applies per-block fonts/colors + inline
// marks to the text storage and hands the block-decoration ranges (code cards, quote bars, rules, inline-
// code pills, table grids) to the text view's draw pass. Owns the styled-font cache. View-model-free: it
// takes the parse + hidden set + zoom as inputs.

import AppKit

final class Restyler {
    private let baseSize: CGFloat = 16   // Mallow body size; SANS (mono only for code)
    private let fm = NSFontManager.shared
    /// Current text-zoom, kept in sync by the view model; `font(for:)` / `baseFont` read it. Set at the top
    /// of `restyle`; the VM clears the cache whenever zoom changes (the only thing altering resolved sizes).
    var zoom: CGFloat = 1
    private var fontCache: [Int: NSFont] = [:]
    private var baseFont: NSFont { NSFont.systemFont(ofSize: baseSize * zoom, weight: .regular) }
    func clearFontCache() { fontCache.removeAll() }

    func applyFocus(in textView: MarkdownTextView, enabled: Bool) {
        guard enabled, let storage = textView.textStorage else { return }
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
        let code = marks.contains("Code"), strong = marks.contains("Strong"), emph = marks.contains("Emphasis")
        let key = (code ? 1 : 0) | (strong ? 2 : 0) | (emph ? 4 : 0)
        if let cached = fontCache[key] { return cached }
        var f = code   // inline code in mono at 0.9em — slightly under the body so mono's wide advances read
                       // inline. (0.85 was an overcorrection from the ghost-advance era: with the hidden
                       // backticks now truly zero-width the pill hugs the text, and 0.85 read too small.)
            ? NSFont.monospacedSystemFont(ofSize: baseSize * 0.9 * zoom, weight: .regular) : baseFont
        if strong { f = fm.convert(f, toHaveTrait: .boldFontMask) }
        if emph { f = fm.convert(f, toHaveTrait: .italicFontMask) }
        fontCache[key] = f
        return f
    }

    /// A fenced code block's range minus its opening/closing ``` fence lines — the rows the background
    /// card should hug. (Indented code blocks have no fence lines, so the range is returned unchanged.)
    private func codeContentRange(_ block: NSRange, in ns: NSString) -> NSRange {
        func isFence(_ lineLo: Int, _ lineHi: Int) -> Bool {
            var i = lineLo
            while i < lineHi, ns.character(at: i) == 32 || ns.character(at: i) == 9 { i += 1 }   // skip indent
            return i + 2 < lineHi
                && ns.character(at: i) == 96 && ns.character(at: i + 1) == 96 && ns.character(at: i + 2) == 96
        }
        guard block.length > 0 else { return block }
        var lo = block.location
        var hi = block.location + block.length
        let first = ns.lineRange(for: NSRange(location: lo, length: 0))
        if isFence(first.location, min(first.location + first.length, hi)) {
            lo = min(first.location + first.length, hi)          // drop the opening fence line
        }
        if hi > lo {
            let last = ns.lineRange(for: NSRange(location: hi - 1, length: 0))
            if last.location >= lo, isFence(last.location, hi) {
                hi = max(lo, last.location)                      // drop the closing fence line
            }
        }
        return NSRange(location: lo, length: max(0, hi - lo))
    }

    func restyle(in textView: MarkdownTextView, blocks: [PBlock], hidden: Set<Int>, zoom: CGFloat) {
        self.zoom = zoom
        let s = textView.string
        guard let storage = textView.textStorage else { return }
        let nsLen = (s as NSString).length
        let map = byteToUTF16Map(s)   // O(1) byte→UTF-16 per range (built once; avoids the O(n²) walk)

        func nsRange(_ r: PRange) -> NSRange? { r.utf16Range(map: map, clampedTo: nsLen) }

        // Viewport geometry for table layout + horizontal scroll. The text CONTAINER may be wider than the
        // viewport (so a too-wide table can be scrolled to), so the viewport width comes from the enclosing
        // scroll view's clip — NOT the container. `availableWidth` is the room a table's laid-out width has
        // inside the viewport (the table's own inset already subtracted). On first paint (no laid-out clip
        // yet) it's huge → every table takes the fits path, corrected on the next restyle once laid out.
        let padding = textView.textContainer?.lineFragmentPadding ?? 5
        let inset = textView.textContainerInset.width
        // The width of a container that exactly fills the viewport: from the scroll view's clip in the real
        // app; fall back to the text container's own width when there's no scroll view (headless tests /
        // detached view). 0 ⇒ not laid out yet → every table takes the fits path (availableWidth huge).
        let clipContentWidth = textView.enclosingScrollView?.contentView.bounds.width ?? 0
        let viewportContainerWidth = clipContentWidth > 0 ? clipContentWidth - 2 * inset
                                                          : (textView.textContainer?.size.width ?? 0)
        let availableWidth: CGFloat = viewportContainerWidth > 0
            ? viewportContainerWidth - 2 * padding - TableRendering.tableInset
            : .greatestFiniteMagnitude
        var maxTableRight: CGFloat = 0   // widest table's TRUE laid-out width (from its first glyph); 0 ⇒ no table

        var quotes: [NSRange] = []   // blockquote ranges → 3px left bar drawn by the text view
        var rules: [NSRange] = []    // thematic-break ranges → 1px rule drawn by the text view
        var codeCards: [NSRange] = [] // code-block ranges → rounded elevated card drawn by the text view
        var tableGrids: [TableGrid] = [] // GFM tables → card + aligned grid (block range + column-rule offsets)
        var inlineCode: [NSRange] = [] // inline `code` ranges → rounded pill drawn by the text view (tight)

        storage.beginEditing()
        storage.setAttributes([.font: baseFont, .foregroundColor: NSColor.labelColor,
                               .paragraphStyle: mallowBodyParagraphStyle],
                              range: NSRange(location: 0, length: nsLen))
        for block in blocks {
            switch block.kindTag {
            case "Heading":
                if let level = block.headingLevel, let nr = nsRange(block.range) {
                    // Only ATX (`#`-prefixed) headings render big. A SETEXT heading — a line "underlined"
                    // by `---`/`===` — is rendered as a normal paragraph instead: otherwise typing a lone
                    // `-`/`=` on the line BELOW any text instantly balloons that text into a heading (e.g.
                    // the moment you start a list). The engine still reports it faithfully as a Heading;
                    // suppressing the big font here is a display choice. Detect ATX by the first
                    // non-indent char being `#`.
                    let nsSrc = s as NSString
                    var i = nr.location
                    let end = nr.location + nr.length
                    while i < end {
                        let c = nsSrc.character(at: i)
                        if c != 32 && c != 9 { break }  // skip the ≤3 chars of allowed indent
                        i += 1
                    }
                    if i < end, nsSrc.character(at: i) == 35, !block.inlines.isEmpty {  // '#' with text
                        let hz: CGFloat = (level == 1 ? 28 : level == 2 ? 22 : level == 3 ? 18 : 16) * zoom  // Mallow sizes × zoom
                        storage.addAttribute(.font, value: NSFont.boldSystemFont(ofSize: hz), range: nr)
                        continue  // ATX heading text is uniform — no inline pass
                    }
                    // setext heading, OR an empty heading still being typed (a lone `#`, now shown by
                    // `showOrphanHeadingMarkers`) → fall through to the inline pass, rendering as body text.
                }
            case "CodeBlock":
                if let nr = nsRange(block.range) {
                    storage.addAttribute(.font,   // code is uniform monospace
                        value: NSFont.monospacedSystemFont(ofSize: baseSize * zoom, weight: .regular), range: nr)
                    storage.addAttribute(.paragraphStyle, value: mallowCodeParagraphStyle, range: nr)
                    // The card hugs the CONTENT lines (range minus the ``` fence lines), not the whole
                    // block: a zero-height opening fence directly under a paragraph (no blank line between)
                    // merges into that paragraph's line fragment, which would pull a block-range card up
                    // over the paragraph. Drawing over content only sidesteps that.
                    let content = codeContentRange(nr, in: s as NSString)
                    if content.length > 0 { codeCards.append(content) }
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
                if let grid = TableRendering.style(block, map: map, storage: storage, hidden: hidden,
                                                   availableWidth: availableWidth) {
                    tableGrids.append(grid)
                    maxTableRight = max(maxTableRight, grid.totalWidth)   // for the container-width / h-scroll decision
                }
                continue   // TableRendering owns the cell font + column kern; skip the generic inline pass
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
                    inlineCode.append(nr)   // pill drawn by the text view (tight cap→baseline; a .backgroundColor
                                            // attribute would fill the whole airy line fragment → tall top gap)
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

        // Horizontal scroll: widen the container to the widest table's right edge (+ a small margin) so it
        // can be scrolled to; otherwise the container just fills the viewport. When it ends up wider than the
        // viewport, keep PROSE wrapping at the viewport by giving every NON-table paragraph an absolute
        // tailIndent there — so only the table extends into the scrolled region, never the prose.
        // Only widen the container when a table GENUINELY exceeds the viewport (→ horizontal scroll). A
        // fitting or last-column-wrapping table has totalWidth ≤ availableWidth, so it never triggers a
        // scroller — the container stays at the viewport width (no spurious h-scroll on ordinary docs).
        let neededContainerWidth = (availableWidth > 0 && maxTableRight > availableWidth)
            ? 2 * padding + TableRendering.tableInset + maxTableRight + 8
            : 0
        let containerWidth = viewportContainerWidth > 0 ? max(viewportContainerWidth, neededContainerWidth)
                                                        : max(textView.bounds.width, neededContainerWidth)
        if viewportContainerWidth > 0, containerWidth > viewportContainerWidth + 0.5 {
            let proseTail = viewportContainerWidth - 2 * padding   // the viewport's text-area right edge (absolute)
            let tableRanges = tableGrids.map(\.blockRange)
            storage.enumerateAttribute(.paragraphStyle,
                                       in: NSRange(location: 0, length: nsLen)) { value, range, _ in
                if tableRanges.contains(where: { NSIntersectionRange($0, range).length > 0 }) { return }  // tables keep their own edge
                let base = (value as? NSParagraphStyle) ?? mallowBodyParagraphStyle
                let p = base.mutableCopy() as! NSMutableParagraphStyle
                p.tailIndent = proseTail
                storage.addAttribute(.paragraphStyle, value: p, range: range)
            }
        }

        storage.endEditing()
        textView.textContainer?.size = NSSize(width: containerWidth, height: .greatestFiniteMagnitude)
        textView.tableContainerWidth = neededContainerWidth   // the resize observer keeps the container ≥ this live
        textView.viewportContainerWidth = viewportContainerWidth   // window-tracking decorations (code card, rule) clamp to it
        textView.codeCards = codeCards     // hand the decoration ranges to the view's draw pass
        textView.tableGrids = tableGrids
        textView.quoteBars = quotes
        textView.ruleLines = rules
        textView.inlineCodeRuns = inlineCode
        textView.needsDisplay = true
    }

    /// The UTF-16 range of a leading YAML frontmatter block (`---` … closing `---`), fences inclusive,
    /// or nil if the document doesn't open with one. Detection is the ENGINE's
    /// (`inkFrontmatterBodyStart`) — the same rule behind `document_title` and HTML-export stripping —
    /// so the editor's dimming can never drift from what the engine treats as metadata (it used to:
    /// the old Swift copy ignored the `key: value` requirement and broke on a blank line inside).
    private func frontmatterRange(_ s: String, nsLen: Int) -> NSRange? {
        let bodyStart = inkFrontmatterBodyStart(s)   // engine byte offset; 0 = no frontmatter
        guard bodyStart > 0 else { return nil }
        let end = min(byteToUTF16(s, bodyStart), nsLen)
        return end > 0 ? NSRange(location: 0, length: end) : nil
    }
}
