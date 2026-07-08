// EditorViewModel+Commands — apply an engine command (toggle a mark, set a heading) to the current
// selection, then re-render. The buffer replace routes through the text view's undoable edit path.

import AppKit

extension EditorViewModel {
    func apply(_ command: EngineCommand) {
        guard let textView else { return }
        let s = textView.string
        let r = textView.selectedRange()
        var anchor = utf16ToChar(s, r.location)
        var head = utf16ToChar(s, r.location + r.length)
        // A wrapping toggle on a bare caret formats the word under it (never inserts an empty,
        // un-hideable delimiter pair). Caret not on a word (whitespace / blank line) → nothing to
        // format, so no-op rather than leave stray markers.
        if anchor == head, EngineCommand.wrapping.contains(command) {
            guard let (lo, hi) = wordScalarRange(s, caret: anchor) else { return }
            anchor = lo; head = hi
        }
        guard let edit = try? JSONDecoder().decode(
            IEditResult.self, from: Data(inkCommand(command.rawValue, s, anchor, head).utf8)
        ) else { return }
        replace(with: edit)
    }

    /// The Unicode-scalar range `[from, to)` of the word the caret sits in or touches, or nil when
    /// the caret isn't adjacent to any word scalar (whitespace / blank line). Scalar-indexed to
    /// match the engine (Inkstone `char` = Unicode scalar). A "word scalar" is any alphanumeric, so
    /// markdown delimiters (`*`, `` ` ``, `[`) are boundaries and a caret inside a styled word
    /// expands to exactly that word's text.
    private func wordScalarRange(_ s: String, caret: Int) -> (Int, Int)? {
        let scalars = Array(s.unicodeScalars)
        let n = scalars.count
        let c = max(0, min(caret, n))
        func isWord(_ u: Unicode.Scalar) -> Bool { CharacterSet.alphanumerics.contains(u) }
        var lo = c, hi = c
        while lo > 0, isWord(scalars[lo - 1]) { lo -= 1 }   // grow left over word scalars
        while hi < n, isWord(scalars[hi]) { hi += 1 }       // grow right over word scalars
        return lo < hi ? (lo, hi) : nil
    }

    func applyHeading(_ level: UInt8) {
        guard let textView else { return }
        let s = textView.string
        let r = textView.selectedRange()
        let anchor = utf16ToChar(s, r.location)
        let head = utf16ToChar(s, r.location + r.length)
        guard let edit = try? JSONDecoder().decode(
            IEditResult.self, from: Data(inkSetHeading(s, anchor, head, level).utf8)
        ) else { return }
        replace(with: edit)
    }

    private func replace(with edit: IEditResult) {
        // Never replace the buffer out from under a live IME composition (marked text): the input context
        // still holds the old marked range, so the next keystroke would replace against a now-resized
        // buffer (NSRangeException) or commit a mangled syllable. Bail mid-composition — the user finishes
        // the syllable, then re-issues the command. (Same IME guard refresh()/the caret-snap already use.)
        guard let textView, !textView.hasMarkedText() else { return }
        // Undoable replace — NOT `textView.string = …` (that registers no undo AND wipes the existing
        // undo stack). Route through the text view's edit path so ⌘Z reverts an engine command (bold,
        // heading, list, …) like any typing, and prior typing-undo history is preserved.
        let full = NSRange(location: 0, length: (textView.string as NSString).length)
        textView.replaceCharactersUndoably(in: full, with: edit.text)
        let a = charToUTF16(edit.text, edit.selection.anchor)
        let h = charToUTF16(edit.text, edit.selection.head)
        textView.setSelectedRange(NSRange(location: min(a, h), length: abs(h - a)))
        refresh()
    }
}
