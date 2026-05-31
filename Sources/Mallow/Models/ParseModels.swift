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

struct DynamicKey: CodingKey {
    var stringValue: String
    var intValue: Int?
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { self.intValue = intValue; self.stringValue = String(intValue) }
}

struct PBlock: Decodable {
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

struct ISelection: Decodable { let anchor: Int; let head: Int }
struct IEditResult: Decodable { let text: String; let selection: ISelection }
struct PDecoration: Decodable { let range: PRange }  // Focus-Mode block (or "null" → nil)
