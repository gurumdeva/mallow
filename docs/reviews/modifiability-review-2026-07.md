# Modifiability Review — July 2026

**Scope:** all 40 Swift files under `Sources/Mallow` (~6.9k lines), reviewed per-file for *structure-for-change*, plus a dedicated cross-file contract map. **Trigger:** the owner's observation that fixing one feature repeatedly produces bugs in unrelated features. **Method:** 5 parallel reviewers (4 area reviews + 1 contract mapper), findings cross-checked against the codebase; every file:line cited was verified at review time. **This document contains no fixes — review only.**

Recent history that calibrates this review (all real regressions from the v1.2.x arc): the table kern model assumed hidden markers were zero-width while the renderer gave them full advances; headless tests rendered different glyphs than the app because the layout delegate lived on the SwiftUI Coordinator; rule positions drifted because a modeled `gap` diverged from real advances; the inline-code pill's two knobs live in two files.

---

## 1. Executive summary — why "fix here, break there" happens

Three structural root causes explain nearly every cross-feature regression:

**R1. One render model, three copies.** What a character *renders as* (hidden→zero-width, `|`→space, `-`→•, `[x]`→☑) is defined in `EditorLayoutDelegate`, *re-implemented for measurement* in `TableRendering.spanWidth`/`visibleWidth`, and *re-assumed for anchoring* in `MarkdownTextView.decorationAnchors`. Any change to one copy silently invalidates the other two. Every table/pill regression in the project's history is an instance of this.

**R2. Conventions instead of chokepoints.** The load-bearing rules are call-site conventions with no enforcement point: the IME freeze guard (12 call sites opt in; 3 in `DocumentActions` already forgot), the `revision &+= 1` chrome bus (15 sites / 7 files), the undoable-mutation seam, single-writer-per-file (4 consult sites), `applyFocus`-after-`restyle`. Each new feature must *remember* every convention; forgetting one ships a silent cross-feature bug.

**R3. Split knobs and duplicated formulas.** Single visuals/policies are split across files: pill = font (Restyler) + padding (MarkdownTextView); table rhythm = lineSpacing (TableRendering) + row pad (EditorLayoutDelegate); container width formula duplicated (Restyler ↔ MarkdownEditor resize observer); save routine duplicated (DocumentActions ↔ EditorBehaviors); "read file into document" ×3 with divergent guards; engine command strings ×3 files; marker grammar ×2 (+2 heuristic copies).

**Overall verdict:** the *pure cores* (HiddenSyntax compute, TableRendering math, CaretSnap, LaunchOpen.decide, validators) are well-factored and tested. The *connective tissue* — who calls what, in which order, under which guard — is where the codebase is fragile, and it is exactly where the regressions have occurred.

### File grades at a glance

| Grade | Files |
|---|---|
| **RED** (changes here regularly break elsewhere) | Restyler, MarkdownTextView, MallowApp, TaskList |
| **YELLOW** (safe only if you know the contracts) | HiddenSyntax, TableRendering, EditorLayoutDelegate, MarkdownEditor, EditorViewModel(+Folding), DocumentActions, EditorBehaviors, SmartTypography, PasteHandlers, AppLifecycle, WindowRegistry, LaunchOpen, OpenSpec, AppState, SessionRestore, Localization, Engine, PDFExporter, DocumentInfoPopover, StylePopover, DocAnalysis, RenameSheet |
| **GREEN** (changes stay local) | Theme, EditorDocument, CaretSnap, EditorViewModel+Commands, MallowCommands, ExternalReload, RecentFilesStore, ChromeBar, MallowControls, StatusBar, ParseModels, UpdateChecker |

### Live defects noticed during review (not fixed — review only)

1. **IME guard missing on the focus-mode selection path** — `EditorViewModel.swift:118`: `selectionChanged()`'s `if focusMode { restyle(); applyFocus() }` has no `hasMarkedText()` guard, and selection notifications fire per jamo during Korean composition → full-document `setAttributes` per keystroke with focus mode on (marked-text underline stripped, flicker) — the exact bug class the `textDidChange` guard was added for, alive through a side door. Also unguarded: `DocumentActions.toggleFocus`/`toggleFoldAll`/`setZoom` (menu-during-composition).
2. **Resize drops focus dimming** — `MarkdownEditor.swift:158`: the debounced reflow calls `vm.restyle()` alone; restyle's base pass wipes the focus dim and nothing re-applies it until the next caret move.
3. Smaller: restored files bypass the 50MB cap and lose BOM on next save (`SessionRestore.swift:176-178` reads without `OpenSpec.make`'s guards); `SessionRestore`'s `.explicit` branch is dead code; `TaskList.TaskBoxClickTarget` is dead code and its header describes a superseded design; 4 comments point at deleted files (InfoPanel, RenameInTitlebar, StylePopoverPanel, ImageInsert); `welcome.demo` in 3 locales still describes the reversed caret-reveal behavior.

---

## 2. Cross-file contract map (the fix-here-break-there axes)

Contracts ranked by regression risk. "Enforced by: nothing" = comment-only.

### C1. VM index-sets are UTF-16 indices into the CURRENT string — HIGH
Six sets (`hiddenChars`, `bulletMarks`, `taskBoxes`, `tablePipes`, `tableRowChars`, `foldedChars`; EditorViewModel.swift:18–23, sole writer `recomputeHidden` :157–178) are valid only for the exact string they were computed from. Consumers: EditorLayoutDelegate (glyph substitution + fragment geometry), CaretSnap, TableRendering (via Restyler), TaskList click gating, Folding caret parking. Sync relies on every mutation funnelling through the undoable seam → `textDidChange` → `refresh()`. Enforced by: content tests only; freshness/no-newline invariants unenforced. Regression: any direct-storage mutation leaves all six stale → wrong chars hide, caret mis-snaps, clicks toggle wrong chars.

### C2. Hidden glyphs have exactly ZERO advance — HIGH
Established by EditorLayoutDelegate (`.controlCharacter` :61–62 + `.zeroAdvancement` :91–99). Assumed by TableRendering's `visibleWidth`/`spanWidth` (measure with hidden chars *removed*), the pill's boundingRect hug + 3.5pt pad, `decorationAnchors`' skip/compensation logic, CaretSnap's shared-x premise. Enforced by `testHiddenMarkers_zeroWidthInLayout` — which only works because the delegate is installed in `EditorViewModel.init` (moving it back to the Coordinator silently reverts tests to a parallel universe). Regression: reverting to `.null` (or adding a substitution without the zero-advance action) reintroduces ghost widths while all set-content tests stay green.

### C3. `refresh()` ordering: parse → recomputeHidden → restyle → applyFocus — HIGH
`recomputeHidden` MUST precede `restyle` (table pass measures visible widths with `hiddenChars`; EditorViewModel.swift:87–96); `applyFocus` MUST be last (restyle's `setAttributes` wipes colors). Enforced by: comment only — no test has marked-up table cells, so a reorder ships green and mis-sizes any column containing `**bold**`/`` `code` ``/links.

### C4. IME frozen-offset convention — HIGH
While `hasMarkedText()`: no buffer/attribute mutation, no set application at/after `markedRange().location`. Guarded at ~12 sites (delegate glyph+fragment passes, textDidChange deferral, resize skip, all mutation helpers, autosave, typewriter, caret snap). **Gaps:** EditorViewModel.swift:118 (live bug above) + DocumentActions' three paths. No chokepoint: `refresh()`/`restyle()` trust every caller. Regression: any new restyle-from-notification/timer path without the guard = CJK flicker/corruption.

### C5. NSTextContainer width: three writers, one duplicated formula — HIGH
(1) makeNSView init (`widthTracksTextView=false` — the precondition), (2) Restyler per pass (:227, authoritative; also writes prose `tailIndent`s), (3) resize observer live-drag write (MarkdownEditor.swift:153). Writers 2 and 3 duplicate `clip − 2·inset` in different files; agreement is parallel maintenance. Headless tests exercise only the fallback path; the live-drag writer is untested. Regression: change one formula → container oscillates during drags; tables' cards detach per frame; tests green.

### C6. `tableContainerWidth` / `viewportContainerWidth` staleness — MED
Written per restyle (Restyler.swift:228–229), read as a floor during drags and as the decoration clamp. Stale by design for the 0.12s debounce window; stale longer if the debounced restyle is skipped mid-IME. Any reader treating them as always-current draws wrong.

### C7. The table column model spans three files — HIGH
Six sub-invariants must hold simultaneously: interiorEdges' origin = first glyph x (probed in drawBackground); `|` advances as exactly one space (delegate substitution ↔ `spanWidth` measuring `|` as `" "`); the `|---|` row is zero-height (scanner incl. newline → delegate collapse → drawBackground/anchors skip); TWO independent derivations of "row start" (engine cells → `rowStartChars` rules; pipe scanner → `tableRowChars` height pad) must coincide; kern padding and rule placement share `colSlot`/`slotPad=6`; vertical rhythm = delegate pad 6 + lineSpacing 5 + no lineHeightMultiple (three files, one design). Best-tested contract in the app (`testTableV2_*`), but marked-up cells and indented tables are untested.

### C8. `.kern` is transient per-restyle state — MED
Measurement is only correct because Restyler's base pass uses full-range `setAttributes` (REPLACES attributes; Restyler.swift:112–114), wiping last pass's kern before this pass measures. Regression: an "optimize: don't wipe what we re-add" refactor to `addAttribute` → stale kern compounds per keystroke inside tables. No restyle-idempotence test exists.

### C9. Zero-height keying discipline — MED
`shouldSetLineFragmentRect` keys on the fragment's FIRST char; an all-hidden line can report its start past the hidden glyphs, so zero-height producers must insert EVERY char incl. the newline (fences/delimiter/folds honor this). `tableRowChars` stores line-starts only — safe only while a row's first char stays visible. A fold-like feature keyed line-start-only reproduces the historical fence bug.

### C10. `vm.blocks` (cached parse) ↔ live string — MED
Folding builds a fresh byte→UTF-16 map against cached blocks — the first thing to break if blocks are stale (mid-IME it has no guard). DocumentInfoPopover instead re-parses per render (never stale, but a full FFI parse + JSON decode per keystroke while open).

### C11. Zoom scales SOME sizes — MED
Scales: body/headings/code-block/inline-code fonts. Fixed (by design or accident): table font 15 + all table metrics, row pad 6, quote/code indents, pill paddings, container insets 88/76, caret fallback. No zoom test; no written list — this map is currently the only one. "Fixing table zoom" without touching `availableWidth` math and the row pad breaks wrap decisions at zoom≠1.

### C12. The undoable-mutation seam bundle — MED (highest blast radius)
`replaceCharactersUndoably`/`insertTextUndoably` (MarkdownTextView.swift:362–381) transitively guarantee: undo, fold invalidation, `refresh()`, `revision` bump, autosave scheduling. Verified: no raw `.string =` outside `EditorDocument.init`. But `revision` bumps are 15 manual sites across 7 files, and two refresh conventions coexist (delegate-driven in PasteHandlers vs explicit in Commands/TaskList/ExternalReload → in-app double full parses; headless, the delegate path never runs and Commands skips `clearSectionFolds`). Regression: one direct-storage mutation = four symptoms in four features.

### C13. Engine boundary: three integer domains + serde tag strings — MED
Bytes (parse ranges) vs Unicode scalars (commands) vs UTF-16 (NSTextView), all typed `Int`; the O(n) PRange conversion overloads remain public beside the O(1) map overloads (zero callers today; reintroducing the historical O(n²) is one wrong autocomplete away). Block/inline/mark tags matched as raw strings at ~10 sites; unknown tags silently decode to "Other" → an inkstone enum rename blanks features with no error. Engine command strings duplicated ×3 files (StylePopover, MallowCommands, Commands validation).

### C14. TaskBoxScanner duplicates MarkerGrammar's walk — MED
Two marker-prefix walks must accept identical lines or ☐ substitution and click-toggle drift apart. The stated justification ("MarkerGrammar is private") is now false — it's internal in HiddenSyntax.swift:33.

### C15. Save/baseline triangle — MED
`baseline`/`isDirty`/`markSaved` feed the dirty dot, autosave gates, quit/close prompts, and external-reload decisions. BOM re-prepend and the other-window guard are duplicated across the two save implementations (DocumentActions.write ↔ EditorBehaviors.performAutosave). A save-like feature that forgets `markSaved` destabilizes all four consumers.

### C16. Window lifecycle: logic/state/clock/invariants in 6 files — HIGH (app layer)
The state machine's *executor* is MallowApp's view closures (:66–113), *state* in LaunchOpen statics, *clock* (1.0s) in AppLifecycle:97, plus an unrelated 1.0s claim-dedup global in MallowApp:122–128, the `didApplyRestoredFrame` latch, and registration in `.onAppear`. Single-writer-per-file is enforced at 4 call sites, not in the registry (`register` dedups by object identity only). `planStartup` mutates `welcomed` inside speculative view evaluation (idempotency contract violated today — first-run welcome is evaluation-order-dependent). ~10 timing dependencies, most failing as silent no-ops. Known launch-frame quirk: at launch-with-file, the doomed initial window consumes the saved frame, then closes.

### C17. Duplicated visual constants — LOW/MED
Body 16pt ×3 spots; inset 12 (Theme style read by card padding — good — vs TableRendering's independent 12); ChromeBar 52 shared with scroller inset but NOT with the 76 top inset that exists because of it; two unrelated 6s (row pad vs slotPad) that a "unify the 6s" cleanup would wrongly merge; body color defined twice (Restyler labelColor vs Theme mallowText).

### C18. Focus dim erased by any bare `restyle()` — LOW/MED
`applyFocus` must follow every restyle while focus mode is on. Violator exists today (resize reflow — live defect #2).

---

## 3. Per-file review

Grades: GREEN = changes stay local · YELLOW = safe only if you know the listed contracts · RED = changes here regularly break elsewhere. Only load-bearing findings are listed; see §2 for shared contracts.

### 3.1 Rendering core

**ViewModels/Restyler.swift — RED.** The attribute pass + decoration-range producer + the entire viewport/h-scroll width policy in one type, exported as 7 property writes to the view. Assumes recomputeHidden ran (C3), the font cache is zoom-invalidated externally (EditorViewModel.swift:29), `widthTracksTextView == false` (set elsewhere), and `TableGrid.totalWidth`'s origin convention. Amplification: width-formula changes must be mirrored in MarkdownEditor.scheduleReflow; inline-code size pairs with the pill pads; base size/color pairs with configureTextView's first-paint defaults. Body color is `labelColor` here vs `mallowText` in the view — two truths. Fence detector duplicated with HiddenSyntax (neither knows `~~~`). *Top refactor: extract a `ViewportGeometry` (single owner of the width formula pair, used by both writers) and hand the view one `Decorations` struct instead of 7 properties.*

**ViewModels/HiddenSyntax.swift — YELLOW.** Pure and well-tested; its exports carry set-specific keying semantics stated only in comments (C9): `foldedChars` = every char incl. newline; `tableRowChars` = line starts; ordering of the show-orphan pass is load-bearing despite a comment claiming order-irrelevance. `hideable` block list lives in another file. *Top refactor: named set types (or asserts + tests) for the keying semantics; unify the fence detector with Restyler's.*

**Features/TableRendering.swift — YELLOW.** The math core is clean; its risk is re-implementing the render model (C2/C7): `spanWidth`/`visibleWidth` model exactly {hidden→0, `|`→space} and nothing else — a task box or bullet inside a cell mis-kerns (unmodeled substitution advances). Assumes kern-free storage on entry (true only post-wipe, C8). Bold/italic re-assertion in `measure` is a partial copy of `font(for:)` — links/strikethrough/inline-code render unstyled in cells. Vertical rhythm split with the delegate (pad 6 there, lineSpacing 5 here). Tables ignore zoom by admitted necessity (:348–350). *Top refactor: extract a shared `RenderModel` used by both the delegate (render) and this file (measure); take fontSize/rowPad as parameters so zoom policy and rhythm live with the caller.*

**Editor/EditorLayoutDelegate.swift — YELLOW.** Small and single-purpose (good); its property choices (`.controlCharacter` for hidden, `.null` for the task fallback) are re-hardcoded by decorationAnchors, and its substitution table is re-modeled by TableRendering (C2). Row pad 6 (:130) is half of the table rhythm. *Top refactor: publish named constants (`hiddenGlyphProperty`, substitution table) that consumers reference; move the row pad next to TableRendering's metrics.*

**Views/MarkdownTextView.swift — RED.** A grab-bag: input overrides (smart typography, double-space defeat), custom caret, ALL five decoration painters, `decorationAnchors`, shared view config, and the undoable-mutation seam. drawBackground trusts decoration ranges to be current-string-valid (safe only because restyle is synchronous with every change); pill geometry depends on zero-width backticks (comment-only, C2); decoration rects are computable only by drawing, so tests must re-derive them (the "parallel universe" risk shape). 16pt appears three times; the −8 pairs with Restyler's +8. *Top refactor: extract a `DecorationRenderer` with pure rect-returning geometry + a thin fill shell; co-locate the pill knobs (`InlineCodeStyle`) with Restyler's font size.*

**Views/Theme.swift — GREEN.** Single-source tokens; two documented-here couplings (code style's headIndent doubles as card padding — good single-knob; lineHeightMultiple 1.5 is why the caret/anchor workarounds exist). Body-color rivalry with Restyler's labelColor is the one wart.

### 3.2 Editor shell / input

**Editor/MarkdownEditor.swift — YELLOW.** The Coordinator carries ~6 roles (delegate, IME-deferral state machine, viewport observer + container writer, task-click target, clipboard suite via extension, behaviors forwarder). Owns the "clearSectionFolds BEFORE refresh" rule — at the delegate, not the mutation seam, so headless mutations skip it. `scheduleReflow` drops the debounced restyle mid-IME and relies on a *different* mechanism to recover. Duplicates the viewport formula (C5) and calls bare `restyle()` (live defect #2). *Top refactor: move reflow into a `ViewportReflow` object; move fold-clearing into the VM's edit path.*

**Editor/EditorDocument.swift — GREEN.** Clean seam; `revision` convention (15 bump sites) is its one export risk. *Refactor: a `markEdited()` that mutation helpers call.*

**Editor/DocumentActions.swift — YELLOW.** Three toggles own three different recompute recipes (restyle+applyFocus / refresh+park+selectionChanged / refresh), all IME-unguarded (live defect #1's siblings). `write(to:)` duplicates the autosave save routine (BOM, other-window guard, atomic write, markSaved, bump). *Top refactor: one shared `persist()`; move toggle recipes into VM methods that carry their own ordering + guard.*

**Features/EditorBehaviors.swift — YELLOW.** Autosave correctness depends on delegate forwarding + the close-path's `cancelPendingAutosave` contract (reached via a 3-hop downcast from AppLifecycle). Save routine duplicated (above). Overscroll predicate re-stated from the clip view.

**Features/SmartTypography.swift — YELLOW.** The rule table is pure (good), but the back-consumption contract is split (glyph identity → chars-to-consume mapping lives in MarkdownTextView.insertText); `isInsideCode`/`isInsideFrontmatter` are a third grammar (no `~~~`, no indented code, no CRLF frontmatter) drifting from the engine's parse the VM already has. *Top refactor: return `(replacement, consumedBefore)`; take a suppression predicate from the caller.*

**Features/PasteHandlers.swift — YELLOW.** Pure helpers well-factored; relies on the delegate-driven refresh convention (opposite of Commands/TaskList — C12); caret+revision boilerplate repeated per insertion site; sidecar-vs-data-URI policy buried in a private func. *Top refactor: one `insertMarkdown(_:replacing:)` on the Coordinator used by all paths.*

**Features/TaskList.swift — RED.** Duplicates MarkerGrammar's walk under a now-false "it's private" justification (C14); `innerFor` encodes rendering knowledge coupled to the delegate's hiding; explicit `refresh()` after an already-refreshing undoable replace (double parse, hedged in comments); `TaskBoxClickTarget` is dead code; the 31-line header describes a superseded design. *Top refactor: delete dead code, rewrite header, collapse the scanner onto MarkerGrammar.*

**ViewModels/CaretSnap.swift — GREEN.** The model extraction: pure, one caller, tested. 

**ViewModels/EditorViewModel.swift — YELLOW.** The pipeline brain: ordering contract inside `refresh()` (C3) with both halves internal-callable in the wrong order; no self-guarding against IME (C4 — trusts 12 call sites); the "restyle alone iff text+folds unchanged" precondition unstated; double full-document invalidation per keystroke (acknowledged in comments); UI flags (`keepOnTop`, `typewriterOn`) parked on the pipeline object. *Top refactor: put the IME guard inside `refresh()`/`restyle()`; make `recomputeHidden` private.*

**ViewModels/EditorViewModel+Commands.swift — GREEN (borderline).** Correct domains and guards; whole-buffer replace per command is the scalability seam; `wrappingCommands` strings must mirror engine names; headless path skips fold-clearing.

**ViewModels/EditorViewModel+Folding.swift — YELLOW.** Fold keys are edit-fragile UTF-16 offsets whose clear-on-edit contract is enforced two files away; `parkCaretOutOfFold` guards `allSectionsFolded` only (a third fold producer would strand the caret); the enclosing-heading loop (incl. full map build) duplicated verbatim ×2. *Top refactor: extract `enclosingHeadingStart(at:)`; self-enforce fold clearing in the VM's edit path.*

### 3.3 App lifecycle / windows

**App/MallowApp.swift — RED.** `EditorWindow`'s closures are the de-facto executor of the launch/open/dedup/supersede machine: 4 ordered side effects in `.onAppear` whose idempotency requirements are stated nowhere; `.openAndSupersede` skips the registry check its sibling branch performs; open-event delivery requires ≥1 mounted window (undelivered opens are silently dropped); `claimFileOpen` is global mutable state with its own coincidental 1.0s. `.openNewWindow` duplicates `MallowCommands.openOrFocus` verbatim. *Top refactor: extract a `WindowLifecycleController` (plain, testable, takes `openWindow` as a closure); fold `claimFileOpen` into LaunchOpen; share one `openOrFocus`.*

**App/AppLifecycle.swift — YELLOW.** Two unrelated machines in one file (app delegate + per-window configurator). Owns LaunchOpen's 1.0s clock; `didApplyRestoredFrame` first-attach-wins latch collides with supersede (saved frame consumed by the doomed window); deferred `view.window` grabs fail as silent no-ops (idiom ×3 across files); close-confirm reaches the autosave timer via a 3-hop downcast. *Top refactor: split WindowConfigurator out; one shared `WindowDiscoverer`; move the 1.0s into LaunchOpen.*

**App/WindowRegistry.swift — YELLOW.** The single-writer invariant is advisory: `register` dedups by object identity, not canonical path — enforcement lives in 4 call-site conventions + a reactive heal; an unregistered dirty window is invisible to the ⌘Q guard (silent data loss) and to dedup. `canonicalPath` does filesystem I/O (so "pure" LaunchOpen.decide is disk-dependent). *Top refactor: make `register` detect canonical-path collisions (assert/verdict); injectable instance for tests.*

**App/LaunchOpen.swift — YELLOW.** The pure `decide` is tested; the statics around it (isLaunching flipped by another file's timer, `closePendingIfReady` called only from another file's `.onAppear`, first-tag-wins depending on SwiftUI @State stability) are the mines. Registry-consultation asymmetry within one `.onAppear` is deliberate and trap-shaped. *Top refactor: centralize launch policy (clock + claim dedup) here; write the lifecycle overview doc this file's header is halfway to being.*

**App/OpenSpec.swift — YELLOW.** `make(for:)` runs inside speculative view init but is not idempotent: `.none` flips `welcomed` (first-run welcome becomes evaluation-order-dependent) and `.file` side-effects RecentFiles per evaluation. OpenSpec's SwiftUI identity is the raw path string while app identity is canonicalPath. The only guarded file reader (50MB/BOM/encoding/recents) — the other two readers bypass it. *Top refactor: pure `planStartup` returning a path; route ALL content reads through this one reader; move the `welcomed` flip to launch.*

**App/AppState.swift — YELLOW.** `activeDoc` singleton + become-key tracker — which also hard-codes ExternalReload's trigger (feature activation hidden in a state file); the "only claim if key" guard is regression bait; activeDoc lifecycle spans 3 files. *Top refactor: post a became-active event; let ExternalReload subscribe itself.*

**Services/SessionRestore.swift — YELLOW.** `planStartup` is impure (state mutation + flush scheduling) and reached from speculative inits; state loaded from real Application Support with no injection seam (untestable); `.explicit` branch is dead; single-frame schema hard-codes one-window restore across 3 files; its file reader bypasses the guards (BOM/50MB). *Top refactor: pure plan + shared reader + injectable store.*

**Features/ExternalReload.swift — GREEN.** Pure decision + correct IME guard + undoable reload; trigger location (AppState) is its one discoverability wart; reader lacks BOM refresh.

**App/MallowCommands.swift — GREEN.** Thin, additive; stale-target guard is the one contract; Document Info uses a second routing style; `openOrFocus` duplicated with MallowApp.

**Services/RecentFilesStore.swift — GREEN.** Dedup by raw string (canonicalPath would fix duplicate menu entries); `mallowSupportFile` placement surprise.

### 3.4 Services / chrome / analysis

**Services/Localization.swift — YELLOW.** Three hand-synced dictionaries with silent English fallback and no parity test; stringly-typed `{placeholder}`s; 3 stale file references; `welcome.demo` (×3 locales) asserts reversed product behavior. *Top refactor: a key-parity unit test; fix the stale strings.*

**Services/Engine.swift — YELLOW.** Ownership correctly centralized (`inkTake`); the risk is three integer indexings all typed `Int` (byte/scalar/UTF-16 — CJK-only corruption on a mis-wired call) and the still-public O(n) conversion overloads beside the O(1) map ones (the healed O(n²) wound, unfenced). *Top refactor: deprecate/rename the slow overloads; consider one-field wrapper types at the FFI signatures.*

**Services/PDFExporter.swift — YELLOW.** Fire-and-forget with UI presented from the service layer (app-modal NSAlert, unlike the anchored-sheet convention); self-retain lifecycle rule is one new delegate method away from a silent leak. *Top refactor: completion handler; alerts presented by the caller.*

**Views/DocumentInfoPopover.swift — YELLOW.** Re-parses the whole document per render while open (the VM's cached parse is available and fresh-by-revision); jumps the caret by direct 4-call AppKit reach-in; header points to a deleted file. *Top refactor: read `vm.blocks`; a single `doc.jump(toUTF16:)`.*

**Views/StylePopover.swift — YELLOW.** Engine command vocabulary as raw strings, duplicated with MallowCommands and the VM validation list — a rename is a 3-file hunt with silent-no-op misses. *Top refactor: one `enum EngineCommand: String` used by all three.*

**Views/ChromeBar.swift / MallowControls.swift / StatusBar.swift — GREEN.** The chrome done right: derived-state-only reads through `revision`, one shared button style. StatusBar's caveats: 4 regex passes per keystroke in an always-visible view (fine today, the first place a big-doc perf pass will touch) and callers, not `DocStats`, enforce frontmatter exclusion.

**Analysis/DocAnalysis.swift — YELLOW.** `DocStats` re-implements markdown grammar as regexes parallel to the engine (setext headings count as prose; indented code not excluded) — the second grammar can drift; outline extraction is a good map citizen. *Top refactor: derive stats from `vm.blocks` with the regex path as fallback.*

**Models/ParseModels.swift — GREEN.** One decode mirror; silent degradation to "Other"/`[]` by design — needs the schema-canary test (below); kindTag literals compared at ~10 sites.

**Features/RenameSheet.swift — YELLOW.** View + validation + disk IO + cross-object mutation in one file; the `setPath`-not-`markSaved` subtlety and the revision/RecentFiles side-channel duo are contracts any second rename path must replicate; `.md` handling spelled twice. *Top refactor: move commit's model half to a `DocumentActions.rename(to:)`.*

**Features/UpdateChecker.swift — GREEN.** Self-contained, documented asymmetries, pure tested compare.

---

## 4. Missing enforcement — the tests/asserts that would pin the contracts

1. **Marked-cell table test** — a table with `**bold**`/`` `code` ``/link cells asserting column symmetry; pins C2-for-tables AND the C3 ordering (both comment-only today).
2. **IME chokepoint** — guard inside `refresh()`/`restyle()` themselves (turns the 12-site convention into one line) — also fixes live defect #1.
3. **Restyle idempotence test** — restyle twice, assert identical TableGrid geometry (pins the `setAttributes` wipe, C8).
4. **Debug asserts in `recomputeHidden`** — no newline in `hiddenChars`; collapse-lines fully covered incl. newline (C1/C9 keying).
5. **One `viewportContainerWidth(for:)` helper** used by both width writers + a resize test that drives `scheduleReflow` (C5).
6. **Zoom partition test** — heading 28·z, inline code 14.4·z, table 15 fixed — makes C11's implicit design executable.
7. **Serde tag fixture test** — parse a kitchen-sink document; assert exact kindTag/mark strings (C13 cross-repo canary).
8. **Resize-under-focus** — `restyle(); applyFocus()` in the reflow (live defect #2) + a headless attribute check.
9. **Marker-walk equivalence test** — TaskBoxScanner finds a box iff MarkerGrammar.skipTaskBox advances (C14).
10. **Locale key-parity test** — `Set(en.keys) == Set(ko.keys) == Set(ja.keys)`.
11. **Registry collision detection** — `register` flags a second doc on one canonical path (C16).
12. **Row-without-leading-pipe pad case** — documents or fixes C9's `tableRowChars` edge.

## 5. Prioritized refactoring roadmap (proposal only — nothing applied)

**P0 — the two live defects + zero-risk hygiene** (small, immediate): IME guard chokepoint in `refresh()`/`restyle()` (fixes defect #1 and closes C4 permanently); `applyFocus` after the reflow restyle (defect #2); delete dead code (TaskBoxClickTarget, SessionRestore `.explicit`); fix the 4 stale file references + `welcome.demo` text; deprecate the slow PRange overloads.

**P1 — kill the three-copy render model + single-owner width** (the direct fix for the regression pattern): shared `RenderModel` (delegate renders it, TableRendering measures it, decorationAnchors references its property constants); `ViewportGeometry` owning the width formula for both writers; co-locate split knobs (pill style, table rhythm, body 16pt/color). Add tests 1/3/5/6 alongside.

**P2 — convention → chokepoint**: `EngineCommand` enum (3 files → 1); `markEdited()` collapsing the revision convention; one `persist()` for save+autosave; one guarded file reader for open/restore/reload; registry collision detection; TaskBoxScanner onto MarkerGrammar; stats from `vm.blocks`.

**P3 — structural extractions** (larger, schedule deliberately): `DecorationRenderer` out of MarkdownTextView; `WindowLifecycleController` out of MallowApp's closures; VM-owned toggle recipes; popover reading the cached parse.

The P1+P2 set directly addresses the owner's complaint: after it, the render model has one definition, the width formula one owner, and the five riskiest conventions have compiler- or test-enforced chokepoints.
