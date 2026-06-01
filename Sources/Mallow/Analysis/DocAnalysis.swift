// DocAnalysis — pure document statistics + heading-outline extraction (no view code). Lifted out
// of the old AppKit InfoPanel so the SwiftUI DocumentInfoPopover can reuse it unchanged. DocStats
// counts words/characters/paragraphs/read-time; DocOutline walks the engine parse into headings.

import AppKit

// MARK: - Statistics (pure logic, mirrors the Tauri StatsCalculator)

/// Word / character / paragraph counts + a ~200 wpm read-time estimate for a markdown string.
/// Pure value type — no editor/engine dependency — so the numbers are testable in isolation.
struct DocStats {
    let words: Int
    let characters: Int
    let paragraphs: Int
    let readMinutes: Int

    init(markdown: String) {
        // Strip embedded images before counting (matches the reference): a pasted image's base64
        // data URI is a single enormous "word" that would wildly inflate characters + read time and
        // make an image-only line count as a prose paragraph. Newlines are preserved so paragraph
        // structure stays intact. Four passes: inline images, reference-style image uses, link/image
        // reference definitions, and a safety net for any leftover long data: token.
        var stripped = markdown
        for pattern in [
            #"!\[[^\]]*\]\(([^()]*(?:\([^()]*\)[^()]*)*)\)"#,   // ![alt](url) (1-level nested parens)
            #"!\[[^\]]*\]\[[^\]]*\]"#,                          // ![alt][id]
            #"(?m)^[ \t]{0,3}\[[^\]]+\]:[ \t]*\S.*$"#,          // [id]: url …  (definition line)
            #"data:[^\s)\]]{100,}"#,                            // leftover long data: URI (100+ chars)
        ] {
            stripped = stripped.replacingOccurrences(of: pattern, with: "",
                                                     options: .regularExpression)
        }

        let text = stripped.trimmingCharacters(in: .whitespacesAndNewlines)
        let chars = text.count
        guard chars > 0 else {
            words = 0; characters = 0; paragraphs = 0; readMinutes = 0
            return
        }

        characters = chars
        words = DocStats.countWords(text)
        paragraphs = DocStats.countParagraphs(stripped)
        // Latin-script read time is word-based at 200 wpm (the brief's target). Always at least 1m
        // for any non-empty document. CJK localization (500 chars/min) is a later follow-up.
        readMinutes = max(1, Int((Double(words) / 200.0).rounded(.up)))
    }

    /// Word count by whitespace splitting. AppKit has no Intl.Segmenter; this matches the Tauri
    /// fallback path (`text.split(/\s+/).filter(Boolean)`). CJK dictionary segmentation is a later
    /// follow-up (the reference also degrades to this split where Segmenter is unavailable).
    private static func countWords(_ text: String) -> Int {
        text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
    }

    /// Prose-paragraph count: blank-line-separated blocks that contain at least one non-structural
    /// (prose) line. Headings, list items, code fences, rules, and quotes are NOT paragraphs —
    /// mirrors the reference `countParagraphs`.
    private static func countParagraphs(_ markdown: String) -> Int {
        // Drop fenced code blocks so code lines never count as prose.
        let withoutCode = markdown.replacingOccurrences(
            of: #"```[\s\S]*?```"#, with: "\n\n", options: .regularExpression)
        var count = 0
        // Split on blank lines (≥2 newlines), then count any block that has a prose (non-structural)
        // line. Equivalent for-loop of the JS `.split(/\n{2,}/).filter(...).some(...)`.
        for block in splitBlankLineBlocks(withoutCode) {
            let lines = block.split(separator: "\n").map(String.init)
                .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            if lines.isEmpty { continue }                 // whitespace-only block
            if lines.contains(where: { !isStructuralLine($0) }) { count += 1 }
        }
        return count
    }

    /// Split text into blocks separated by one-or-more blank lines (≥2 newlines), matching
    /// JS `split(/\n{2,}/)`. Implemented directly (Foundation regex split is awkward for groups).
    private static func splitBlankLineBlocks(_ s: String) -> [String] {
        var blocks: [String] = []
        var current = ""
        var newlineRun = 0
        for ch in s {
            if ch == "\n" {
                newlineRun += 1
                if newlineRun >= 2 {
                    // A blank line ends the current block; collapse the rest of the run.
                    if newlineRun == 2, !current.isEmpty { blocks.append(current); current = "" }
                    continue
                }
                current.append(ch)
            } else {
                newlineRun = 0
                current.append(ch)
            }
        }
        if !current.isEmpty { blocks.append(current) }
        return blocks
    }

    /// A non-prose structural line: ATX heading / thematic break / list item / blockquote.
    private static func isStructuralLine(_ line: String) -> Bool {
        let s = line.trimmingCharacters(in: .whitespaces)
        func m(_ pattern: String) -> Bool {
            s.range(of: pattern, options: .regularExpression) != nil
        }
        return m(#"^#{1,6}\s"#)                  // heading
            || m(#"^(-{3,}|\*{3,}|_{3,})$"#)     // thematic break (hr)
            || m(#"^([-*+]|\d+[.)])\s"#)         // list item
            || m(#"^>"#)                         // blockquote
    }
}

// MARK: - Table of Contents (heading extraction off the engine parse)

/// One outline entry: the rendered heading text, its level, and the UTF-16 caret target in the
/// buffer (the start of the heading's text, mirroring the reference caret placement).
struct OutlineItem {
    let text: String
    let level: Int
    let caretUTF16: Int   // where to put the caret + scroll when this row is clicked
}

/// Extracts the document outline from the engine parse. Heading blocks carry their full source span
/// (including the `#` markers); the heading's inline runs carry the rendered text, so concatenating
/// those substrings gives the same clean text the WebView's `el.textContent` shows (no `#`/leading
/// space). The caret target is the first inline run's start (or the block start if a heading has no
/// inlines, e.g. an empty `##`).
enum DocOutline {
    static func extract(_ source: String, blocks: [PBlock]) -> [OutlineItem] {
        let ns = source as NSString
        let nsLen = ns.length
        let map = byteToUTF16Map(source)   // O(1) byte→UTF-16 per heading (else O(n²) over a long doc's headings)
        func b2u(_ b: Int) -> Int { map[Swift.min(Swift.max(b, 0), map.count - 1)] }
        // Skip headings inside a leading YAML frontmatter block: the closing `---` makes the engine
        // read the metadata as a setext heading, which must not show up as an outline row. Same engine
        // detection the render pass dims it with — one source of truth (see `inkFrontmatterBodyStart`).
        let fmBodyStart = inkFrontmatterBodyStart(source)
        var items: [OutlineItem] = []
        for block in blocks where block.kindTag == "Heading" && block.range.start >= fmBodyStart {
            let level = block.headingLevel ?? 1

            // Concatenate the inline-run substrings → rendered heading text (markers excluded).
            var text = ""
            for inline in block.inlines {
                if let r = inline.range.utf16Range(map: map, clampedTo: nsLen) {
                    text += ns.substring(with: r)
                }
            }
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)

            // Fallback for headings with no inline runs (empty heading): strip the leading `#`s and
            // spaces off the block's own source so the row still shows *something* sensible.
            if text.isEmpty, let r = block.range.utf16Range(map: map, clampedTo: nsLen) {
                let raw = ns.substring(with: r)
                text = raw.drop { $0 == "#" || $0 == " " || $0 == "\t" }
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }

            // Caret target: the first inline run's start (heading text start), else the block start.
            let caret = block.inlines.first.map { b2u($0.range.start) }
                ?? b2u(block.range.start)
            items.append(OutlineItem(text: text, level: level, caretUTF16: min(caret, nsLen)))
        }
        return items
    }
}
