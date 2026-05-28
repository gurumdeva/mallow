# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/).

Categories: **Added** (new features) · **Changed** (changes to existing behavior) · **Fixed** (bug fixes).

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

[0.1.2]: https://github.com/gurumdeva/mallow/compare/v0.1.1...v0.1.2
[0.1.1]: https://github.com/gurumdeva/mallow/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/gurumdeva/mallow/releases/tag/v0.1.0
