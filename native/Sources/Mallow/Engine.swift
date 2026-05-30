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
func inkCommand(_ name: String, _ s: String, _ anchor: Int, _ head: Int) -> String {
    inkTake(inkstone_apply_command(name, s, anchor, head))
}
func inkRenderHtml(_ s: String, _ title: String) -> String { inkTake(inkstone_render_html(s, title)) }

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
