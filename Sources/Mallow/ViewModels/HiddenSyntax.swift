// HiddenSyntax — the markdown syntax-hiding machinery, extracted from EditorViewModel.
// A CharBuffer snapshot + a MarkerGrammar (bullet / quote / heading prefixes) feed the
// HiddenSyntaxCollector (the hide passes) and TablePipeScanner. EditorViewModel.recomputeHidden
// drives these to produce the zero-width-glyph index sets the layout-manager delegate reads.

import AppKit

/// A one-shot `[unichar]` snapshot of an NSString. The hide-syntax scanners read characters in tight
/// whole-document loops; routing each read through `-[NSString characterAtIndex:]` is an ObjC message
/// send per character and measured as roughly half the per-keystroke styling cost on large notes.
/// Reading the buffer once and indexing the array turns each access into a plain subscript.
/// `lineRange(for:)` delegates to the backing string (called per line, not per char, so it stays cheap).
struct CharBuffer {
    private let chars: [unichar]
    let ns: NSString
    init(_ ns: NSString) {
        self.ns = ns
        let n = ns.length
        guard n > 0 else { chars = []; return }
        var buf = [unichar](repeating: 0, count: n)
        ns.getCharacters(&buf, range: NSRange(location: 0, length: n))
        chars = buf
    }
    @inline(__always) func character(at i: Int) -> unichar { chars[i] }
    @inline(__always) func lineRange(for r: NSRange) -> NSRange { ns.lineRange(for: r) }
    var length: Int { chars.count }
}

/// The line-leading marker grammar over the buffer: where a list bullet / ordered number / nested
/// blockquote prefix ends, and (for lists) the exact set of marker chars to KEEP visible. Pure — it
/// only reads the buffer; it never decides what to hide. The marker must stay visible so a delimiter
/// opening the first inline (e.g. `- **bold**`) still collapses while the `- ` does not.
struct MarkerGrammar {
    let ns: CharBuffer

    func isMarkerSpace(_ c: unichar) -> Bool { c == 32 || c == 9 }

    /// The layout of a GFM task checkbox: the inner char's UTF-16 index (the ` `/`x`/`X` between the
    /// brackets — substituted with ☐/☑ and the char a click-toggle rewrites) plus whether it's checked.
    /// The brackets sit at `inner - 1` (`[`) and `inner + 1` (`]`), so callers derive them without a
    /// richer struct.
    struct TaskBox { let inner: Int; let checked: Bool }

    /// If `start` opens a task-list checkbox `[ ] ` / `[x] ` / `[X] ` (a marker space must follow the `]`,
    /// so `[link] ` is not a box), return its layout; otherwise nil. The single shape test both the hide
    /// pass and the click-toggle use, so the box kept visible is exactly the box a click flips.
    func taskBoxAt(_ start: Int, _ lineHi: Int) -> TaskBox? {
        guard start + 3 < lineHi, ns.character(at: start) == 91 /* [ */ else { return nil }
        let inner = ns.character(at: start + 1)
        let checked = inner == 120 || inner == 88 /* x/X */
        guard inner == 32 || checked,
              ns.character(at: start + 2) == 93 /* ] */,
              isMarkerSpace(ns.character(at: start + 3)) else { return nil }
        return TaskBox(inner: start + 1, checked: checked)
    }

    /// If `start` opens a task-list checkbox, the index past it (so the box stays visible as part of the
    /// marker); otherwise `start` unchanged. Thin wrapper over `taskBoxAt` so the skip and the record
    /// share one shape test.
    func skipTaskBox(_ start: Int, _ lineHi: Int) -> Int {
        taskBoxAt(start, lineHi) != nil ? start + 4 : start
    }

    /// The parsed leading structure of one line: where the whole marker prefix ends (indent + nested
    /// `>` + bullet/number + task box — all kept visible), and the task box if the line is a `- [ ]`
    /// item. ONE walk feeds both `markerPrefixEnd` (the hide pass's "keep visible" span) and
    /// `taskBox(onLine:)` (the click-toggle / ☐ substitution), so the two can never drift — the
    /// duplication that used to live in TaskList's TaskBoxScanner.
    struct LineMarker { let prefixEnd: Int; let taskBox: TaskBox? }

    func lineMarker(_ lineLo: Int, _ lineHi: Int) -> LineMarker {
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
                return marker(afterBulletAt: i + 2, lineHi)  // bullet ends the marker; a box may follow
            }
            if c >= 48 && c <= 57 /* digit */ {  // ordered: N. / N)
                var j = i
                while j < lineHi && ns.character(at: j) >= 48 && ns.character(at: j) <= 57 { j += 1 }
                if j < lineHi, ns.character(at: j) == 46 || ns.character(at: j) == 41 /* . ) */,
                   j + 1 < lineHi, isMarkerSpace(ns.character(at: j + 1)) {
                    return marker(afterBulletAt: j + 2, lineHi)
                }
                return LineMarker(prefixEnd: i, taskBox: nil)  // a bare number is content, not a marker
            }
            return LineMarker(prefixEnd: i, taskBox: nil)
        }
        return LineMarker(prefixEnd: min(i, lineHi), taskBox: nil)
    }

    /// Resolve the marker end + task box given `start` = the index right after a `- `/`1. ` bullet.
    private func marker(afterBulletAt start: Int, _ lineHi: Int) -> LineMarker {
        let box = taskBoxAt(start, lineHi)
        return LineMarker(prefixEnd: box != nil ? start + 4 : start, taskBox: box)
    }

    /// The index where the line's leading marker prefix ends (indent + bullet/number/quote markers,
    /// incl. a task-box). A bare number with no `.`/`)` delimiter is content, not a marker.
    func markerPrefixEnd(_ lineLo: Int, _ lineHi: Int) -> Int {
        lineMarker(lineLo, lineHi).prefixEnd
    }

    /// The GFM task checkbox on this line (list item with a `[ ]`/`[x]` right after the bullet), or nil.
    func taskBox(onLine lineLo: Int, _ lineHi: Int) -> TaskBox? {
        lineMarker(lineLo, lineHi).taskBox
    }

    /// Every task checkbox in the half-open UTF-16 range `[lo, hi)` (a List block's clamped span),
    /// scanned line by line, as `innerIndex → checked`. The KEY is the inner char's UTF-16 index (the
    /// char to substitute with ☐/☑ and the char a toggle rewrites); the brackets are at `inner ∓ 1`.
    func boxes(in lo: Int, _ hi: Int) -> [Int: Bool] {
        var found: [Int: Bool] = [:]
        let rangeHi = min(hi, ns.length)
        var lineStart = max(0, lo)
        while lineStart < rangeHi {
            let line = ns.lineRange(for: NSRange(location: lineStart, length: 0))
            let lineHi = min(line.location + line.length, rangeHi)
            if let b = taskBox(onLine: line.location, lineHi) { found[b.inner] = b.checked }
            if line.length == 0 { break }   // guard against a zero-length tail loop
            lineStart = line.location + line.length
        }
        return found
    }

    /// Scan ALL `List` blocks in one parse and return the merged `innerIndex → checked` map.
    /// `byteToUTF16` bridges each block's engine BYTE range to UTF-16 (same as recomputeHidden).
    func allBoxes(_ blocks: [PBlock], map: [Int]) -> [Int: Bool] {
        var out: [Int: Bool] = [:]
        for block in blocks where block.kindTag == "List" {
            let (bLo, bHi) = block.range.utf16Bounds(map: map, clampedTo: ns.length)
            for (inner, checked) in boxes(in: bLo, bHi) { out[inner] = checked }
        }
        return out
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
struct HiddenSyntaxCollector {
    let ns: CharBuffer
    let map: [Int]   // byte→UTF-16 lookup (O(1) range conversion; see byteToUTF16Map)
    let total: Int
    let grammar: MarkerGrammar
    var hidden = Set<Int>()
    var fenceChars = Set<Int>()   // ALL chars of each ``` fence line → zero-height (so the code card hugs the code).
                                  // Must be every char, not just the line start: the layout reports a hidden-`.null`-
                                  // glyph fence line's fragment char-start PAST the hidden ``` (at the newline), so a
                                  // line-start-only set misses it in the shouldSetLineFragmentRect match.

    init(ns: CharBuffer, map: [Int], total: Int) {
        self.ns = ns
        self.map = map
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
            let (bLo, bHi) = block.range.utf16Bounds(map: map, clampedTo: total)
            let covered = block.inlines
                .map { $0.range.utf16Bounds(map: map, clampedTo: total) }
                .sorted { $0.lo < $1.lo }
            let keep = (block.kindTag == "List") ? grammar.leadingMarkers(bLo, bHi) : Set<Int>()
            var cursor = bLo
            // Leading gap (Paragraph only): peel leading whitespace so indentation typed at the START of a
            // paragraph stays VISIBLE — the symmetric twin of the trailing-whitespace peel below. pulldown
            // strips a paragraph's insignificant leading whitespace from its first inline run, so otherwise
            // it lands in the leading gap and gets zero-width-hidden (you type spaces and nothing shows).
            // Scoped to Paragraph because Heading/List/BlockQuote leading gaps are the block MARKER (`#`,
            // `- `, `> `) + padding, which MUST stay hidden; their gaps start with a non-whitespace marker
            // so the peel would stop immediately anyway — the guard just makes that intent explicit/safe.
            if block.kindTag == "Paragraph" {
                while cursor < bHi {
                    let c = ns.character(at: cursor)
                    if c == 32 || c == 9 { cursor += 1 } else { break }
                }
            }
            for (lo, hi) in covered {
                if lo > cursor { collapse(cursor, lo, keep: keep) }
                cursor = max(cursor, hi)
            }
            // Trailing gap: peel trailing whitespace so a just-typed trailing space/tab stays VISIBLE and the
            // caret visibly advances. pulldown excludes trailing whitespace from the last inline run, so
            // without this peel it falls in the gap and gets zero-width-hidden — typing a space at the end of
            // a line looked like nothing happened (the caret sat on an invisible char). Real trailing SYNTAX
            // (a closing `##`, a hard-break `\`) is non-whitespace, so it is still hidden.
            if cursor < bHi {
                var hi = bHi
                while hi > cursor {
                    let c = ns.character(at: hi - 1)
                    if c == 32 || c == 9 || c == 10 || c == 13 { hi -= 1 } else { break }
                }
                if hi > cursor { collapse(cursor, hi, keep: keep) }
            }
        }
    }

    /// Reveal a block marker that has no text on its own line, so a marker you've typed but not yet given
    /// content shows literally instead of vanishing ("you typed it, you should see it"):
    ///   • a lone list bullet — `-` / `*` / `+` / `1.` with nothing after it (an empty list item). The
    ///     bullet pipeline only draws `•` for a `- ` WITH a trailing space, so a BARE `-` was neither
    ///     bulleted nor kept and fell into the gap → hidden. Now it shows until you type the space/content
    ///     that turns it into a real bullet.
    ///   • a SETEXT underline — `Title\n---` / `Title\n===` (rendered as a plain paragraph here, so the
    ///     `---`/`===` below is plain text). Typing a lone `-` under a line used to show nothing.
    ///   • the bare `#` of an EMPTY heading you're still typing (`#`, `## `).
    /// A marker that ALREADY has a visible stand-in stays hidden: a `- ` bullet draws `•`, a `>` draws its
    /// quote bar (so BlockQuote is EXCLUDED), and a closing `# H #` / a real heading's `#` share the text's
    /// line. This pass only ever UN-hides; the later bullet/task/table passes don't re-touch these chars.
    /// Runs right after `hideBlockGaps`.
    mutating func showOrphanMarkers(_ blocks: [PBlock]) {
        for block in blocks
        where EditorViewModel.hideable(block.kindTag) && block.kindTag != "BlockQuote" {
            let (bLo, bHi) = block.range.utf16Bounds(map: map, clampedTo: total)
            let runs = block.inlines.map { $0.range.utf16Bounds(map: map, clampedTo: total) }
            guard let firstLo = runs.map(\.lo).min(), let lastHi = runs.map(\.hi).max() else {
                for i in bLo ..< bHi { hidden.remove(i) }   // empty block → reveal its raw marker
                continue
            }
            // The text sits on ONE line; keep that line's markers hidden, reveal every other line.
            var lineLo = firstLo
            while lineLo > bLo, ns.character(at: lineLo - 1) != 10 { lineLo -= 1 }
            var lineHi = lastHi
            while lineHi < bHi, ns.character(at: lineHi) != 10 { lineHi += 1 }
            for i in bLo ..< bHi where i < lineLo || i >= lineHi { hidden.remove(i) }
        }
    }

    /// Inline code's source range includes its backtick fences; collapse the leading/trailing ` runs so
    /// only the code text shows (rendered on its pill).
    mutating func hideInlineCodeFences(_ blocks: [PBlock]) {
        for block in blocks {
            for inline in block.inlines where inline.kindTag == "Code" {
                let (lo, hi) = inline.range.utf16Bounds(map: map, clampedTo: total)
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
            let (lo, hi) = block.range.utf16Bounds(map: map, clampedTo: total)
            var i = lo
            while i < hi { hideChar(i); i += 1 }
        }
    }

    /// Code-block fences: hide the ``` / ```lang opening + closing lines so only the code shows on its
    /// tint (a rounded card is drawn instead). Code content is untouched.
    mutating func hideCodeBlockFences(_ blocks: [PBlock]) {
        for block in blocks where block.kindTag == "CodeBlock" {
            let (bLo, bHi) = block.range.utf16Bounds(map: map, clampedTo: total)
            var lineStart = bLo
            while lineStart < bHi {
                let line = ns.lineRange(for: NSRange(location: lineStart, length: 0))
                let lineHi = min(line.location + line.length, bHi)
                var i = line.location
                while i < lineHi && grammar.isMarkerSpace(ns.character(at: i)) { i += 1 }   // skip indent
                let isFence = i + 2 < lineHi
                    && ns.character(at: i) == 96 && ns.character(at: i + 1) == 96 && ns.character(at: i + 2) == 96
                if isFence {
                    // Zero-height this fence line so the code card (drawn over the whole block range) hugs
                    // the code instead of trailing empty tint where the hidden ``` line still took a row.
                    // Record EVERY char of the line (incl. its newline) so the zero-height match in
                    // shouldSetLineFragmentRect lands regardless of which char the layout reports as the
                    // fragment start (the hidden ``` glyphs push it past the line start).
                    var j = line.location
                    while j < lineHi { fenceChars.insert(j); hideChar(j); j += 1 }
                }
                if line.length == 0 { break }
                lineStart = line.location + line.length
            }
        }
    }
}

/// The "no raw table markers" scan over GFM `Table` blocks (a true cell-bordered grid needs engine cell
/// ranges, absent today). Pure over the NSString; for every table it collects the UTF-16 indices of each
/// `|` bar on a content row (→ rendered as a space, keeping monospace columns aligned) and of every char
/// on the `|---|` delimiter row (→ hidden). Like `MarkerGrammar`'s box scan: detection only, no mutation.
struct TablePipeScanner {
    let ns: CharBuffer
    let total: Int

    /// `pipes` = bar indices to render as spaces; `hide` = delimiter-row chars whose GLYPHS to drop (no
    /// newline — hiding a newline glyph would merge lines); `collapse` = the delimiter row's chars INCLUDING
    /// its newline, for the zero-height fold set (the row is all-hidden, so its fragment can report the
    /// newline as the line start — that char must be in the fold set or the row won't collapse);
    /// `rowStarts` = the line-start char of each CONTENT row (header + body, not the delimiter), so the
    /// layout delegate can pad those rows vertically (cell breathing room around the grid rules).
    func scan(_ blocks: [PBlock], map: [Int]) -> (pipes: Set<Int>, hide: Set<Int>, collapse: Set<Int>, rowStarts: Set<Int>) {
        var pipes = Set<Int>(), hide = Set<Int>(), collapse = Set<Int>(), rowStarts = Set<Int>()
        for block in blocks where block.kindTag == "Table" {
            let (bLo, bHi) = block.range.utf16Bounds(map: map, clampedTo: total)
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
                    while j < lineHi {
                        if ns.character(at: j) != 10 { hide.insert(j) }   // drop the glyph (not the newline)
                        collapse.insert(j)                                // fold the whole line incl. newline
                        j += 1
                    }
                    foundDelimiter = true
                } else if !linePipes.isEmpty {
                    for p in linePipes { pipes.insert(p) }
                    rowStarts.insert(line.location)   // a content row (header / body) → pad it vertically
                }
                if line.length == 0 { break }
                lineStart = line.location + line.length
            }
        }
        return (pipes, hide, collapse, rowStarts)
    }
}

/// Computes every syntax-hiding index set for one document state — pure (no view), so it is testable in
/// isolation. `EditorViewModel.recomputeHidden` stores the result for the layout-manager delegate to read.
enum HiddenSyntax {
    struct Result {
        var hidden = Set<Int>()         // zero-width-glyph indices (the markdown markers)
        var bulletMarks = Set<Int>()    // `- ` dashes drawn as •
        var taskBoxes = [Int: Bool]()   // task `[ ]`/`[x]` inner char → checked
        var tablePipes = Set<Int>()     // GFM `|` drawn as a space
        var tableRowChars = Set<Int>()  // table content-row line starts
        var foldedChars = Set<Int>()    // zero-height line starts (folds + ``` fences + table delimiter)
    }

    static func compute(string s: String, blocks: [PBlock],
                        folds foldedHeadingStarts: Set<Int>, foldAll allSectionsFolded: Bool) -> Result {
        var result = Result()
        let ns = s as NSString
        let total = ns.length
        let cb = CharBuffer(ns)   // bulk-read once; the scanners index this instead of -characterAtIndex:
        let map = byteToUTF16Map(s)   // O(1) byte→UTF-16 per range (the scanners convert every block range)
        // Markdown is the source of truth, but its syntax NEVER shows in the editor — you write and edit
        // clean styled text and change structure through commands (⌘B, Style ▸ H1…), not by touching raw
        // markers. So the hidden set is purely a function of the parse; it does NOT depend on the caret
        // (which is why `selectionChanged` no longer recomputes it). Pass order is irrelevant — each pass
        // only inserts into the same set.
        var collector = HiddenSyntaxCollector(ns: cb, map: map, total: total)
        collector.hideBlockGaps(blocks)        // the `#`/`**`/`> ` marker gaps in paragraphs/headings/lists/quotes
        collector.showOrphanMarkers(blocks)    // …but reveal a marker with no content yet (lone `-`/`#`, setext)
        collector.hideInlineCodeFences(blocks) // the ` backtick runs around inline code
        collector.hideThematicBreaks(blocks)   // the --- / *** / ___ source (a rule is drawn instead)
        collector.hideCodeBlockFences(blocks)  // the ``` opening/closing fence lines

        // Unordered-list dashes render as `•`, and GFM task `[ ]`/`[x]` as ☐/☑ — glyph substitution, also
        // unconditional (the raw `- ` / `[ ]` never shows). Task brackets collapse; the inner char carries
        // the ☐/☑ glyph (drawn by the layout-manager delegate).
        var bullets = Set<Int>()
        let grammar = MarkerGrammar(ns: cb)
        for block in blocks where block.kindTag == "List" {
            let (bLo, bHi) = block.range.utf16Bounds(map: map, clampedTo: total)
            for d in grammar.bulletDashes(bLo, bHi) { bullets.insert(d) }
        }
        result.bulletMarks = bullets

        var boxes = [Int: Bool]()
        for (inner, checked) in grammar.allBoxes(blocks, map: map) {
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
        result.taskBoxes = boxes

        // GFM tables: a true grid needs engine cell ranges, but the philosophy is "no raw markers". So
        // render every `|` as a space and hide the `|---|` delimiter row (see TablePipeScanner) — monospace
        // keeps the columns aligned, the bars just don't show.
        let table = TablePipeScanner(ns: cb, total: total).scan(blocks, map: map)
        result.tablePipes = table.pipes
        result.tableRowChars = table.rowStarts
        for h in table.hide { collector.hidden.insert(h) }

        // Fold All Sections: collapse every heading's body (the content between a heading and the next
        // heading) to a document outline. Re-derived from the live parse each refresh, so it follows edits
        // with no offset bookkeeping. Collapsed chars zero-height their lines (the layout-manager
        // `shouldSetLineFragmentRect` delegate reads `foldedChars`); their glyphs join the hidden set so
        // nothing leaks, and — being hidden — the caret snaps out of them like any hidden run. Heading
        // lines stay visible. Content before the first heading (the intro) is left expanded.
        var fold = Set<Int>()
        if allSectionsFolded || !foldedHeadingStarts.isEmpty {
            let headings = blocks.indices.filter { blocks[$0].kindTag == "Heading" }
            for (k, i) in headings.enumerated() {
                let (hStart, hEnd) = blocks[i].range.utf16Bounds(map: map, clampedTo: total)
                guard allSectionsFolded || foldedHeadingStarts.contains(hStart) else { continue }
                let nextStart = k + 1 < headings.count
                    ? blocks[headings[k + 1]].range.utf16Bounds(map: map, clampedTo: total).lo
                    : total
                guard nextStart > hEnd else { continue }
                for c in hEnd ..< nextStart {
                    fold.insert(c)
                    if cb.character(at: c) != 10 { collector.hidden.insert(c) }   // hide glyphs (keep newlines for line structure)
                }
            }
        }
        // Code-block ``` fence lines also collapse to zero height: their glyphs are already hidden, but the
        // line still occupied a row, so the card (drawn over the whole block range) showed empty tint above
        // the first/below the last code line. Merging them here reuses the same zero-height-fragment path.
        // Zero-height (collapse) both code-block ``` fence lines and the GFM table `|---|` delimiter row,
        // so neither leaves a blank full-height row. (Their glyphs are already hidden; this removes the row.)
        // `table.collapse` (not `table.hide`) includes the delimiter row's newline — needed because the
        // all-hidden row's fragment can report the newline as its start char.
        result.foldedChars = fold.union(collector.fenceChars).union(table.collapse)
        result.hidden = collector.hidden
        return result
    }
}
