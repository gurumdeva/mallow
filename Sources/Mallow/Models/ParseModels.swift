// ParseModels — the JSON view-model decoded from the engine's parse/command/decoration output.
// These mirror the Rust `Block`/`Inline`/`EditResult`/`Decoration` shapes (only the fields the UI
// needs; extra keys are ignored). They are the Model layer: plain data, no behavior.

import Foundation

struct PRange: Decodable { let start: Int; let end: Int }

struct PInline: Decodable {
    let range: PRange
    let marks: [String]
    let kindTag: String   // "Text" / "Code" / "Link"
    enum CodingKeys: String, CodingKey { case kind, range, marks }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        range = try c.decode(PRange.self, forKey: .range)
        marks = try c.decode([String].self, forKey: .marks)
        // InlineKind: "Text"/"Code" as a bare string; Link as {"Link": {"href": …}}.
        kindTag = c.serdeTag(forKey: .kind, default: "Text").tag
    }
}

struct DynamicKey: CodingKey {
    var stringValue: String
    var intValue: Int?
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { self.intValue = intValue; self.stringValue = String(intValue) }
}

extension KeyedDecodingContainer {
    /// Decode a serde-style enum tag at `key`: serde writes unit variants as a bare string ("Paragraph")
    /// and data variants as a single-key object ({"Heading": 2}). Returns the variant tag (the string, or
    /// the object's sole key) plus — for the object case — the nested container and that key, so the
    /// caller can read the associated value (e.g. the heading level). Falls back to `fallback` if neither
    /// shape decodes. Shared by `PInline`/`PBlock` so the branch ladder lives in one place.
    func serdeTag(forKey key: Key, default fallback: String)
        -> (tag: String, object: KeyedDecodingContainer<DynamicKey>?, dataKey: DynamicKey?) {
        if let s = try? decode(String.self, forKey: key) {
            return (s, nil, nil)
        }
        if let obj = try? nestedContainer(keyedBy: DynamicKey.self, forKey: key),
           let first = obj.allKeys.first {
            return (first.stringValue, obj, first)
        }
        return (fallback, nil, nil)
    }
}

/// One GFM table cell from the engine: its grid position, source BYTE range (the content between the
/// pipes, GFM padding spaces included), and the column's alignment. Present only on `Table` blocks; the
/// header is row 0, body rows follow, and a short body row is padded with empty (`range.length == 0`)
/// cells so every row has the header's column count. Drives the aligned-grid layout in TableRendering.
struct PTableCell: Decodable {
    let row: Int
    let col: Int
    let range: PRange
    let align: String   // "None" / "Left" / "Center" / "Right" (serde unit-variant → bare string)
}

struct PBlock: Decodable {
    let range: PRange
    let inlines: [PInline]
    let cells: [PTableCell]   // GFM table cells (empty for every non-Table block — key omitted by serde)
    let kindTag: String     // "Paragraph" / "Heading" / "List" / "BlockQuote" / "CodeBlock" / …
    let headingLevel: Int?
    enum CodingKeys: String, CodingKey { case kind, range, inlines, cells }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        range = try c.decode(PRange.self, forKey: .range)
        inlines = try c.decode([PInline].self, forKey: .inlines)
        // `cells` is serialized only for tables (skip_serializing_if on the Rust side), so decode it as
        // optional and default to empty — a paragraph/heading/etc. simply has no cells.
        cells = (try? c.decode([PTableCell].self, forKey: .cells)) ?? []
        // serde encodes BlockKind: unit variants as a string ("Paragraph"), data variants as a
        // single-key object ({"Heading": 2} / {"CodeBlock": {…}}). Pull the tag (+ heading level).
        let (tag, obj, dataKey) = c.serdeTag(forKey: .kind, default: "Other")
        kindTag = tag
        if tag == "Heading", let obj, let dataKey {
            headingLevel = try? obj.decode(Int.self, forKey: dataKey)
        } else {
            headingLevel = nil
        }
    }
}

struct ISelection: Decodable { let anchor: Int; let head: Int }
struct IEditResult: Decodable { let text: String; let selection: ISelection }
struct PDecoration: Decodable { let range: PRange }  // Focus-Mode block (or "null" → nil)
