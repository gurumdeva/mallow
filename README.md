# Mallow

A lightweight WYSIWYG Markdown editor for macOS — built with Tauri + Milkdown.

Mallow loads as a native macOS app, edits markdown directly in preview mode (no separate raw view), and ships as a ~5 MB DMG.

![Mallow screenshot](docs/screenshot.png)

## Features

- **Live preview editing** — type and edit markdown right inside the rendered view
- **Native macOS chrome** — standard menu bar (File / Edit / View / Window), ⌘O / ⌘S / ⇧⌘S / ⌘N / ⌘E shortcuts, file associations for `.md`
- **Modified indicator** — unsaved changes show as ● in the window title (macOS standard)
- **Recent files** — File → Open Recent (persisted across sessions)
- **Statistics & Table of Contents** — word/character/paragraph count, read time, and a collapsible TOC (⌘⇧I)
- **PDF export** — quick export to a clean light-theme PDF
- **Dark theme** with system fonts (SF Pro + Apple SD Gothic Neo)

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
- `src-tauri/target/release/bundle/dmg/Mallow_0.1.0_aarch64.dmg`

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
├── domain/            # EventEmitter, Document, UIState
├── editor/            # EditorController (Milkdown wrapping)
├── services/          # FileService, PdfExporter, RecentFilesStore, MenuBridge, …
├── ui/                # TitleBarView, FilenamePopover, InfoPopover (stateless)
└── analysis/          # StatsCalculator, TocExtractor
```

## License

MIT — see [LICENSE](LICENSE).
