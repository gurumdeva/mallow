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
    /// This byte range as a clamped UTF-16 `(lo, hi)` pair in `s` (hi ≤ `total`). Use when a pass needs
    /// the raw bounds to iterate; `utf16Range` wraps the same pair as an NSRange.
    func utf16Bounds(in s: String, clampedTo total: Int) -> (lo: Int, hi: Int) {
        (byteToUTF16(s, start), min(byteToUTF16(s, end), total))
    }

    /// This byte range as a UTF-16 `NSRange` in `s`, clamped to `total`; nil when empty/inverted after
    /// clamping (so callers can `guard let` instead of repeating the `hi > lo` check).
    func utf16Range(in s: String, clampedTo total: Int) -> NSRange? {
        let (lo, hi) = utf16Bounds(in: s, clampedTo: total)
        guard hi > lo else { return nil }
        return NSRange(location: lo, length: hi - lo)
    }
}
