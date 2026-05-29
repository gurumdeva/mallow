# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/).

Categories: **Added** (new features) · **Changed** (changes to existing behavior) · **Fixed** (bug fixes).

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
