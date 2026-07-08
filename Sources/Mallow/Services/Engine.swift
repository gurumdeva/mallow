// Engine — the Inkstone boundary. Every call into the Rust core (the C-ABI in include/inkstone.h,
// linked as libinkstone.a) goes through here, plus the UTF-8(byte) ↔ char ↔ NSTextView(UTF-16)
// offset bridges. The rest of the app depends on THIS layer, never on the raw C symbols (SOLID DIP:
// the view-model talks to the engine through a single, swappable seam).

import CInkstone
import Foundation

// MARK: FFI string handling — every char* the engine returns is owned by us and freed here.

func inkTake(_ p: UnsafeMutablePointer<CChar>?) -> String {
    guard let p = p else { return "" }
    defer { inkstone_string_free(p) }
    return String(cString: p)
}
func inkParse(_ s: String) -> String { inkTake(inkstone_parse_json(s)) }
/// Parse `s` and decode the engine's block JSON into the UI model. The decode-or-empty idiom is
/// shared by everyone who needs the block tree (the view-model's render pipeline, the info-panel
/// outline), so it lives here behind the seam rather than being duplicated at each call site.
func inkParseBlocks(_ s: String) -> [PBlock] {
    (try? JSONDecoder().decode([PBlock].self, from: Data(inkParse(s).utf8))) ?? []
}
func inkCommand(_ name: String, _ s: String, _ anchor: Int, _ head: Int) -> String {
    inkTake(inkstone_apply_command(name, s, anchor, head))
}
/// Set the heading level of the block(s) covering [anchor, head] (char indices); level 0 = body.
func inkSetHeading(_ s: String, _ anchor: Int, _ head: Int, _ level: UInt8) -> String {
    inkTake(inkstone_set_heading(s, anchor, head, level))
}
func inkRenderHtml(_ s: String, _ title: String) -> String { inkTake(inkstone_render_html(s, title)) }
/// The document's title — the text of the FIRST heading (`#` …), or "" when there's no heading.
/// Drives the window/chrome title and the save-as default filename (falling back to the filename when
/// empty) — Notion-style "the first heading is the title", so the user just types a heading at the top.
func inkDocumentTitle(_ s: String) -> String { inkTake(inkstone_document_title(s)) }
/// The byte offset where the body begins after a leading YAML frontmatter block (`---` … `---`), or
/// 0 when the document doesn't open with frontmatter. One source of truth (the engine) for "what is
/// frontmatter": the render pass dims `[0, body_start)` as quiet metadata and the outline skips
/// headings inside it, rather than the app re-deriving the rule and drifting from `document_title` /
/// HTML-export stripping.
func inkFrontmatterBodyStart(_ s: String) -> Int { Int(inkstone_frontmatter_body_start(s)) }
/// `s` with any leading YAML frontmatter block removed (the body only), or `s` unchanged when there's
/// no frontmatter. For content statistics — words/characters/paragraphs count the body, not metadata —
/// matching HTML export, the window title, and the outline, which all ignore frontmatter. `body_start`
/// is a `\n`-aligned byte offset, so it always lands on a character boundary.
func bodyWithoutFrontmatter(_ s: String) -> String {
    let bs = inkFrontmatterBodyStart(s)
    guard bs > 0,
          let i = s.utf8.index(s.utf8.startIndex, offsetBy: bs, limitedBy: s.utf8.endIndex),
          let si = i.samePosition(in: s) else { return s }
    return String(s[si...])
}
/// Engine content-equality (NOT a debounced flag): true when `current` differs from `baseline`.
/// Used by the dirty dot + external-reload's disk-vs-baseline check.
func inkIsDirty(_ current: String, _ baseline: String) -> Bool { inkstone_is_dirty(current, baseline) }

// MARK: focus mode + offset queries that the engine answers (kept behind the seam too).

/// Byte offset of char index `ch` in `s` (the engine's source indexing; used to feed byte-based queries).
func inkCharToByte(_ s: String, _ ch: Int) -> Int { inkstone_char_to_byte(s, ch) }
/// The focus-mode decoration JSON for the block at source byte `caret` ("null" when between blocks).
func inkFocusDecoration(_ s: String, _ caret: Int) -> String { inkTake(inkstone_focus_decoration(s, caret)) }

// MARK: Offset bridges — Inkstone uses source BYTE ranges (parse) / CHAR indices (commands);
// NSTextView uses UTF-16 (NSRange). These convert between the three indexings.

func byteToUTF16(_ s: String, _ byte: Int) -> Int {
    let u8 = s.utf8
    guard byte >= 0,
          let i = u8.index(u8.startIndex, offsetBy: byte, limitedBy: u8.endIndex),
          let si = i.samePosition(in: s) else { return s.utf16.count }
    return si.utf16Offset(in: s)
}

/// A byte-offset → UTF-16-offset lookup table for `s`, built in one linear pass: `map[b]` is the UTF-16
/// offset of source byte `b` (engine ranges always land on a character boundary). Single calls to
/// `byteToUTF16` are O(b) — fine once, but a whole-document restyle converts every block/inline range,
/// turning the per-keystroke cost O(n²). The styling pipeline builds this once per parse and converts
/// each range through `PRange.utf16Bounds(map:clampedTo:)` in O(1). `map.count == s.utf8.count + 1`.
func byteToUTF16Map(_ s: String) -> [Int] {
    var map = [Int](repeating: 0, count: s.utf8.count + 1)
    var byte = 0, u16 = 0
    for scalar in s.unicodeScalars {
        let v = scalar.value
        let bytes = v < 0x80 ? 1 : v < 0x800 ? 2 : v < 0x1_0000 ? 3 : 4   // UTF-8 width
        var k = 0
        while k < bytes { map[byte + k] = u16; k += 1 }                   // interior bytes → scalar start
        byte += bytes
        u16 += v < 0x1_0000 ? 1 : 2                                       // UTF-16 width (surrogate pair = 2)
    }
    map[byte] = u16   // one-past-the-end boundary == UTF-16 length
    return map
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

// MARK: Engine source-range → NSTextView UTF-16 — the bridge every render/hide pass needs.
// A `PRange` carries the engine's source BYTE offsets; the AppKit layer wants a clamped UTF-16
// NSRange (or its raw bounds for iteration). Centralized here so the parse → restyle / recompute-hidden
// / table / outline passes stop re-implementing `byteToUTF16(...) + min(..., total)` at every block.

extension PRange {
    /// This byte range as a clamped UTF-16 `(lo, hi)` pair in `s` (hi ≤ `total`). O(byte offset) per
    /// call — deprecated as a fence: called per-block/per-inline this is the historical O(n²) typing-lag
    /// bug (fixed twice: restyle 9f8acfc, tables/outline ece8fc5). Loops must use the map overload.
    @available(*, deprecated, message: "O(byte) per call — use utf16Bounds(map:clampedTo:) with a per-pass byteToUTF16Map in any loop")
    func utf16Bounds(in s: String, clampedTo total: Int) -> (lo: Int, hi: Int) {
        (byteToUTF16(s, start), min(byteToUTF16(s, end), total))
    }

    /// NSRange variant of the deprecated O(byte) conversion above — same fence, same reason.
    @available(*, deprecated, message: "O(byte) per call — use utf16Range(map:clampedTo:) with a per-pass byteToUTF16Map in any loop")
    func utf16Range(in s: String, clampedTo total: Int) -> NSRange? {
        let (lo, hi) = (byteToUTF16(s, start), min(byteToUTF16(s, end), total))
        guard hi > lo else { return nil }
        return NSRange(location: lo, length: hi - lo)
    }

    /// Same as `utf16Bounds(in:clampedTo:)` but converts through a prebuilt `byteToUTF16Map` in O(1)
    /// instead of an O(byte) walk — for the per-keystroke styling pipeline, which converts every range.
    func utf16Bounds(map: [Int], clampedTo total: Int) -> (lo: Int, hi: Int) {
        let last = map.count - 1
        let lo = map[Swift.min(Swift.max(start, 0), last)]
        let hi = Swift.min(map[Swift.min(Swift.max(end, 0), last)], total)
        return (lo, hi)
    }

    /// Map-based counterpart of `utf16Range(in:clampedTo:)` (O(1) per range; see `utf16Bounds(map:…)`).
    func utf16Range(map: [Int], clampedTo total: Int) -> NSRange? {
        let (lo, hi) = utf16Bounds(map: map, clampedTo: total)
        guard hi > lo else { return nil }
        return NSRange(location: lo, length: hi - lo)
    }
}
