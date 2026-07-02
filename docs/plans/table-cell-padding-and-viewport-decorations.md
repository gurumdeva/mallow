# Table Cell Padding + Viewport-Clamped Decorations (v2 follow-up)

**Status:** SHIPPED in v1.2.0 (build 24), 2026-07-02 · **Builds on:** `table-rendering-v2-hscroll.md`.
Two visual defects from the Lesson 08 screenshots.

**As-built note:** Issue 1 was implemented with a more robust model than the original "2×cellPad band" sketch
below. A headless glyph-measurement diagnostic showed the old rule offsets drifted off the actual layout by
an amount that *accumulates per column* (the `| ` source spaces around each pipe aren't in a fixed `gap`
model), so a constant correction couldn't fix multi-column tables. The shipped fix instead: column slots
carry content only; the REAL inter-cell separator widths are measured from the source (`spanWidth`, with `|`
drawn as a space); each rule is centred in its measured gap; and a small symmetric `slotPad` (6pt) trailing
room gives `(separator + slotPad)/2 ≈ 9pt` of padding on BOTH sides of every rule. Verified by a
padding-invariant unit test (measured glyph gaps, left≈right, both >4pt) and GUI on the real Lesson 08 tables.
Issue 2 shipped as designed (`viewportContainerWidth` + `decoWidth` clamp; inline code 0.92→0.85em).

---

## Issue 1 — Cells have no uniform inner padding (text sits on the rules)

### Diagnosis (exact, from `Sources/Mallow/Features/TableRendering.swift`)

The current spacing model is **asymmetric by construction**:

- `measure(at:)` adds one breathing gap INSIDE each column slot:
  `gap = space-width × 1.6 ≈ 6.7pt` at 15pt, then `colSlot[c] += gap` (trailing).
- `geometry(_:_:)` places the interior rule AFTER the slot at `edges.append(x + gap/2)`, then
  advances `x += gap` for the separator.

So around every interior rule: the LEFT side gets `gap + gap/2 ≈ 10pt` (the slot's trailing pad +
half the separator), but the RIGHT side gets only `gap/2 ≈ 3.4pt` — the next cell's text starts
~3pt from the rule. That is the "딱 달라붙은" look in the screenshot (`정리` column, and every
wrapped continuation line, start ~3pt after the rule).

The card is worse — it has **zero** padding on the outer columns:
- `MarkdownTextView.drawBackground` anchors the card at `leftX` = the **first glyph's minX**
  (the leading `|` is zero-width, so that IS the first text pixel) → column 1's text touches the
  card's left border.
- Card width = `grid.totalWidth` = the text span; in wrap mode the right edge = the `tailIndent`
  wrap edge → wrapped lines end exactly ON the card's right border.

Vertical padding is already fine (±6pt per row from the layout delegate + `lineSpacing = 5`) and
is not changed by this plan.

### Design — one `cellPad` constant, symmetric everywhere

Add `cellPad: CGFloat = 10` next to `tableInset` in `TableRendering`. Redefine the horizontal
model so **every vertical line (interior rules AND both card borders) has ≥ cellPad of space to
the nearest glyph on BOTH sides**:

1. **Column slots carry content only.** `colSlot[c]` = widest visible cell — drop the `+= gap`
   in-slot pad. Alignment kern (Left/Center/Right) distributes within this content slot, as today.
2. **Separator band = `2 × cellPad`, rule centered.** In `geometry`:
   `x += colSlot[c]; edges.append(x + cellPad); x += 2 * cellPad` — giving exactly `cellPad` on
   each side of every interior rule, for every row, including wrapped continuation lines (their
   `headIndent` start is the last column's slot start = `cellPad` after the rule automatically).
3. **Card inflated by `cellPad` on both sides.** Keep `TableGrid.totalWidth` = the text span;
   `drawBackground` draws the card at `leftX − cellPad` with width `totalWidth + 2·cellPad`
   (clamped to the container as today). In wrap mode the right edge becomes
   `tailIndent + cellPad` — wrapped lines no longer touch the border. Expose `cellPad` as an
   internal `TableRendering` constant so the view and the Restyler read the same number.

**Bookkeeping that must be re-derived with care** (the plan's risk points):
- The `|` pipes render as **space glyphs** (one space advance each, via the glyph substitution),
  sitting between cells in the layout. The old `gap` model absorbed those advances; the new
  band model must fold each pipe's rendered advance INTO its `2·cellPad` band (the rule stays
  centered on the band, the kern math pads the remainder). Same for the outer
  `hasLeadingPipe`/`hasTrailingPipe` x-shifts.
- **Every consumer of the widths updates together**: the fits/wrap/scroll decision
  (`laidOutWidth` must now be the PADDED span: content + all bands + `2·cellPad`), the
  `remainder`/`slot` math for the wrap edge, `Restyler.neededContainerWidth` (must include the
  `2·cellPad` card inflation so a horizontally-scrolling table's card isn't clipped), and the
  card/rule drawing.
- Trade-off to accept knowingly: padding adds ≈ `(colCount−1)·(2·cellPad − old gap·1.5) + 2·cellPad`
  ≈ +10pt per boundary, so a few previously-just-fitting tables will start wrapping/scrolling
  slightly earlier. Run the 236-table corpus sweep and report how many tables change mode —
  expected a handful; that is the intended cost of readable padding.

## Issue 2 — Code blocks (and thematic rules) stretch to the widened container

### Diagnosis (exact, from `Sources/Mallow/Views/MarkdownTextView.swift`)

v1.2.0 lets the text container grow wider than the viewport when a wide table needs horizontal
scroll. Two decorations still size themselves to the CONTAINER, so in any document that contains
one wide table they now stretch far past the window (the Lesson 08 code-diagram card):

- Code-block card, line ~174: `width: tc.size.width - 8`
- Thematic-break rule, line ~270: `width: tc.size.width - 8`

Their TEXT already wraps at the viewport (the prose `tailIndent` from v2), so only the drawn
decoration is wrong. Inline-code pills are per-fragment `boundingRect`-hugging — verified
unaffected. The TABLE card's container clamp is correct (tables own the scrolled region) — keep.

### Design — decorations clamp to the viewport, only tables extend

1. Add `viewportContainerWidth: CGFloat` to `MarkdownTextView` (sibling of the existing
   `tableContainerWidth`), set by the Restyler every pass (= the container width that fills the
   viewport; 0 when unknown → fall back to `tc.size.width`, i.e. today's behavior).
2. In `drawBackground`, compute `decoWidth = min(tc.size.width, viewportContainerWidth > 0 ?
   viewportContainerWidth : tc.size.width)` and use it for the code card and the thematic-break
   rule (`decoWidth − 8`). Everything else unchanged.
3. Resize behavior: the property refreshes with the debounced restyle (≤120ms lag during a live
   drag, same as table geometry — acceptable). Documents without a wide table are pixel-identical
   (container == viewport ⇒ `decoWidth == tc.size.width`).

## Out of scope (unchanged)
Vertical row padding (±6pt) and `lineSpacing 5`; inline-code pills; table-card container clamp;
code-block horizontal scrolling (still a possible later feature — if added, code cards would then
opt INTO the container width deliberately).

## Verification plan

Unit (extend the `testTableV2_` suite):
1. **Padding invariant** — style fit / wrap / h-scroll tables; for every interior rule x, the
   nearest glyph used-rect on BOTH sides is ≥ `cellPad − ε`; first/last glyph vs card edges
   (`leftX − cellPad`, `totalWidth + cellPad`) likewise. Measure per row via
   `enumerateLineFragments` + glyph locations.
2. **Decision stability** — the fits/wrap/scroll mode is computed from the PADDED width (no
   table that "fits" may paint its padded card past `availableWidth`).
3. **Code card clamp** — doc = wide table + code block at a narrow viewport → code decoration
   right edge ≤ viewport; doc without a wide table → byte-identical card rect to today.
4. **Thematic rule clamp** — same shape as 3.
Corpus: re-run the 236-table sweep (temp diagnostic) — no visual overflow of text past cards;
report the count of tables whose mode changed due to padding.
GUI: the exact Lesson 08 doc from the screenshots — cell text visibly padded off every rule and
border (incl. wrapped lines), the code diagram card ends at the window edge while the wide table
still h-scrolls; plus one live-resize pass.

## Release
v1.2.1 (visual fixes on the v2 policy). Standard pipeline after user approval of this plan.
