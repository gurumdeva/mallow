# Mallow

A lightweight WYSIWYG Markdown editor for macOS — built with Tauri + Milkdown.

Mallow loads as a native macOS app, edits markdown directly in preview mode (no separate raw view), and ships as a ~5 MB DMG.

![Mallow screenshot](docs/screenshot.png)

## Features

- **Live preview editing** — type and edit markdown right inside the rendered view
- **Distraction-free writing** — Focus Mode (⇧⌘F) dims everything but the current paragraph; Typewriter Scrolling (⌃⌘T) keeps the active line centered. Both reliable in Korean/Japanese.
- **Smart typography & spell check** — curly quotes, en/em dashes, and ellipsis as you type (kept out of code), plus the macOS system spell checker
- **Find & Replace** (⌘F) — live match highlighting, a match counter, jump between matches, replace one or all, and an optional case-sensitive mode
- **Paste & drop images** — paste an image from the clipboard or drag an image file into the editor; it's embedded inline so the document stays self-contained
- **Localized UI (Korean / English / Japanese)** — the whole interface (menu, dialogs, tooltips, panels, dates) follows the device language and shows a single consistent language; any other language falls back to English
- **Multiple windows** — New (⌘N) and Open (⌘O / Recent / Finder double-click) open in a separate window instead of replacing the current document
- **Native macOS chrome** — standard menu bar (File / Edit / View / Window), ⌘N / ⌘O / ⌘S / ⇧⌘S / ⌘E / ⌘W shortcuts, file associations for `.md`
- **Modified indicator** — unsaved changes show as ● in the window title (macOS standard)
- **Autosave** — once a document has been saved to a file, edits are written to disk automatically a moment after you stop typing
- **External-change reload** — edit a file in another app and Mallow refreshes from disk when you return (it asks first if you have unsaved edits)
- **Recent files** — File → Open Recent (persisted across sessions)
- **Statistics & Table of Contents** — word/character/paragraph count, read time, and a collapsible TOC (⌘⇧I) with click-to-jump, plus a live word-count badge that also counts the current selection
- **PDF export** — quick export to a clean light-theme PDF
- **Export as HTML** (⇧⌘E) — save a self-contained, styled HTML file you can open in any browser
- **Automatic light & dark theme** — follows your macOS appearance and switches live when you change it, with system fonts (SF Pro + Apple SD Gothic Neo)

## Download

Grab the latest `.dmg` from the [Releases](../../releases) page.

> **First launch on macOS:** the build is unsigned, so Gatekeeper blocks the first launch.
> Right-click `Mallow.app` → **Open** → confirm. From then on it launches normally.

> **Apple Silicon only.** The current build targets `aarch64-apple-darwin` (M1/M2/M3/M4).

## Development

```bash
npm install
npm run tauri dev    # or: npx tauri dev
```

## Build

```bash
npm run tauri build
```

Artifacts:

- `src-tauri/target/release/bundle/macos/Mallow.app`
- `src-tauri/target/release/bundle/dmg/Mallow_0.1.3_aarch64.dmg`

## Tech stack

- **[Tauri 2](https://tauri.app/)** — Rust + macOS WKWebView shell (small binary, native menus & dialogs)
- **[Milkdown (crepe)](https://milkdown.dev/)** — ProseMirror-based WYSIWYG markdown editor
- **TypeScript + Vite** — frontend
- **html2pdf.js** — client-side PDF export

## Architecture

The frontend is split by responsibility (Document + UIState as the only state holders; views are stateless):

```
src/
├── main.ts            # composition root
├── i18n/              # typed t() helper + locales/{en,ko,ja}.json (shared with the Rust menu)
├── domain/            # EventEmitter, Document, UIState
├── editor/            # EditorController (Milkdown wrapping)
├── services/          # FileService, PdfExporter, RecentFilesStore, MenuBridge, …
├── ui/                # TitleBarView, FilenamePopover, InfoPopover, StylePopover (stateless)
└── analysis/          # StatsCalculator, TocExtractor
```

## Localization

UI strings live in `src/i18n/locales/{en,ko,ja}.json` as the single source of truth.
The TypeScript frontend reads them through a typed `t()` helper, and the Rust native
menu embeds the same files at build time (`include_str!`), so there is one place to edit.
The device language is detected once in Rust (`sys-locale`) and shared with the frontend,
so the entire app — including macOS-injected menu items (via `CFBundleLocalizations`) —
renders in one consistent language: Korean, Japanese, or English (others fall back to English).

## License

MIT — see [LICENSE](LICENSE).
