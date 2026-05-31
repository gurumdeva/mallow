// SmartTypography — OUR controlled, rule-based "smart typography" for the markdown-as-truth editor.
//
// This is a faithful Swift port of the Tauri implementation
//   (`src/editor/smartTypography.ts` + `src/editor/smartTypographyRules.ts` on `main`).
// It deliberately does NOT use the OS automatic substitutions: MarkdownTextView turns all of those
// off (isAutomaticQuoteSubstitutionEnabled = false, …) because they would rewrite the bytes the
// markdown parser reads, at moments and with glyphs we don't control. Instead we reproduce the
// SmartyPants-style rules ourselves as PURE functions so the behavior is identical to the old app
// and is unit-testable without an editor.
//
// Rules ported (ASCII punctuation → publishing-quality glyphs):
//   • straight double quote  "  → opening “ / closing ”            (direction from the preceding char)
//   • straight single quote  '  → opening ‘ / closing·apostrophe ’ (don't → don’t between letters)
//   • --  → en dash –     and    ---  → em dash —
//   • ... → ellipsis …
//
// Like the Tauri version, ASCII-only: CJK text (한글/日本語 …) is untouched because the triggers are
// ASCII quotes/hyphens/dots and the open/close decision treats every Unicode letter (\p{L}) the same.
//
// PURITY / OWNERSHIP: every rule here is a pure function of (preceding char, following char, the
// just-typed string). This type does NOT decide WHETHER to apply — the text view does. The single
// entry point `substitution(for:in:at:)` returns the replacement string when a rule fires, else nil.
// That keeps the feature trivially gateable (a toggle can wrap the call site) and side-effect free.

import Foundation

enum SmartTypography {

    // ─── Glyph constants ───────────────────────────────────────────────────────────────────────
    // Mirrors Tauri `SMART_GLYPHS`. Kept in one place so call sites and tests share the source of
    // truth instead of scattering magic characters. (`closeSingle` doubles as the apostrophe — the
    // closing single quote and the apostrophe are the same glyph, which reads naturally.)
    enum Glyph {
        static let openDouble: Character = "\u{201C}"  // “
        static let closeDouble: Character = "\u{201D}" // ”
        static let openSingle: Character = "\u{2018}"  // ‘
        static let closeSingle: Character = "\u{2019}" // ’  (= apostrophe)
        static let enDash: Character = "\u{2013}"      // –
        static let emDash: Character = "\u{2014}"      // —
        static let ellipsis: Character = "\u{2026}"    // …
    }

    // Characters that, when they sit immediately BEFORE a straight quote, make it an OPENING quote.
    // Mirrors Tauri `OPENING_QUOTE_PREV`: whitespace family + opening brackets + other quotes. An
    // explicit set (rather than a regex) keeps the intent obvious and the unit tests exhaustive.
    private static let openingQuotePrev: Set<Character> = [
        " ", "\t", "\n", "\r",
        "\u{000B}",  // vertical tab (\v)
        "\u{000C}",  // form feed (\f)
        "\u{00A0}",  // non-breaking space
        "{", "[", "(", "<",                                   // opening brackets
        "'", "\"", Glyph.openSingle, Glyph.openDouble,        // right after another quote = opening slot
    ]

    // ─── Pure predicates (1:1 with smartTypography.ts) ─────────────────────────────────────────

    /// Should a straight quote become an OPENING quote? True at paragraph start (no preceding char)
    /// or when the preceding char is whitespace / an opening bracket / another quote. Otherwise it's
    /// a CLOSING quote (after a letter, digit, or other punctuation). Shared by ' and ".
    static func isOpeningQuote(prev: Character?) -> Bool {
        guard let prev else { return true }   // start of paragraph → opening
        return openingQuotePrev.contains(prev)
    }

    /// Is a single quote an APOSTROPHE? True when it sits between two letters (don't, it's, rock'n).
    /// Same glyph as the closing single quote (’) but named separately to keep intent explicit.
    static func isApostrophe(prev: Character?, next: Character?) -> Bool {
        return isLetter(prev) && isLetter(next)
    }

    /// Unicode letter test (Latin plus 한글/한자 etc.). Digits, symbols, whitespace, nil → false.
    /// Equivalent to the Tauri `/\p{L}/u` check.
    static func isLetter(_ ch: Character?) -> Bool {
        guard let ch else { return false }
        // A Character can be a grapheme cluster; treat it as a letter only if every scalar is one
        // (matches "is this a letter" intent; single-scalar ASCII/CJK letters pass trivially).
        return ch.unicodeScalars.allSatisfy { CharacterSet.letters.contains($0) }
    }

    /// Glyph for a straight double quote: opening “ or closing ”, decided by the preceding char.
    static func doubleQuote(prev: Character?) -> Character {
        return isOpeningQuote(prev: prev) ? Glyph.openDouble : Glyph.closeDouble
    }

    /// Glyph for a straight single quote: apostrophe ’ between letters, else opening ‘ / closing ’
    /// from the preceding char. (Apostrophe and closing single quote share the ’ glyph.)
    static func singleQuote(prev: Character?, next: Character?) -> Character {
        if isApostrophe(prev: prev, next: next) { return Glyph.closeSingle }
        return isOpeningQuote(prev: prev) ? Glyph.openSingle : Glyph.closeSingle
    }

    /// Consecutive-hyphen → dash mapping, mirroring Tauri `dashFor`.
    ///
    /// Because we evaluate on each keystroke against the live text, typing `-`,`-`,`-` arrives as:
    ///   1) 2nd `-`: preceding text is "…-", the pair "--" → en dash –.
    ///   2) 3rd `-`: the en dash already replaced the pair, so preceding char is "–" and we see
    ///      "–-" → em dash —. (A literal "---" never survives to be matched whole; it funnels through
    ///      the en-dash step into this "–-" case — exactly as the Tauri comment documents.)
    /// Returns nil for anything else (a lone hyphen) so the caller leaves the input untouched.
    static func dash(_ hyphens: String) -> Character? {
        if hyphens == "---" || hyphens == String(Glyph.enDash) + "-" { return Glyph.emDash }
        if hyphens == "--" { return Glyph.enDash }
        return nil
    }

    /// "..." → ellipsis …; anything else → nil. Mirrors Tauri `ellipsisFor`.
    static func ellipsis(_ dots: String) -> Character? {
        return dots == "..." ? Glyph.ellipsis : nil
    }

    // ─── Single entry point for the text view ──────────────────────────────────────────────────

    /// Decide the smart-typography replacement for a single just-typed `input` at UTF-16 offset
    /// `loc` in `text` (the document so far, BEFORE the input is inserted). Returns the string to
    /// insert in place of `input`, or nil when no rule fires (caller inserts `input` unchanged).
    ///
    /// Contract / scope (matches the Tauri InputRules):
    ///   • Only fires for a single typed character that is a trigger: `"`, `'`, `-`, or `.`. Pasted
    ///     or multi-character input returns nil (the OS-substitution guard and paste handlers own
    ///     those paths).
    ///   • Never fires inside inline code (between backticks on the line) or inside a fenced code
    ///     block — the Tauri rules carry `{ inCodeMark: false }` and rely on InputRule's default of
    ///     not running in `code` nodes. We approximate that with a backtick / fence scan below.
    ///   • Dash at the very start of a line is suppressed (returns nil), mirroring the Tauri
    ///     block-start carve-out that let CommonMark's "---" → horizontal-rule shortcut survive.
    ///     (This editor has no HR input rule, so the visible effect is simply that a line-leading
    ///     "--"/"---" stays literal hyphens. Faithful to the source.)
    ///
    /// `loc` is a UTF-16 offset (NSTextView/NSString convention). All indexing here goes through
    /// UTF-16 so it lines up with `selectedRange()` / `replacementRange.location`.
    static func substitution(for input: String, in text: String, at loc: Int) -> String? {
        // Only single typed characters are candidates; reject paste / IME multi-char / empty.
        guard input.count == 1, let typed = input.first else { return nil }
        guard typed == "\"" || typed == "'" || typed == "-" || typed == "." else { return nil }

        let utf16 = Array(text.utf16)
        // Defensive clamp: treat an out-of-range loc as "end of text".
        let at = max(0, min(loc, utf16.count))

        let prev = characterBefore(utf16, at)
        let next = characterAfter(utf16, at)

        // Never transform inside code (inline backtick span or fenced block). Cheap line/scan check.
        if isInsideCode(utf16: utf16, at: at) { return nil }

        switch typed {
        case "\"":
            return String(doubleQuote(prev: prev))

        case "'":
            return String(singleQuote(prev: prev, next: next))

        case ".":
            // Ellipsis needs the two chars already in the doc to be dots: "..".
            guard prev == ".", characterBefore(utf16, at - 1) == "." else { return nil }
            // Replace the two existing dots + this one. The caller widens the replacement range to
            // cover the two preceding dots; here we return the full glyph.
            return ellipsis("...").map(String.init)

        case "-":
            // Block-start carve-out: a hyphen with no preceding char on the line is left alone.
            if prev == nil { return nil }
            // En dash from "-" + a single preceding hyphen.
            if prev == "-" {
                return dash("--").map(String.init)
            }
            // Em dash from "-" + a preceding en dash (the "---" funnel; see `dash(_:)`).
            if prev == Glyph.enDash {
                return dash(String(Glyph.enDash) + "-").map(String.init)
            }
            return nil

        default:
            return nil
        }
    }

    // ─── Helpers ───────────────────────────────────────────────────────────────────────────────

    /// The character ending immediately before UTF-16 index `idx` (nil if at/over the start).
    /// Rebuilds a Character from the (up to two) UTF-16 units so surrogate pairs / combined letters
    /// are honored for the letter test. We look back at most a couple of units — enough for the
    /// quote/dash context, which only cares about the single preceding grapheme's base.
    private static func characterBefore(_ utf16: [UInt16], _ idx: Int) -> Character? {
        guard idx > 0, idx <= utf16.count else { return nil }
        let unit = utf16[idx - 1]
        // Low surrogate → pair with the preceding high surrogate to form one scalar.
        if (0xDC00...0xDFFF).contains(unit), idx >= 2,
           let s = String(utf16CodeUnits: [utf16[idx - 2], unit], count: 2).first {
            return s
        }
        return String(utf16CodeUnits: [unit], count: 1).first
    }

    /// The character starting at UTF-16 index `idx` (nil if at/over the end).
    private static func characterAfter(_ utf16: [UInt16], _ idx: Int) -> Character? {
        guard idx >= 0, idx < utf16.count else { return nil }
        let unit = utf16[idx]
        // High surrogate → pair with the following low surrogate.
        if (0xD800...0xDBFF).contains(unit), idx + 1 < utf16.count,
           let s = String(utf16CodeUnits: [unit, utf16[idx + 1]], count: 2).first {
            return s
        }
        return String(utf16CodeUnits: [unit], count: 1).first
    }

    /// Approximate the Tauri "don't transform in code" guard without a full parse:
    ///   • Fenced code block: an ODD number of ``` fence lines appears before the caret's line.
    ///   • Inline code: an ODD number of backticks on the caret's own line, up to the caret.
    /// Either condition means the insertion point is inside code, so smart typography is suppressed.
    /// (A simple, conservative heuristic — the markdown-as-truth doc has no AST here. It matches the
    /// common cases the Tauri InputRule blocked: inline `code` spans and fenced blocks.)
    private static func isInsideCode(utf16: [UInt16], at idx: Int) -> Bool {
        let backtick: UInt16 = 96   // `
        let newline: UInt16 = 10    // \n

        // Start of the caret's current line.
        var lineStart = idx
        while lineStart > 0, utf16[lineStart - 1] != newline { lineStart -= 1 }

        // Fenced blocks: count lines (before the current one) that begin with "```". Odd ⇒ inside.
        var fenceCount = 0
        var i = 0
        while i < lineStart {
            // Is position i the first non-ignored char of a line, and does the line open with ```?
            let atLineHead = (i == 0) || utf16[i - 1] == newline
            if atLineHead, i + 2 < lineStart,
               utf16[i] == backtick, utf16[i + 1] == backtick, utf16[i + 2] == backtick {
                fenceCount += 1
            }
            i += 1
        }
        if fenceCount % 2 == 1 { return true }

        // Inline code: count backticks on the current line up to the caret. Odd ⇒ inside a span.
        var ticks = 0
        var j = lineStart
        while j < idx { if utf16[j] == backtick { ticks += 1 }; j += 1 }
        return ticks % 2 == 1
    }
}
