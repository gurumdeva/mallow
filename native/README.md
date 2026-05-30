# Mallow — native macOS app

The native Swift/AppKit Mallow app, built on the [Inkstone](https://github.com/gurumdeva/inkstone)
engine (a markdown-as-truth Rust core, linked as a C-ABI staticlib). This is the successor to the
Tauri/Milkdown app in [`../src`](../src) + [`../src-tauri`](../src-tauri): it removes the WKWebView
and uses the OS system IME via `NSTextView`. macOS only.

## Engine dependency (sibling checkout)
The Rust engine lives in a separate repo and must be checked out as a **sibling** of this one:

```
Documents/
  inkstone/          # the engine (private: gurumdeva/inkstone)
  markdown-editor/   # this repo (Mallow)
    native/          # ← you are here
```

`Package.swift` links `../../inkstone/target/release/libinkstone.a`, and
`Sources/CInkstone/inkstone.h` symlinks `../../inkstone/include/inkstone.h`. Set the engine up
first (its README has details).

## Build & run
```sh
native/build.sh                       # builds the engine staticlib, then runs the app
# or manually, from native/:
( cd ../../inkstone && cargo build --features ffi --release )
swift build && swift run Mallow
```

## Features
All built on the Inkstone engine over the C-ABI (`Sources/Mallow/main.swift`); the OS system IME
comes free with `NSTextView`.

- **Live preview** — Inkstone parses the markdown as you type; syntax (`#`, `**`, `*`, `~~`,
  `` ` ``, and list/quote markers) collapses to zero width except on the caret's line, while
  headings, bold/italic/strike/inline-code, links, code blocks, and blockquotes are styled in place.
- **Commands** — the full Format menu (bold/italic/strikethrough/inline-code, headings ⌘1–3 / body
  ⌘0, bullet & numbered lists, quote, code block, divider), each a verified Inkstone command.
- **Focus mode** — View ▸ Focus Mode (⌃⌘F) dims every block but the caret's (engine
  `focus_decoration`).
- **Multi-window** — File ▸ New (⌘N) / Open (⌘O) spawn independent document windows; ⌘W closes one,
  and the app quits after the last.
- **Files** — open / save / save-as with atomic writes and per-window dirty tracking (Inkstone's
  verified `safety`); a discard prompt guards both close (⌘W) and quit (⌘Q). **Export as HTML**
  (⇧⌘E) renders a styled, self-contained page from the engine.
- **Find** — the native find / replace bar (⌘F).
- **`Sources/CInkstone/`** — the Inkstone C-ABI as a SwiftPM `systemLibrary` (module map + a symlink
  to the engine header).

![Native editor](docs/native-editor.png)

## Status
Rendering, multi-window, and HTML export are verified by screen capture. What still needs a human at
the keyboard — IME typing, caret-move re-reveal, command execution, file dialogs, the Focus toggle,
New/Open spawning windows, and the discard-on-quit prompt — is tracked in
`PENDING-MANUAL-TEST.local.md` (gitignored). Remaining build-out toward Tauri parity: recent files,
and the rest of the Tauri app's feature set.
