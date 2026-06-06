# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/).

Categories: **Added** (new features) · **Changed** (changes to existing behavior) · **Fixed** (bug fixes).

## [Unreleased]

### Fixed
- **Blank lines no longer show stray "ghost" marks.** After typing a line, pressing Enter twice, then moving the cursor up through the empty lines, faint vertical marks (left-over cursor pixels) could linger on the blank lines — they looked like stray commas or apostrophes even though no such characters exist in the document. The custom insertion-point caret was being drawn just outside the line region the system repaints when the cursor moves, so the old caret was never erased. The caret is now always clamped inside that region, so a moved cursor never leaves a ghost behind.
- **Korean / CJK input no longer flickers while composing.** Each in-progress jamo (or kana) used to trigger a full-document restyle that wiped the system's composing-clause underline and re-hid every syntax marker mid-composition, so the composition indicator and nearby markers could flicker and large documents could stutter. The editor now leaves a live composition untouched and applies styling once the text is committed — matching how every other edit path already treated in-progress input.
- **Raw HTML in your text no longer disappears.** Raw HTML — inline tags like `<br>`, `<span>…</span>`, `<sub>`, `<kbd>`, and also an HTML block nested inside a list or quote (a `<div>…</div>`) — was being silently zero-width-hidden in the editor, so `line<br>wrap` displayed as `linewrap`, `H<sub>2</sub>O` as `H2O`, and a nested `<div>` line vanished entirely. The text was always safe on disk (the file kept the exact bytes); it only vanished on screen, because the editor hides syntax by the complement of what the parser marks as content and the engine had no rule for raw HTML. The engine now treats raw HTML as content, so the literal markup shows — consistent with how the editor already shows entities like `&amp;` verbatim (markdown-as-truth). A new property test pins the underlying guarantee that no on-screen content can be dropped this way.

### Changed
- Internal hardening (no visible change): the insertion-point caret is clamped underflow-safe against future line-height settings, and a layout reflow of hidden/collapsed syntax now always requests the matching decoration repaint, so block decorations (code cards, quote bars, inline-code pills, rules, table grids) can never lag behind an edit.

## [1.0.3] - 2026-06-06

### Changed
- **Pasted or dropped images are now saved as files, not embedded inline.** When you paste or drop an image into a *saved* document, Mallow writes it to a sidecar folder next to the file — `<docname>.assets/image-1.png`, `image-2.png`, … — and inserts a short relative reference instead of a multi-megabyte `data:` base64 string that bloated both the `.md` file and the editor view. Your images stay on disk as ordinary files, and the document text stays readable. An untitled document (no folder to save beside) still falls back to an inline data-URI.

_Internally, this release also adds the project's first app-level unit-test suite (`swift test`) — locking the data-safety, encoding, filename, URL, and image-asset logic in against regression._

## [1.0.2] - 2026-06-05

A correctness + safety release — every fix below was found and verified through a continuous review pass over the editor, engine, and export paths. Signed with a Developer ID and notarized by Apple.

### Fixed
- **Opening a file that isn't valid UTF-8 can no longer destroy it** (data-safety). A UTF-16 / Latin-1 / binary file (or one that can't be read) now opens as an *untitled* buffer instead of a blank document still bound to the file — so the 1.5-second autosave can no longer overwrite the original with an empty buffer.
- **Exported HTML/PDF no longer executes scripts embedded in a document** (security). Link/image URLs using `javascript:`, `vbscript:`, or `data:text/html` are neutralized on export, and the PDF renderer runs with JavaScript disabled — so exporting a Markdown file you received from someone else can't run embedded code. (Image `data:image/…` URLs are preserved.)
- **No more crash when running a command mid-composition in Korean/Japanese.** Bold/heading/list commands, the task-checkbox toggle, and the on-focus file reload no longer rewrite the buffer while an IME syllable is still being composed (which could raise an exception or mangle the input).
- **A UTF-8 BOM is preserved** across an open → save round-trip (files from Windows / PowerShell keep their byte-order mark instead of silently losing it).
- **Fold All no longer hides the cursor.** Collapsing every section with the caret inside a body now parks it on the enclosing heading instead of stranding it on an invisible zero-height line.
- **Typing a quote over selected text now replaces the selection** (it used to leave the text in place and merely prepend the quote).
- **Pasting an image over a selection now replaces it** (it used to leave the selected text behind).
- **A paragraph placed directly under a table** (no blank line) is no longer pulled into the table grid — it renders as ordinary body text below the table.
- **Multi-window:** a background or restored window can no longer steal the menu-command target from the front window.
- **Inline `code` that wraps to the next line** now draws a pill on each visual line instead of one tall box bleeding across the lines between.
- **PDF export** now surfaces a save error instead of silently failing, and no longer leaks resources when a render fails.

## [1.0.1] - 2026-06-05

### Fixed
- **Table columns now line up correctly with Korean/CJK text.** A table's column widths are now derived from the engine's actual cell boundaries and measured from the rendered glyphs, so the vertical rules stay straight even when cells mix Hangul, symbols, and Latin — the 1.0.0 grid padded by a monospace approximation that drifted on CJK (the column rules looked ragged). The table also honors each column's left / center / right alignment, and its card now hugs the table's width instead of spanning the page. Still display-only; your source bytes are untouched.
- **Multi-window polish.** Each window's title now shows its own document's name — live — in the Window menu, Mission Control, and ⌘\` cycling (windows used to all read "Mallow" until the file was saved). The app reopens at its last size and position; quitting no longer drops the final window state if you quit right after a change; closing a window no longer leaves menu commands pointing at it (or holding it in memory); and a background autosave won't overwrite a file another window is editing.

## [1.0.0] - 2026-06-05

First stable release — **signed with a Developer ID and notarized by Apple**, so it installs with a normal double-click (no more right-click → Open or `xattr` workaround).

### Changed
- **Tables now render as a grid.** A GFM table draws as a ruled card — an outer border, a rule under the header and between each row, and a vertical rule between columns. The columns are aligned (each cell is padded to its column's width) so the rules stay straight even with Korean/CJK text, the cells have even padding on all sides (the rows are no longer cramped against the rules), and the `|---|` delimiter row no longer leaves a blank gap. The alignment is display-only; the source bytes are untouched.

## [0.30.2] - 2026-06-04

### Fixed
- **Code blocks and quote bars now hug their text vertically, with even padding.** The rounded background behind a fenced code block left an empty gap above the first line of code, and the bar beside a block quote ran taller than the quoted text — both because the airy line spacing adds its extra leading *above* each line. The decorations are now measured from the text's real top (the letter cap line) and bottom (the baseline); the code card's top/bottom padding matches its left/right inset, so the breathing room is even on all four sides.
- **A code block placed right under a paragraph no longer pulls its background over that line.** With no blank line between a paragraph and the code block beneath it, the card was drawn up over the paragraph's last line (and could show an empty row where the hidden ``` ``` ``` fence sat). The card now spans only the code's own lines.
- **Inline `code` now sits in a snug pill.** The little background behind inline code filled the whole airy line height, leaving a tall gap above the text; it's now a rounded pill that hugs the code (cap line to baseline), drawn directly rather than via a text background attribute.

## [0.30.1] - 2026-06-04

### Fixed
- **Code blocks no longer have an empty band inside their background.** A fenced code block's rounded background card stretched over the (hidden) ``` ``` ``` opening and closing fence lines, leaving an empty grey strip above the first line of code and below the last. The fence lines now collapse to zero height, so the card hugs the code exactly.

## [0.30.0] - 2026-06-02

### Added
- **Document title from the first heading (Notion-style).** A document's first heading (`# …`) is now its title: it shows in the window/chrome title bar, and saving a new document offers that heading as the default filename (e.g. type `# Meeting notes` → Save suggests `Meeting notes.md`). Falls back to the filename when there's no heading. No extra syntax — just write a heading at the top.
- **Scroll past the end.** The last lines of a long note are no longer pinned to the window's bottom edge — you can scroll them up toward the middle (and typewriter mode can now centre the final lines), the way iA Writer and Typora do. Always on; notes that fit the window are unaffected.
- **Fold all sections (outline view).** **View ▸ Fold All Sections** (⌃⌘O) collapses the body under every heading, so a long note reads as an outline of just its headings — handy for getting an overview or jumping around; toggle again to expand. Headings keep their styling, and your text is never modified (the bodies are only hidden).
- **Fold a single section.** **View ▸ Fold Section** (⌥⌘.) collapses just the section the caret is in (its heading's body); invoke again to expand. Complements Fold All. (Per-section folds reset when you edit the text.)

### Fixed
- **The text cursor now sits on the line, not above it.** With the airy line spacing, the blinking caret was drawn centred in the (tall) line box, so it floated noticeably above the actual characters; it's now pinned to the text baseline and lines up with the glyphs on body and heading lines alike.
- Hardened the editor engine across many formatting edge cases: bold/italic/strikethrough/inline-code no longer leak literal markers or change a line's block structure; list-type switches (bullet ↔ ordered ↔ task, including nested/indented items) replace the marker cleanly instead of stacking; inserting a link escapes special characters in the selected text and never breaks block structure; and deeply-nested or pathological math no longer crashes export.
- **Frontmatter no longer leaks into the title, outline, or word count.** When a note opens with a `---` … `---` metadata block, its keys are no longer mistaken for the document's title (the closing `---` had made them look like a heading), no longer appear as an outline / table-of-contents entry, and are kept out of the word / character / paragraph counts again — matching how HTML/PDF export already drops them. What counts as frontmatter is now decided in one place in the engine, so the title, outline, statistics, and export always agree.
- **Fixed severe typing lag in larger documents.** Editing a longer note (e.g. a few hundred lines with code blocks and tables) had become very choppy — each keystroke re-styled the whole document, and a byte→offset conversion buried in that pass was quadratic in the document size. Re-styling now converts offsets through a one-pass lookup table, so a keystroke that previously took ~115 ms of work now takes ~10 ms (measured on a ~10 KB note); typing stays smooth as documents grow.
- **Fixed slow opening of large, table-heavy documents.** The same quadratic byte→offset conversion lingered in the table renderer and the outline builder, so a long note with many tables could take most of a second to open and re-render. Both now use the one-pass lookup, so a 73 KB document with 120 tables opens in ~15 ms instead of ~720 ms (~50× faster), and the outline (⌘⇧I) opens instantly.

## [0.29.0] - 2026-05-31

### Changed
- **Mallow is now a fully native macOS app.** The editor has been rebuilt from the ground up — replacing the previous embedded web-view build with a fully native one. Text editing now uses the macOS system text engine directly, so Korean/Japanese IME composition, the caret, and selection behave exactly like any native app, and the download is a fraction of the size. The writing experience carries over: live-preview styling, the Format menu, focus mode, multi-window, find, autosave, session restore, statistics/TOC, and HTML/PDF export.

### Note
- Apple Silicon (arm64) build, and not code-signed yet. On first launch, right-click the app in Finder → **Open** (or run `xattr -dr com.apple.quarantine /Applications/Mallow.app`).

## [0.28.0] - 2026-05-30

### Added
- **YAML frontmatter is now preserved.** Notes that begin with a `---` … `---` metadata block (the convention used by Obsidian, Hugo, and Jekyll) previously had that block reinterpreted and rewritten whenever Mallow autosaved — quietly corrupting it. Mallow now keeps the frontmatter exactly as written: it is set aside when the file opens and restored verbatim on every save, so your metadata round-trips byte-for-byte and stays out of the word count and exports.

## [0.27.0] - 2026-05-30

### Fixed
- **Prevented a rare cross-window save conflict.** If you used Save As — or saved an untitled document — onto a file that was already open in another Mallow window, both windows could autosave to it and silently overwrite each other's edits. Mallow now detects this and declines, asking you to pick a different name.

### Changed
- **Document saves are now atomic.** Each save writes to a temporary file and then atomically replaces the original, so a crash, force-quit, or power loss in the middle of a save can no longer leave a half-written or truncated file — your previously saved content is never put at risk. Symbolic links are followed, so a symlinked note still updates its real target.

## [0.26.0] - 2026-05-30

### Added
- **Keep on Top** (View → Keep on Top): pins the current window above other apps, so you can keep a note or reference visible while working elsewhere — like a floating scratchpad. It's per-window and resets each launch; nothing to configure.

## [0.25.0] - 2026-05-30

### Added
- **Paste a link onto selected text**: select some text, paste a URL, and Mallow wraps the selection in a link — e.g. select "docs" and paste `https://example.com` to get `[docs](https://example.com)`. Only `http`/`https` URLs trigger this; pasting with no selection still inserts the URL as before.

## [0.24.0] - 2026-05-30

### Added
- **Paste and Match Style** (Edit → Paste and Match Style, ⇧⌘V): pastes the clipboard's text as plain text at the cursor — no markdown parsing, no source formatting. It's the escape hatch for when a normal paste would turn your clipboard into formatted blocks. Localized (Korean / English / Japanese).

## [0.23.0] - 2026-05-30

### Added
- **Text zoom**: press ⌘+ / ⌘− to make the editor text bigger or smaller (uses WebKit page zoom, so the caret stays accurate). It's per-window and resets to 100% each launch — true to the no-settings design, there's nothing to configure.

## [0.22.0] - 2026-05-30

### Added
- **Copy as Rich Text** (Edit → Copy as Rich Text, ⌥⌘C): copies the whole document to the clipboard as formatted rich text, so pasting into Slack, email, Google Docs, or Notion keeps your headings, bold/italic, lists, tables, and code — instead of pasting raw markdown. Apps that accept only plain text receive the clean markdown source. Localized (Korean / English / Japanese).

## [0.21.0] - 2026-05-29

### Changed
- **Math now renders as real math in HTML export.** Exported HTML uses native MathML (no external libraries or fonts), so inline math like `E = mc²` and block equations display as properly typeset math in any modern browser — instead of showing the raw LaTeX source. (PDF export keeps the LaTeX source, since the PDF renderer can't draw MathML.)

## [0.20.0] - 2026-05-29

### Changed
- **Much cleaner HTML and PDF export.** Exported documents no longer carry editor-only scaffolding:
  - **Tables** export as clean, bordered tables. Previously the row/column drag handles, insert/delete buttons, and icons leaked into the output.
  - **Math** is written as readable LaTeX source instead of broken, unstyled markup.
  - Stray editor widgets and hard-break artifacts are removed, and long code lines now wrap instead of being clipped.
  - **PDF export now uses the same pipeline as HTML export**, so the two render consistently (previously PDF embedded the raw editor view).

### Fixed
- **Nested list items and table cells no longer lose content on export.** Nested bullet/numbered items kept their text (they could export empty), and a table cell containing a list or extra paragraphs now exports in full.

## [0.19.0] - 2026-05-29

### Fixed
- **Closing or quitting right after typing no longer loses edits.** If you typed and then immediately closed a window (⌘W) or quit (⌘Q) within a fraction of a second, the unsaved-changes prompt could fail to appear and the most recent edits were lost — for a never-saved document, unrecoverably. Close and quit now check the editor's actual contents instead of a delayed "modified" flag, so you're always asked first.
- **Reading time no longer explodes from pasted/linked images.** A reference-style image (`[id]: data:…`) or an image whose title contained deeply nested parentheses could leak its huge embedded data into the statistics, showing absurd character counts and reading times (e.g. "1601 min"). All embedded image data is now excluded from the counts.
- **Find & Replace keeps formatting when replacing the first word of a styled run.** Replacing a word that began a bold/italic span (e.g. the "bar" in **bar** baz) previously dropped the formatting; the replacement now inherits the run's style correctly.

## [0.18.0] - 2026-05-29

### Fixed
- **Opening a file that's already open no longer creates a duplicate window.** If you open a document that's already open in another window — via Open, Open Recent, or a Finder double-click — Mallow now brings that window to the front instead of opening a second copy. Previously two windows could hold the same file and autosave over each other. The check is race-safe even if the same file is opened twice in quick succession.

### Changed
- **Hardened file renaming** (defense-in-depth): the backend now independently re-validates that a rename's new name is a plain filename within the same folder, rejecting any value that contains a path separator or would resolve outside the folder — a second safety layer behind the existing in-app guard. No change for normal renames.

## [0.17.0] - 2026-05-29

### Fixed
- **Prevented several rare ways edits could be lost.** Continuing to type while a save was being written to disk, an external-change reload arriving mid-typing, or renaming a file at the same moment an autosave fired could each, in a narrow timing window, drop your most recent edits. Save/reload now reconcile against the actual editor contents (not a delayed "modified" flag), and renaming is serialized against saving.

### Security
- **HTML export is now sanitized.** When you Export as HTML, links and images carrying unsafe URL schemes (e.g. `javascript:`, non-image `data:`) are stripped, and the exported file now includes a strict Content-Security-Policy — so a malicious `.md` you open and re-export can't carry script into the exported file. (In-app rendering was already protected by the app's CSP.)

## [0.16.0] - 2026-05-29

### Added
- **Session restore**: Mallow reopens where you left off — the main window returns to its last size and position (kept on-screen even if you'd moved it to a display that's now disconnected), and your most recently edited document reopens on launch. Opening a file from Finder, or your first-ever launch (which shows the welcome guide), still take precedence.

### Fixed
- **No more dark flash on launch in Light Mode**: the window now matches your macOS appearance from the very first frame. (Dark Mode launch is unchanged.)

## [0.15.0] - 2026-05-29

### Added
- **Selection word count**: select some text and the corner badge shows that selection's word and character count; it returns to the whole-document count when you deselect.
- **Jump to heading**: click a heading in the Table of Contents (⌘⇧I → Contents) to scroll straight to it. The outline entries are now keyboard-focusable.

## [0.14.0] - 2026-05-29

### Added
- **Smart typography**: as you type, straight quotes become curly (“ ” / ‘ ’), `--` becomes an en dash (–), `---` an em dash (—), and `...` an ellipsis (…). It stays out of code blocks and inline code, leaves a line-leading `---` as a divider, and you can undo any substitution with Backspace or ⌘Z.
- **Spell check**: the system spell checker is now active in the editor — right-click a misspelled word for suggestions. Uses your macOS language settings; nothing to configure.

## [0.13.0] - 2026-05-29

### Added
- **Focus Mode** (View → Focus Mode, ⇧⌘F): dims everything except the paragraph you're writing, and quietly tucks away the corner buttons and word-count badge for a clean surface. Works at the paragraph level, so it's reliable in Korean and Japanese too.
- **Typewriter Scrolling** (View → Typewriter Scrolling, ⌃⌘T): keeps the line you're typing centered on screen, like paper advancing in a typewriter. Stays out of the way during Korean/Japanese input composition.

## [0.12.0] - 2026-05-29

### Changed
- **Open Recent is more reliable**: clicking a recent file always opens the file you clicked, even if the list reordered in the background, and entries that no longer exist are removed automatically (with a brief notice) instead of failing.

### Added
- **Clear Recent**: an "Open Recent → Clear Recent" menu item to empty the recent-files list.

## [0.11.0] - 2026-05-29

### Changed
- **Safer file renaming**: renaming a document from the title bar can no longer overwrite another file or move it out of its folder. If the name is already taken you'll be told, and invalid names (containing slashes, etc.) are rejected with a clear message instead of failing silently.
- **Steadier title bar**: the "unsaved" dot (●) no longer nudges the filename sideways when it appears or disappears.

### Fixed
- The rename field and the title-bar file name are now labeled for screen readers.

## [0.10.0] - 2026-05-29

### Added
- **Find & Replace refinements**: the find field is pre-filled with your current selection when you open it (⌘F), "Replace All" confirms how many were replaced, and replacing text now keeps the original formatting (bold/italic) of the match. When nothing matches, the counter shows "No results" instead of "0/0".

### Changed
- **Find no longer jumps the page on every keystroke** — the view stays put as you type and only moves when you go to the next/previous match; closing the bar returns you to where you were.
- **Accessibility**: the Style panel, document-info panel, toasts, and the live word-count are now announced to screen readers and labeled; toolbar buttons have accessible names; Escape closes the Style and Statistics panels (matching Find and the rename field).
- **Tidier notifications**: identical messages no longer stack up, the number on screen is capped, and animations respect the system "reduce motion" setting.
- The English quit prompt is now grammatical for a single document ("1 document has unsaved changes").

### Fixed
- Closing Find/Replace now returns keyboard focus to the editor.

## [0.9.0] - 2026-05-29

### Added
- **Drag & drop images now work**: dragging an image file from Finder (or another app) onto the editor embeds it inline, the same as pasting. Previously the drop was intercepted before it reached the editor.
- **Export confirmation**: exporting to PDF or HTML now shows a brief confirmation with the saved file name, and exporting an empty document tells you there's nothing to export instead of silently writing a blank file.

### Changed
- **HTML export fidelity**: bulleted, numbered, and task lists, code blocks, and images now export as clean, correct HTML (previously editor scaffolding leaked into the file). The exported file also follows your light/dark appearance.
- **PDF export polish**: links keep their color, code blocks / images / tables are no longer split across page breaks, and long code lines wrap instead of being clipped.
- **More accurate statistics**: word count now handles Japanese and Chinese (which don't use spaces between words), reading time is estimated per language, and the paragraph count no longer includes headings, lists, or code blocks. Embedded images are excluded from all counts (a single pasted image no longer shows an enormous reading time).
- **Clearer image errors**: distinct messages for "image is too large" vs. "couldn't add the image", and dropping several images at once shows at most one message per reason instead of one per file. The image upload button now also respects the size limit, and embedded images are no longer cropped.

## [0.8.0] - 2026-05-29

### Added
- **Paste & drop images**: paste an image from the clipboard, or drag an image file into the editor, and it's embedded directly in your document. Images are stored inline, so the document stays self-contained and portable — there are no separate image files to keep track of. Localized (Korean / English / Japanese).

## [0.7.0] - 2026-05-29

### Added
- **Automatic light & dark theme**: Mallow now follows your macOS appearance — it shows a light theme in Light Mode and the dark theme in Dark Mode, and switches instantly when you change the system appearance while the app is open. No setting to toggle; it just matches your system.

## [0.6.0] - 2026-05-29

### Added
- **Export as HTML** (File → Export as HTML…, ⇧⌘E): save the current document as a self-contained, styled HTML file you can open in any browser or paste elsewhere. Localized (Korean / English / Japanese).

## [0.5.0] - 2026-05-29

### Added
- **Welcome guide on first launch**: a short, localized welcome document (Korean / English / Japanese) introduces what Mallow can do — live formatting, Find & Replace, stats, PDF export, autosave — the first time you open the app. It's a normal unsaved document; clear it and start writing.

## [0.4.0] - 2026-05-29

### Added
- **Autosave**: once a document has been saved to a file, your edits are written to disk automatically a moment after you stop typing — no more reaching for ⌘S constantly. New, untitled documents still prompt for a location on the first save.

## [0.3.0] - 2026-05-29

### Added
- **Live word count**: a subtle word-count and reading-time indicator appears in the bottom-right corner while you write (hidden on an empty document). Localized (Korean / English / Japanese).

## [0.2.0] - 2026-05-29

### Added
- **Find & Replace (⌘F)**: search the document with live match highlighting and a match counter, jump between matches (Enter / Shift+Enter), replace the current match or all matches, and an optional case-sensitive mode. Available from Edit → Find… and localized (Korean / English / Japanese).
- **Automated tests + CI**: a Vitest unit-test suite for the core logic modules and a GitHub Actions workflow that type-checks and runs the tests on every push and pull request.

### Changed
- The interface language is pinned once at startup, so the native menu and the in-app UI always stay in the same language for the whole session.

### Fixed
- Prevented a possible one-frame white flash when opening a new window.
- A rapid double-press of ⌘Q no longer stacks multiple quit-confirmation dialogs.

## [0.1.3] - 2026-05-29

### Added
- **Localization (Korean / English / Japanese)**: the entire interface — native menu, dialogs, tooltips, the statistics and style panels, the editor placeholder, and dates — now follows the device language and shows a single consistent language. Korean, Japanese, and English are supported; any other language falls back to English.

## [0.1.2] - 2026-05-29

### Added
- **Multiple windows**: New (⌘N) and Open (⌘O · Recent Files · Finder double-click) now open in a separate window instead of replacing the current document. Opening from an empty new-document window reuses that window.
- **Renaming a file moves it on disk**: Renaming a saved document from the title bar renames the actual file within the same folder.

### Changed
- **Quit (⌘Q) is now atomic**: when there are unsaved documents, a single consolidated confirmation is shown and quit/cancel applies to every window at once (no more closing only some windows).
- The close/quit confirmation dialogs now show the filename so you can tell which document they refer to.
- The recent-files list is now managed as a single in-app source, so it is no longer lost when several windows are open at the same time.

### Fixed
- Fixed an issue where a save (⌘S) overlapping with a reload of an externally modified file could revert the just-saved content to the old content.
- Prevented the save dialog from appearing twice during rapid consecutive saves.
- The dark background is now applied immediately to newly opened windows.

## [0.1.1] - 2026-05-28

### Added
- **Automatic external-change reload**: after editing a .md file in another app and returning to Mallow, the document refreshes from disk automatically (you are asked first if you have unsaved edits).
- **Move the window by dragging the title bar.**

### Changed
- Long titles are truncated with an ellipsis (…) so they no longer overflow the title bar.

## [0.1.0] - 2026-05-27

### Added
- First release. Milkdown-based WYSIWYG markdown editing, open/save .md, PDF export, document statistics and table-of-contents panels, recent files, a native menu, and a dark theme.

### Fixed
- Fixed an issue where a document failed to load when launching the app by double-clicking a .md file in Finder.
- Removed the white screen flash on the first launch in dark mode.

[0.27.0]: https://github.com/gurumdeva/mallow/compare/v0.26.0...v0.27.0
[0.26.0]: https://github.com/gurumdeva/mallow/compare/v0.25.0...v0.26.0
[0.25.0]: https://github.com/gurumdeva/mallow/compare/v0.24.0...v0.25.0
[0.24.0]: https://github.com/gurumdeva/mallow/compare/v0.23.0...v0.24.0
[0.23.0]: https://github.com/gurumdeva/mallow/compare/v0.22.0...v0.23.0
[0.22.0]: https://github.com/gurumdeva/mallow/compare/v0.21.0...v0.22.0
[0.21.0]: https://github.com/gurumdeva/mallow/compare/v0.20.0...v0.21.0
[0.20.0]: https://github.com/gurumdeva/mallow/compare/v0.19.0...v0.20.0
[0.19.0]: https://github.com/gurumdeva/mallow/compare/v0.18.0...v0.19.0
[0.18.0]: https://github.com/gurumdeva/mallow/compare/v0.17.0...v0.18.0
[0.17.0]: https://github.com/gurumdeva/mallow/compare/v0.16.0...v0.17.0
[0.16.0]: https://github.com/gurumdeva/mallow/compare/v0.15.0...v0.16.0
[0.15.0]: https://github.com/gurumdeva/mallow/compare/v0.14.0...v0.15.0
[0.14.0]: https://github.com/gurumdeva/mallow/compare/v0.13.0...v0.14.0
[0.13.0]: https://github.com/gurumdeva/mallow/compare/v0.12.0...v0.13.0
[0.12.0]: https://github.com/gurumdeva/mallow/compare/v0.11.0...v0.12.0
[0.11.0]: https://github.com/gurumdeva/mallow/compare/v0.10.0...v0.11.0
[0.10.0]: https://github.com/gurumdeva/mallow/compare/v0.9.0...v0.10.0
[0.9.0]: https://github.com/gurumdeva/mallow/compare/v0.8.0...v0.9.0
[0.8.0]: https://github.com/gurumdeva/mallow/compare/v0.7.0...v0.8.0
[0.7.0]: https://github.com/gurumdeva/mallow/compare/v0.6.0...v0.7.0
[0.6.0]: https://github.com/gurumdeva/mallow/compare/v0.5.0...v0.6.0
[0.5.0]: https://github.com/gurumdeva/mallow/compare/v0.4.0...v0.5.0
[0.4.0]: https://github.com/gurumdeva/mallow/compare/v0.3.0...v0.4.0
[0.3.0]: https://github.com/gurumdeva/mallow/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/gurumdeva/mallow/compare/v0.1.3...v0.2.0
[0.1.3]: https://github.com/gurumdeva/mallow/compare/v0.1.2...v0.1.3
[0.1.2]: https://github.com/gurumdeva/mallow/compare/v0.1.1...v0.1.2
[0.1.1]: https://github.com/gurumdeva/mallow/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/gurumdeva/mallow/releases/tag/v0.1.0
