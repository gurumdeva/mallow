# Mallow (native) — app bundle

Packages the SwiftPM `Mallow` executable as a double-clickable macOS `.app`
so Finder opens `.md` files with it. The raw `swift build` product is a bare
Unix binary that Finder treats as a CLI tool; the bundle adds the `Info.plist`
(metadata + Markdown document types) and the `Contents/{MacOS,Resources}`
layout macOS needs to launch it as an app and route file-open events.

## Files here

- **`Info.plist`** — bundle metadata. Bundle id is **`com.gurumdeva.mallow-native`**,
  deliberately distinct from the old Tauri build so the two don't collide in
  LaunchServices / TCC. Declares `CFBundleDocumentTypes` for
  `md`, `markdown`, `mdown`, `markdn` (role Editor, rank Owner) plus a
  `public.plain-text` fallback, and imports/exports the
  `net.daringfireball.markdown` UTI.
- **`AppIcon.icns`** — *optional*. Drop one here and the build script bundles
  it; absent, the app uses the generic macOS icon.
- **`../build-app.sh`** — assembles the bundle.

## Build

```sh
build-app.sh
```

It builds `libinkstone` (cargo, from the sibling `../inkstone`), then
`swift build -c release`, then assembles **`.build/Mallow.app`**
(wiped and rebuilt each run, so it's idempotent). If `build-app.sh` isn't
executable yet: `chmod +x build-app.sh`.

## Run

```sh
open .build/Mallow.app                       # launch
open -a .build/Mallow.app /path/to/file.md   # open a file (Finder-style)
```

`open .build/Mallow.app --args foo.md` does **not** pass the file —
`--args` go to the process as argv, not as a document-open event. Use
`open -a … <file>` (above) to exercise the real Finder open path.

## Unsigned — first-launch Gatekeeper

The bundle is **not** code-signed or notarized, so Gatekeeper blocks a plain
double-click the first time. Either:

- right-click the `.app` → **Open** → **Open** (one-time per machine), or
- `xattr -dr com.apple.quarantine .build/Mallow.app`

## Signing / notarization (your separate step)

Out of scope for this script. When you're ready to distribute beyond your own
machine: `codesign --deep --force --options runtime --sign "Developer ID
Application: …" .build/Mallow.app`, then `xcrun notarytool submit … &&
xcrun stapler staple`.

> Re-sign **after** building: the script runs `install_name_tool` on the
> executable (see below), which invalidates any prior signature. Sign last.

## Self-contained note (libinkstone)

inkstone is built `crate-type = ["cdylib","staticlib","rlib"]`, so both
`libinkstone.a` and `libinkstone.dylib` exist in `target/release`. Apple's
linker prefers the **dylib** when both sit in the same `-L` dir, so the Mallow
binary links `libinkstone.dylib` at an **absolute** path inside the inkstone
build tree — which won't exist on another machine. `build-app.sh` therefore
copies that dylib into `Contents/Frameworks/` and rewrites the load command to
`@rpath` (with an rpath of `@loader_path/../Frameworks`), making the `.app`
self-contained. Verify:

```sh
otool -L .build/Mallow.app/Contents/MacOS/Mallow | grep -iv /System/Library
# expect: @rpath/libinkstone.dylib  (+ /usr/lib + /usr/lib/swift entries), no absolute inkstone path
```

(If inkstone is ever switched to staticlib-only, the binary becomes fully
self-contained on its own and the script skips this step automatically.)

## UserDefaults note (bare-binary → bundle)

`UserDefaults.standard` keys by bundle id. The bare `swift run` binary has no
bundle id, so it persists under a process-name domain (`Mallow`); the bundle
persists under **`com.gurumdeva.mallow-native`**. They're different stores, so
session/recent-file state does **not** carry over the first time you switch to
the bundle — expect a fresh start. (No data is lost; the old domain just isn't
read by the bundled app.)
