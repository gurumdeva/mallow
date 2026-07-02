# Table Rendering v2 — One Size, Bounded Wrap, Horizontal Scroll

**Status:** proposed (not started) · **Target:** v1.2.0 · **Author:** autonomous PM session, 2026-06-30
**Supersedes:** the v1.1.6–v1.1.9 wrap/shrink policy (`TableRendering.swift` step 5 shrink path is removed).

---

## 1. Diagnosis — what the user's screenshots show, mapped to code

The Lesson 07 screenshots show four tables in ONE document rendered three different ways
("표 렌더링이 제각각"). Each symptom traces to a specific piece of the current implementation:

### D1 — Tables in one document render at different sizes (the "제각각" complaint)
The A-7 / NestJS-Spring comparison tables render visibly **smaller** than the 흐름 table above
them. Cause: the shrink-to-fit branch, `Sources/Mallow/Features/TableRendering.swift` step 5
(lines ~166–182). Shrinking is *per-table*, so a document mixes 15 pt tables with ~11–13 pt
tables. Whatever the fit math does, mixed sizes read as broken. **Any policy that scales fonts
per-table produces this; the fix is to remove per-table scaling entirely.**

### D2 — Card/grid geometry goes stale on window resize (text spills past the card)
In the 헷갈림/핵심 screenshots, the wrapped second column's text runs **past the card's right
border** and the vertical rule sits mid-text. Cause: there is **no resize → restyle hook**
(`grep frameDidChange|viewDidEndLiveResize` → zero hits). All table geometry — per-cell `.kern`,
`headIndent`, `TableGrid.totalWidth`, `interiorEdges` — is computed once per edit at the
then-current width (`Restyler.swift` ~line 90: `tableAvailableWidth` from
`textContainer.size.width`). The **text** relayouts live when the window resizes
(`widthTracksTextView = true`, `MarkdownEditor.swift:61`), but the decorations and kern are
frozen at the stale width. Widen the window after opening → text reflows to the new edge, card
stays at the old one. This was a known deferred limitation; the screenshots show it is a real,
visible defect, not an edge case.

### D3 — The wrap edge is implicit (the live container edge), not part of the table's model
In wrap mode the last column wraps wherever the container currently ends, while `headIndent`
comes from the frozen `lastColLeftX`. The two agree only at the width restyle last ran at —
another face of D2, but fixing it needs the wrap edge to become **explicit state**
(a `tailIndent`), not "wherever the container happens to end".

### D4 — Requirement: a too-wide table must scroll horizontally, never shrink
New requirement from the user: when rows are long, the table keeps its full size and the user
scrolls horizontally (Notion/GitHub behavior). Today the editor cannot h-scroll at all:
`isHorizontallyResizable = false`, `widthTracksTextView = true`, no horizontal scroller
(`MarkdownEditor.swift:59–66`).

---

## 2. Policy v2 (normative — every rule testable)

| # | Rule |
|---|------|
| P1 | **One size.** Every table renders at `tableFontSize` (15 pt). No per-table scaling, ever. The shrink path is deleted. |
| P2 | **Fit is untouched.** A table whose natural (kern-aligned) width fits the viewport renders exactly as today — byte-identical attributes. |
| P3 | **Long LAST cell wraps in its column.** Wrap is bounded by an explicit edge (`tailIndent`), rows grow taller, continuation lines align under the column (`headIndent`). Non-last cells never wrap (a row is one source line; only the trailing run can wrap — established in the v1.1.6 exploration). |
| P4 | **Wider than the viewport → horizontal scroll.** If the non-last columns alone exceed the viewport, the table keeps natural width and the *editor* scrolls horizontally. **Prose never h-scrolls**: body/list/quote/code/heading paragraphs keep wrapping at the viewport edge. |
| P5 | **The card always exactly bounds its table.** Visible table text ⊆ card ⊆ container, at any width, after any resize. No text outside the card, no card past the text. |
| P6 | **Reflow on width change.** Window/viewport width change recomputes kern, wrap edge, card, rules (debounced). No stale geometry. |
| P7 | **Many rows are first-class.** One horizontal rule per source row (a wrapped row spanning several fragments still gets exactly one), row padding per row, cost linear in rows. |

Decision tree per table (all at 15 pt):

```
naturalWidth ≤ viewport            → plain (P2)
else, viewportRemainder ≥ minLast  → wrap last column inside the viewport (P3; no h-scroll)
else                               → natural columns + bounded last column → WIDER than viewport
                                     → horizontal scroll (P4; replaces shrink)
```

where `viewportRemainder = viewportTextWidth − tableInset − lastColLeftX`, `minLast = 110`,
and the wrapped slot is `clamp(remainder or naturalLast, min: minLast, max: lastCap = 420)`.

---

## 3. Mechanism — why "wide container + per-paragraph `tailIndent`"

Rejected (from the v1.1.6 exploration, still true): a per-table `NSScrollView` overlay or
`NSTextTable` — both break markdown-as-truth (selection, ⌘F highlight, focus dimming, inline
editing across the boundary). The table must remain ordinary text in the one `NSTextView`.

Adopted — pure TextKit, everything stays native text:

1. **The text container may be wider than the viewport.**
   `containerWidth = max(viewportTextWidth, maxTableRequiredWidth)` recomputed each restyle.
   `viewportTextWidth = clipView.bounds.width − 2 × textContainerInset.width (88)`.
   The scroll view gets a horizontal scroller; when no table overflows, containerWidth ==
   viewportTextWidth → no scroller, pixel-identical to today (zero-regression guarantee).

2. **Prose wraps at the viewport via `tailIndent`.**
   `NSParagraphStyle.tailIndent > 0` is an *absolute* trailing margin measured from the leading
   edge. Setting `tailIndent = viewportTextWidth` on every NON-table paragraph makes prose wrap
   exactly where it wraps today, even inside a wider container. Applied only when
   `containerWidth > viewportTextWidth` (otherwise styles stay the shared statics — no change).

3. **The table's wrap edge becomes explicit.**
   In wrap mode the table paragraph gets `tailIndent = tableInset + lastColLeftX + slot`
   (and keeps `headIndent = tableInset + lastColLeftX`). The wrap edge is now part of the
   style, recomputed on every restyle/reflow — D3 gone by construction. In h-scroll mode the
   same mechanism caps an over-long last column at `lastCap` so a giant cell can't make the
   table absurdly wide (wrap and h-scroll compose).

4. **Resize wiring** (also fixes D2 on its own): observe the clip view's frame, debounce,
   re-run the style pass. The parse and hidden set are width-independent — only `restyle()`
   reruns.

---

## 4. Implementation phases

### Phase 0 — Spike: prove the TextKit interplay (½ day, throwaway test)
A headless XCTest that lays out one wrapped table + one prose paragraph in a container wider
than the "viewport", asserting:
- `tailIndent` (positive/absolute) actually breaks lines at that x, with `headIndent` hanging
  alignment intact, in the presence of per-char `.kern` and `.null`-glyph (hidden) characters;
- `isHorizontallyResizable = true` + `widthTracksTextView = false` + manual
  `textContainer.size.width` produces the expected `usedRect`/frame width (scroller range).
Abort criteria: if `tailIndent` misbehaves with zero-width glyphs, fall back to wrapping the
last column at the container edge and capping via container width only (slightly weaker P3,
same P1/P2/P4–P7).

### Phase 1 — Resize reflow (standalone fix for D2; shippable on its own)
**`Sources/Mallow/Editor/MarkdownEditor.swift`** (`makeNSView`, Coordinator):

```swift
// makeNSView, after building `scroll`:
scroll.contentView.postsFrameChangedNotifications = true
context.coordinator.observeWidth(of: scroll.contentView)

// Coordinator:
private var widthObserver: NSObjectProtocol?
private var lastLayoutWidth: CGFloat = 0
private var reflowWork: DispatchWorkItem?

func observeWidth(of clipView: NSClipView) {
    widthObserver = NotificationCenter.default.addObserver(
        forName: NSView.frameDidChangeNotification, object: clipView, queue: .main
    ) { [weak self] _ in self?.scheduleReflow(clipView.bounds.width) }
}

private func scheduleReflow(_ width: CGFloat) {
    guard abs(width - lastLayoutWidth) > 0.5 else { return }
    lastLayoutWidth = width
    reflowWork?.cancel()
    let work = DispatchWorkItem { [weak self] in self?.vm.restyle() }   // parse + hidden are width-independent
    reflowWork = work
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
}
```
(Deregister in deinit. `EditorViewModel.restyle()` already exists and is idempotent.)
**Acceptance:** open a doc with a wrapped table, resize wider/narrower → card, rules, kern and
wrap all follow within ~120 ms. The screenshot-4/5 defect is unreproducible.

### Phase 2 — Horizontal-scroll infrastructure
**`MarkdownEditor.swift` `makeNSView` (lines 55–66):**
```swift
textView.isHorizontallyResizable = true          // was false
textView.autoresizingMask = []                    // width now managed by the style pass
textView.textContainer?.widthTracksTextView = false   // was true
scroll.hasHorizontalScroller = true
scroll.autohidesScrollers = true
```
**`Restyler.swift`** — own the width model at the top of `restyle(in:blocks:hidden:zoom:)`:
```swift
let viewportTextWidth = (textView.enclosingScrollView?.contentView.bounds.width
                         ?? textView.frame.width) - 2 * textView.textContainerInset.width
// … run the block passes; TableRendering returns each grid's requiredWidth …
let containerWidth = max(viewportTextWidth, maxTableRequiredWidth)
textView.textContainer?.size.width = containerWidth
if containerWidth > viewportTextWidth + 0.5 {
    // overlay prose wrap: body/quote/code styles + typingAttributes get a copy with
    // tailIndent = viewportTextWidth (cached per (style, width) pair)
}
```
`BottomOverscrollClipView` (scroll-past-end) must be checked to clamp only vertically —
one small read + test.
**`MarkdownTextView.swift` `drawBackground`:** card width
`min(grid.totalWidth, tc.size.width − (leftX − origin.x) − 4)` keeps the same *formula* but
`tc.size.width` is now the (possibly wider) container — i.e. the visible-width clamp that
truncated cards disappears; the card may extend into the scrolled region, which is now correct.
**Acceptance:** doc without wide tables → no horizontal scroller, layout pixel-identical;
prose lines never exceed the viewport in any doc.

### Phase 3 — `TableRendering.swift` policy rewrite
- **Delete step 5** (shrink, lines ~166–182) and the second `measure()` call — measurement runs
  once at `tableFontSize`; keep the helpers (they're clearer than inlining).
- Wrap decision (replaces step 6):
```swift
let remainder = viewportTextWidth - tableInset - lastColLeftX
let lastNatural = colSlot[colCount - 1]
let wrapLast: Bool
let slot: CGFloat
if laidOutWidth <= viewportTextWidth - tableInset { wrapLast = false; slot = lastNatural }      // P2
else if remainder >= minLast { wrapLast = true;  slot = min(lastNatural, max(remainder, minLast)) } // P3, no h-scroll
else                        { wrapLast = lastNatural > lastCap; slot = min(lastNatural, lastCap) }  // P4, h-scroll
```
- Paragraph style (step 7): keep `firstLineHeadIndent`/`headIndent`/`lineSpacing`; add
  `para.tailIndent = wrapLast ? tableInset + lastColLeftX + slot : 0`.
- Kern (step 8): unchanged, still skipping the last column iff `wrapLast`.
- Return: `totalWidth` becomes the TRUE laid-out width — `lastColLeftX + slot + (trailing pipe
  ? gap : 0)` in wrap mode, `laidOutWidth` otherwise. **Delete the
  `wrapLast ? availableWidth : laidOutWidth` hack** (the card then exactly bounds the table, P5).
  Add `requiredWidth: CGFloat` (= `tableInset + totalWidth + 8` right pad) for the Restyler's
  container computation. Signature: `availableWidth:` param renamed `viewportTextWidth:`.
- Constants: `minLast: CGFloat = 110`, `lastCap: CGFloat = 420` next to `tableInset`.

### Phase 4 — Tests + verification
Unit (replacing/extending the current 36):
1. `testTableUniformSize_neverShrinks` — synthetic wide-middle, wide-multi, huge tables all at
   15 pt (replaces `testTableShrink_wideNonLastColumn_scalesDownFloored`).
2. `testTableFit_unchanged` — fit table: no tailIndent, headIndent == inset, kern-all (existing
   wrap test keeps its fit assertions).
3. `testTableWrap_boundedByTailIndent` — long last col: headIndent/tailIndent exact; every line
   fragment's used maxX ≤ tailIndent + ε.
4. `testTableHScroll_wideNonLast` — container.width grows to requiredWidth; font stays 15 pt;
   card == totalWidth; prose paragraphs in the same doc carry tailIndent == viewportTextWidth
   and their fragments stay ≤ viewport.
5. `testResizeReflow` — style at W1, change clip width to W2, run the reflow → kern/tailIndent/
   card recomputed for W2 (no stale values survive).
6. `testManyRows_oneRulePerRow` — 12-row table → `rowStartChars.count == 11`; wrapped rows
   don't add rules.
Corpus sweep (temp diagnostic, not committed): all 236 real tables × {600, 824, 1200} pt —
assert text ⊆ card ⊆ container, all fonts 15 pt, prose ≤ viewport. 0 violations required.
GUI: the exact screenshot document (`step2 …/lesson_07_dependencies/README.md`) at 900/1100/
1400 pt + live resize both directions: A-7 4-col table h-scrolls at full size; 헷갈림 tables
wrap with the card exactly hugging; 흐름 table untouched; resize never detaches card from text.
Regression sweep: selection across a table, ⌘F inside a table (native find auto-h-scrolls —
verify), focus dim, cell editing, IME composition over a table row.

### Phase 5 — Release
v1.2.0 (new capability): CHANGELOG (`Changed`: uniform table size + horizontal scroll replaces
shrinking; `Fixed`: stale card/grid after window resize). Standard pipeline: build-app.sh →
DMG → notarize → `gh release create v1.2.0 --latest` → install. Memory update.

---

## 5. Edge cases & risks

| Case | Handling |
|------|----------|
| `tailIndent` × `.kern` × `.null` glyphs | Phase 0 spike proves it; fallback documented there. |
| Resize storms (live drag) | 120 ms trailing debounce; width-delta guard; restyle is the only recomputed pass. |
| `typingAttributes` staleness between edits | restyle runs on every `textDidChange`; typingAttributes updated alongside the overlay styles. |
| Scroll-past-end clip view | verify `BottomOverscrollClipView` constrains vertical only (Phase 2 read + test). |
| Zoom | `tableFontSize` is already zoom-independent (documented in code); width math uses points, orthogonal. Unchanged behavior. |
| Multiple wide tables | container = max(requiredWidth); each card its own width; one scroller. |
| 1-column / empty tables | `colCount >= 2` guards stay; early-return grid path untouched. |
| Find/⌘F into an off-screen column | native `usesFindBar` scrolls horizontally to the match — free with this design (verify in GUI pass). |
| Elastic over-scroll showing void right of prose | prose ends at viewport but background is the view's own `mallowBG` — visually uniform; check in GUI pass. |
| Performance, many rows | measurement is O(rows × cols) CTLine per restyle — corpus files (26 tables) already restyle in ms; 12-row test + debounce cover it. |

## 6. Explicit non-goals
Per-table independent scroll regions, sticky headers, drag column-resize; code-block
h-scrolling (natural follow-up — the same tailIndent/container machinery supports it, but out
of scope for v1.2.0).

## 7. Acceptance checklist (user's requirements → policy)
- 여러 행 (many rows) → P7 + test 6 (one rule per row, per-row padding, linear cost).
- 긴 셀 텍스트 (long cell text) → P3 bounded wrap for the last column; P4 natural width +
  h-scroll for any other column. Never shrunk (P1), never cut off (P5).
- 가로 스크롤 (horizontal scroll) → P4 via the wide-container + prose-tailIndent mechanism;
  prose reading is never affected.
- 렌더링 일관성 (the "제각각" complaint) → P1 one size + P5 card discipline + P6 reflow.
