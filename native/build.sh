#!/usr/bin/env bash
# Build + run Mallow's native macOS app (SwiftPM) on the Inkstone engine. macOS only.
# Assumes the `inkstone` repo is checked out as a SIBLING: ../../inkstone (relative to this file).
# Run from anywhere: native/build.sh
set -euo pipefail
cd "$(dirname "$0")"            # markdown-editor/native

INK=../../inkstone
if [ ! -d "$INK" ]; then
  echo "error: expected the Inkstone engine at $INK (a sibling checkout of this repo)." >&2
  echo "       clone gurumdeva/inkstone next to markdown-editor, then re-run." >&2
  exit 1
fi

echo "== building libinkstone.a (cargo --features ffi --release, from $INK) =="
( cd "$INK" && cargo build --features ffi --release )

echo "== Mallow native app (SwiftPM) =="
echo "   VERIFY: type Korean/Japanese via the system IME; **/#/-/> collapse + reveal on the"
echo "   caret's line; ⌘B/⌘I + Format menu; ⌃⌘F focus mode; ⌘N/O/S file I/O. ⌘Q to quit."
swift run Mallow
