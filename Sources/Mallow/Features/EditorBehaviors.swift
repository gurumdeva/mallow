// EditorBehaviors — two editor behaviors ported from the AppKit Features into the SwiftUI rewrite:
//
//   1. Typewriter scrolling (View ▸ Typewriter Scrolling, ⌃⌘T). When on, the caret's line is pinned
//      to the vertical centre of the scroll view: centred once the moment it's enabled, then re-centred
//      on every selection change. Ported from the old `TypewriterScroll.swift` (centerCaretLine): read
//      the caret glyph's bounding rect from the layout manager, convert it to the scroll view, and move
//      the clip view's bounds origin by the gap to the viewport midpoint, clamped to the document.
//      Markdown-as-truth is unaffected — this only scrolls; it never touches the buffer.
//
//   2. Debounced autosave. Once a document is backed by a file, edits are flushed to disk ~1.5s after
//      typing stops, so work isn't lost to a crash or a forgotten ⌘S. Ported from the old
//      `Autosave.swift` (scheduleAutosave/performAutosave): a non-repeating Timer reset on every edit;
//      on fire, a dirty + file-backed document is written atomically (utf8) and its saved baseline is
//      updated. Untitled documents are deliberately excluded (autosaving one would need a Save panel).
//
// In the AppKit build both lived as extensions on the EditorController god-object (the responder in the
// menu chain, owner of the autosave Timer). In the SwiftUI build the editor's NSTextViewDelegate is the
// representable's Coordinator, which has no equivalent timer slot — so the debounce/centring state lives
// here in a small plain object the Coordinator owns (`let behaviors = EditorBehaviors()`). The Coordinator
// forwards its two delegate callbacks in (textChanged / selectionChanged); the View menu toggle calls
// EditorDocument.toggleTypewriter().

import AppKit

/// A plain (non-@Observable) object the editor Coordinator owns: it holds the autosave debounce timer
/// and forwards text/selection changes into the two ported behaviors. One instance per Coordinator
/// (i.e. per editor window), matching the old per-controller autosave timer + per-window typewriter flag.
final class EditorBehaviors {
    /// Idle delay before an edited, file-backed document is flushed to disk. Matches the AppKit build's
    /// 1500ms: long enough to coalesce a burst of keystrokes into one write, short enough to feel safe.
    private static let autosaveDelay: TimeInterval = 1.5

    /// The in-flight debounce timer (non-repeating). Reset on every edit; nil when nothing is pending.
    private var autosaveTimer: Timer?

    /// Re-entrancy guard for the deferred write: a synchronous save path can drive a text mutation, and
    /// we never want a save to recursively schedule/perform another save while one is already running.
    private var isSaving = false

    // MARK: - Autosave (ported from Autosave.swift)

    /// Debounce a background save. Called from `Coordinator.textDidChange`. Each keystroke resets the
    /// countdown; only after editing pauses for `autosaveDelay` does the write fire — and only for a
    /// dirty, file-backed document (never an untitled one, which would need a Save panel).
    func textChanged(_ doc: EditorDocument) {
        // Always cancel the in-flight timer first: a fresh edit means the previous countdown is stale.
        autosaveTimer?.invalidate()
        autosaveTimer = nil

        // Untitled docs are never autosaved (no surprise dialog); a clean doc has nothing to write.
        guard doc.vm.filePath != nil, doc.vm.isDirty else { return }

        // Block-based timer with a weak doc: if the window closes mid-countdown the document can still
        // deallocate, and a fire that races a teardown simply finds nil and no-ops.
        autosaveTimer = Timer.scheduledTimer(withTimeInterval: Self.autosaveDelay,
                                             repeats: false) { [weak self, weak doc] _ in
            guard let self, let doc else { return }
            self.performAutosave(doc)
        }
    }

    /// The deferred write. Re-checks the guards (state may have changed during the idle window — e.g.
    /// the user hit ⌘S, or an Undo restored the saved text), then writes `doc.textView.string` to the
    /// file atomically as utf8 and updates the saved baseline via `markSaved`. Guards re-entrancy so a
    /// write can't recursively trigger another. Mirrors the AppKit build's performAutosave (which routed
    /// through saveDocument); here we inline the same atomic-utf8 write + markSaved bookkeeping.
    private func performAutosave(_ doc: EditorDocument) {
        autosaveTimer = nil
        guard !isSaving else { return }
        guard let path = doc.vm.filePath, doc.vm.isDirty else { return }

        // Don't let a background autosave clobber a file another window now owns (the manual Save path in
        // DocumentActions.write guards this the same way). Skip silently — the other window is the live
        // writer; a later edit reschedules, and a manual ⌘S would surface the conflict via an alert.
        if pathOpenInOtherWindow(path, excluding: doc) { return }

        isSaving = true
        defer { isSaving = false }

        let content = doc.textView.string
        do {
            try content.write(to: URL(fileURLWithPath: path), atomically: true, encoding: .utf8)
            doc.vm.markSaved(path: path, content: content)
            doc.revision &+= 1   // chrome re-renders the ● dirty dot now that the baseline matches
        } catch {
            // A failed background write stays silent (no surprise dialog from an autosave); the doc
            // remains dirty, so a later edit reschedules and the next manual ⌘S surfaces any error.
        }
    }

    // MARK: - Typewriter scrolling (ported from TypewriterScroll.swift)

    /// Re-centre the caret line as the selection moves. Called from `Coordinator.textViewDidChangeSelection`.
    /// No-op unless typewriter scrolling is on (the per-window `vm.typewriterOn` flag).
    func selectionChanged(_ doc: EditorDocument) {
        guard doc.vm.typewriterOn else { return }
        centerCaretLine(doc)
    }

    deinit {
        // Stop any pending autosave so a queued write can't fire after the Coordinator (and this object)
        // is torn down on window close.
        autosaveTimer?.invalidate()
        autosaveTimer = nil
    }
}

extension EditorDocument {
    /// View ▸ Typewriter Scrolling toggle. Flips the per-window flag, bumps `revision` (so the menu
    /// checkmark / chrome re-render), and on ENABLE centres the caret line immediately so "this line"
    /// jumps to the middle right away — matching the AppKit build's toggleTypewriter → centerCaretLine
    /// (it doesn't wait for the next selection move). Shares the centring math with EditorBehaviors via
    /// the internal `centerCaretLine(_:)` free function below, so enable-now and on-move stay identical.
    func toggleTypewriter() {
        vm.typewriterOn.toggle()
        revision &+= 1
        if vm.typewriterOn { centerCaretLine(self) }
    }
}

/// Scroll `doc`'s text view so the caret's line sits at the vertical centre of its scroll view. Shared
/// by `EditorBehaviors.selectionChanged` (on-move, while on) and `EditorDocument.toggleTypewriter`
/// (the moment it's enabled). No-op when typewriter scrolling is off, while an IME is composing (marked
/// text), or when the caret rect / scroll view can't be resolved yet (e.g. just after a buffer swap) —
/// all mirroring the AppKit build's guards. Only scrolls when the gap is ≥ 1pt so a caret already near
/// centre doesn't jitter. (Ported verbatim from TypewriterScroll.centerCaretLine; `textView` →
/// `doc.textView`, the flag is `doc.vm.typewriterOn`.)
///
/// A free function at module scope (not file-private) so both call sites — the Coordinator's selection
/// hook and the EditorDocument typewriter toggle — share this one centring implementation.
func centerCaretLine(_ doc: EditorDocument) {
    let textView = doc.textView
    guard doc.vm.typewriterOn else { return }
    // Skip during IME marked text — scrolling now would jump the candidate window (view.composing).
    guard !textView.hasMarkedText() else { return }
    guard let layoutManager = textView.layoutManager,
          let container = textView.textContainer,
          let clip = textView.enclosingScrollView?.contentView else { return }

    // Caret glyph rect in text-container space → text-view space (add the container origin). Using the
    // insertion point's glyph range gives the caret's line position even on an empty line.
    let caretCharRange = textView.selectedRange()
    let glyphRange = layoutManager.glyphRange(forCharacterRange: caretCharRange,
                                              actualCharacterRange: nil)
    var caretRect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: container)
    // boundingRect is empty at the very end of the text / on a trailing empty line; fall back to that
    // line's fragment rect so the last line still centres. Skip the fallback on an empty doc (no glyphs)
    // — boundingRect's extra-line-fragment rect at location 0 is already correct there.
    if caretRect.isEmpty, layoutManager.numberOfGlyphs > 0 {
        let g = min(glyphRange.location, layoutManager.numberOfGlyphs - 1)
        caretRect = layoutManager.lineFragmentRect(forGlyphAt: g, effectiveRange: nil)
    }
    let origin = textView.textContainerOrigin
    let caretMidY = caretRect.midY + origin.y

    // Target: put caretMidY at the centre of the currently visible rectangle, then clamp to the document
    // so we never scroll past the top/bottom (AppKit analogue of scrollTop += delta).
    let visible = clip.bounds                 // visible rect in document (text-view) coordinates
    let desiredOriginY = caretMidY - visible.height / 2
    guard let documentHeight = textView.enclosingScrollView?.documentView?.frame.height else { return }
    let maxOriginY = max(0, documentHeight - visible.height)
    let clampedY = min(max(0, desiredOriginY), maxOriginY)

    // Don't nudge if we're already essentially centred (mirrors the |delta| < 1 short-circuit).
    guard abs(clampedY - visible.origin.y) >= 1 else { return }

    // Move the clip view's bounds origin to the clamped target, then let the scroll view sync its
    // scroller/overlay. (clip.scroll(to:) sets the clip-view bounds origin; reflectScrolledClipView
    // updates the rest of the scroll view to match — the AppKit build's exact two-step.)
    var target = visible.origin
    target.y = clampedY
    clip.scroll(to: target)
    textView.enclosingScrollView?.reflectScrolledClipView(clip)
}
