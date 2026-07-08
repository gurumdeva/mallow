// EditorViewModel — the editor's brain (the logic the old EditorController god-object mixed with
// window/menu plumbing). It owns the document state (file path, saved baseline, the cached parse,
// focus mode) and all the engine-driven work: parsing, live-preview styling, hide-syntax glyph
// computation, focus dimming, and command application. It drives an injected MarkdownTextView's
// storage; the EditorController owns the window/views and forwards delegate + menu events here.

import AppKit

final class EditorViewModel {
    private(set) weak var textView: MarkdownTextView?  // internal-read so the Folding/Commands extensions reach it

    var filePath: String?
    private(set) var baseline = ""
    /// True iff the file opened with a leading UTF-8 BOM (EF BB BF). The buffer text is BOM-free (Foundation
    /// strips it on read), so the save paths re-prepend it to preserve the file's exact bytes on disk.
    var hadBOM = false
    private(set) var blocks: [PBlock] = []      // cached parse (one parse per text change); written only by refresh()
    private(set) var hiddenChars = Set<Int>()   // UTF-16 indices of collapsed syntax glyphs (read by the layout-manager delegate)
    private(set) var bulletMarks = Set<Int>()   // UTF-16 indices of unordered `- ` dashes to render as `•` (glyph delegate)
    private(set) var taskBoxes = [Int: Bool]()  // UTF-16 index of a task `[ ]`/`[x]` inner char → isChecked (glyph delegate ☐/☑)
    private(set) var tablePipes = Set<Int>()    // UTF-16 indices of GFM table `|` to render as a space (glyph delegate)
    private(set) var tableRowChars = Set<Int>() // UTF-16 line-start of each table CONTENT row → padded taller + centered (layout delegate)
    private(set) var foldedChars = Set<Int>()   // UTF-16 line-start indices → zero-height lines (collapsed sections + code-block ``` fence lines; layout delegate)
    var focusMode = false                        // dim every block but the caret's
    var keepOnTop = false                         // pin this window above other apps (transient, per-window)
    var typewriterOn = false                      // View ▸ Typewriter Scrolling: keep the caret line centered (per-window)
    var allSectionsFolded = false                 // View ▸ Fold All Sections: collapse every heading's body to an outline
    var foldedHeadingStarts = Set<Int>()        // per-section folds: UTF-16 starts (reset on edit); the Folding extension mutates it
    var zoomFactor: CGFloat = 1 { didSet { restyler.zoom = zoomFactor; restyler.clearFontCache() } }  // text zoom (View ▸ Zoom)

    private var lastCaretLoc = 0                  // previous caret UTF-16 location — gives the hidden-run snap its direction
    private var isAdjustingSelection = false      // guards the re-entrant setSelectedRange in `snapCaretOutOfHiddenRuns`

    /// Applies all live-preview styling (block fonts/colors, inline marks, decoration ranges) and owns the
    /// styled-font cache; kept in zoom-sync by `zoomFactor`'s didSet above.
    private let restyler = Restyler()

    /// The glyph-level rendering delegate (hide syntax zero-width, `•` bullets, ☐/☑ boxes, `|`→space,
    /// folded lines, table-row padding). Owned HERE — not by the SwiftUI Coordinator — so headless tests
    /// exercise the exact same glyph pipeline the app renders. Installed on the layout manager in `init`.
    private var layoutDelegate: EditorLayoutDelegate?

    init(textView: MarkdownTextView) {
        self.textView = textView
        baseline = textView.string
        // Touching layoutManager forces TextKit 1, where the glyph-generation delegate fires (the
        // hide-syntax + substitution pipeline depends on it).
        let delegate = EditorLayoutDelegate(vm: self, textView: textView)
        layoutDelegate = delegate
        textView.layoutManager?.delegate = delegate
    }

    // MARK: derived state for the chrome

    var isDirty: Bool { inkIsDirty(textView?.string ?? "", baseline) }
    var displayName: String { (filePath as NSString?)?.lastPathComponent ?? L.t("doc.untitled") }
    /// The title shown in the window/chrome: the document's FIRST heading (`# …`) when it has one, else
    /// the filename (`displayName`) — Notion-style, so the user just types a heading at the top. Note
    /// `displayName`/`baseName` stay the FILENAME — rename and the save target operate on the file.
    var documentTitle: String {
        let heading = inkDocumentTitle(textView?.string ?? "")
        return heading.isEmpty ? displayName : heading
    }
    /// The first-heading title sanitized into a safe base filename (no extension), or "" when the
    /// document has no heading. Seeds the Save-As panel for an untitled document (Notion-style: a doc
    /// named by its title). Strips path-illegal characters and trims; the user can still edit it.
    var titleAsFileName: String {
        let heading = inkDocumentTitle(textView?.string ?? "")
        let cleaned = heading
            .components(separatedBy: CharacterSet(charactersIn: "/\\:\n\r\t"))
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        return String(cleaned.prefix(120))
    }
    /// `displayName` without a trailing `.md` (export filename / document title). Suffix-only — a blind
    /// `.replacingOccurrences(of:".md")` would mangle names like "notes.md.md" or "a.md.txt".
    var baseName: String {
        let n = displayName
        return n.lowercased().hasSuffix(".md") ? String(n.dropLast(3)) : n
    }

    func setPath(_ path: String?) { filePath = path }
    func markSaved(path: String, content: String) { filePath = path; baseline = content }

    // MARK: pipeline — parse once, then style + compute hidden syntax + focus.

    func refresh() {
        guard let textView, !textView.hasMarkedText() else { return }   // IME chokepoint — see restyle()
        blocks = inkParseBlocks(textView.string)
        // Hidden set FIRST: restyle's table pass measures each cell's VISIBLE width (markers dropped) to
        // size the grid columns, so it needs `hiddenChars` already computed. The two passes are otherwise
        // independent (recomputeHidden reads only the parse + string; restyle reads the parse + hidden set).
        recomputeHidden()
        restyle()
        applyFocus()
    }

    /// Apply live-preview styling to the text storage — delegates to the `Restyler` collaborator (which
    /// owns the styled-font cache and all the per-block/inline logic). Public so the focus-mode toggle in
    /// DocumentActions and `refresh` can drive it.
    ///
    /// IME CHOKEPOINT: refresh/restyle/applyFocus self-guard against a live composition. During marked
    /// text the parse and every index set are FROZEN at pre-composition offsets, and a full-document
    /// `setAttributes` strips the composition underline — so these must never run mid-composition. The
    /// guard used to be a convention each caller remembered (and some forgot: the focus-mode selection
    /// path re-styled per jamo); now it is enforced HERE, once. Callers may still guard earlier for
    /// their own sequencing (e.g. the Coordinator's deferred-refresh machinery re-runs after commit).
    func restyle() {
        guard let textView, !textView.hasMarkedText() else { return }
        restyler.restyle(in: textView, blocks: blocks, hidden: hiddenChars, zoom: zoomFactor)
    }

    /// Re-apply (or clear) focus-mode dimming via the `Restyler`. No-op when focus mode is off.
    /// Same IME chokepoint as `restyle()` (full-document color writes over frozen offsets).
    func applyFocus() {
        guard let textView, !textView.hasMarkedText() else { return }
        restyler.applyFocus(in: textView, enabled: focusMode)
    }

    /// Set focus mode and re-render with its exact recompute recipe: `restyle()` first wipes any prior
    /// dim (its base pass replaces attributes), then `applyFocus()` re-adds the dim only when turning ON.
    /// Owning the recipe here (instead of in DocumentActions' menu glue) keeps the ordering — and its IME
    /// chokepoint, inherited from restyle/applyFocus — with the state it drives.
    func setFocusMode(_ on: Bool) {
        focusMode = on
        restyle()
        if focusMode { applyFocus() }
    }

    /// The caret moved. Hidden syntax is caret-independent (markers are always hidden), so the only
    /// work is (a) keeping the caret/selection out of a hidden run's interior, and (b) focus mode
    /// re-dimming around the new caret block. Text is unchanged → the cached parse stands.
    func selectionChanged() {
        if isAdjustingSelection { return }   // re-entrant call from the snap's own setSelectedRange
        snapCaretOutOfHiddenRuns()
        if focusMode { restyle(); applyFocus() }
    }

    // MARK: caret / selection vs hidden syntax
    //
    // Hidden markers are zero-width glyphs, so a click or drag can land the caret (or a selection
    // endpoint) *inside* a hidden run — e.g. between the `(` and `)` of a link's `](url)` — where
    // every position shares one x and is visually indistinguishable. That makes the caret feel
    // stuck and a selection's range disagree with what's highlighted. Since markers don't exist as
    // far as the cursor is concerned, an endpoint never rests in a run's interior:
    //   • a bare caret jumps out to the run edge in its direction of travel (so ← / → step over a
    //     whole marker in one press), and
    //   • a selection grows to fully contain any partially-covered run (so selecting a link is
    //     atomic — the whole `[text](url)` — and the highlight matches the visible text exactly).
    private func snapCaretOutOfHiddenRuns() {
        guard let textView, !textView.hasMarkedText() else { return }  // never fight an IME composition
        // Don't mutate the selection in the middle of a live mouse-drag — NSTextView is tracking the
        // drag and re-deriving the range from the mouse each frame, so changing it here would fight
        // the tracking loop. The drag's end (mouseUp / a click's mouseDown) and arrow keys/shift-
        // select still snap; only the intermediate drag frames are skipped.
        if NSApp.currentEvent?.type == .leftMouseDragged { return }
        let total = (textView.string as NSString).length
        let sel = textView.selectedRange()
        let fixed = CaretSnap.snapped(sel, total: total, hidden: hiddenChars, lastCaret: lastCaretLoc)
        if fixed != sel {
            isAdjustingSelection = true
            textView.setSelectedRange(fixed)
            isAdjustingSelection = false
        }
        lastCaretLoc = textView.selectedRange().location
    }


    /// Which block kinds have hideable syntax (the `**`, `#`, `- `, `> ` gaps collapsed by
    /// `hideBlockGaps`). Internal so the hide-pass collector (now in HiddenSyntax.swift) can read it.
    static func hideable(_ tag: String) -> Bool {
        tag == "Paragraph" || tag == "Heading" || tag == "List" || tag == "BlockQuote"
    }

    func recomputeHidden() {
        guard let textView else { return }
        // The hidden set is a pure function of the parse + fold state (see HiddenSyntax.compute); store the
        // result for the layout-manager delegate, which reads these off the view model.
        let r = HiddenSyntax.compute(string: textView.string, blocks: blocks,
                                     folds: foldedHeadingStarts, foldAll: allSectionsFolded)
        bulletMarks = r.bulletMarks
        taskBoxes = r.taskBoxes
        tablePipes = r.tablePipes
        tableRowChars = r.tableRowChars
        foldedChars = r.foldedChars
        hiddenChars = r.hidden
        // Debug tripwires for the two keying contracts the layout delegate depends on (comment-only
        // until now): a newline must NEVER be hidden (zero-advancing a line break merges lines), and
        // zero-height coverage must include each collapsed line's newline (the fragment can report its
        // start there). Cheap, debug-builds-only, and they catch a new producer violating the contract
        // at development time instead of shipping a silent layout bug.
        #if DEBUG
        let ns = textView.string as NSString
        assert(!hiddenChars.contains { $0 < ns.length && ns.character(at: $0) == 10 },
               "hiddenChars must never contain a newline (see EditorLayoutDelegate zero-advance guard)")
        #endif
        // We just changed which glyphs are zero-width / zero-height — reflow + repaint so the block
        // decorations (cards, bars, pills, rules, grids) draw at the new geometry. restyle() also sets
        // needsDisplay (it always follows in refresh()); doing it here keeps recomputeHidden self-consistent.
        if let lm = textView.layoutManager {
            let full = NSRange(location: 0, length: (textView.string as NSString).length)
            lm.invalidateGlyphs(forCharacterRange: full, changeInLength: 0, actualCharacterRange: nil)
            lm.invalidateLayout(forCharacterRange: full, actualCharacterRange: nil)
            textView.needsDisplay = true
        }
    }

}
