// swift-tools-version:5.9
import PackageDescription

// Mallow — the native macOS app (SwiftUI shell + an NSViewRepresentable editor) on the Inkstone
// engine. The text surface stays NSTextView (live-preview syntax hiding / glyph substitution / IME
// need TextKit), wrapped in SwiftUI; everything else (app lifecycle, chrome, popovers, menus) is
// SwiftUI. The Rust core lives in the
// sibling `inkstone` repo and links in as a C-ABI staticlib; build it first:
//   cargo build --features ffi --release        (from ../inkstone)
// then from this directory (the repo root):
//   swift build && swift run Mallow
// (See ./build.sh, which does both. The sibling layout ../inkstone is assumed.)
let package = Package(
    name: "Mallow",
    platforms: [.macOS(.v14)],
    dependencies: [
        // Sparkle 2 — in-app auto-update. Pinned `from: "2.9.4"` so SemVer keeps us at or above every
        // 2025 XPC-validation CVE fix (docs/security/sparkle-update-security.md, condition 1). Never
        // lower this floor. Distributed as a signed binary XCFramework; build-app.sh embeds + signs it.
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.9.4"),
    ],
    targets: [
        // The Inkstone C-ABI: header + module map only (the header symlinks to the engine's
        // include/inkstone.h). The actual symbols come from libinkstone.a, linked below.
        .systemLibrary(name: "CInkstone", path: "Sources/CInkstone"),
        .executableTarget(
            name: "Mallow",
            dependencies: ["CInkstone", .product(name: "Sparkle", package: "Sparkle")],
            // Link the sibling inkstone repo's staticlib. The -L path resolves from this package
            // root (the repo root) → ../inkstone/target/release. AppKit / UniformTypeIdentifiers are
            // auto-linked by Swift from their imports.
            linkerSettings: [
                .unsafeFlags(["-L../inkstone/target/release", "-linkstone"])
            ]
        ),
        // Unit tests for the app's pure logic (`@testable import Mallow`). Mallow is an executable target
        // that links the engine staticlib, so the test bundle needs the same `-L`/`-l` flags to resolve
        // those symbols. UI/rendering isn't unit-testable; these lock in the pure helpers (encoding/BOM
        // open guard, filename validation, URL detection, image embed, path canonicalization, offsets).
        .testTarget(
            name: "MallowTests",
            dependencies: ["Mallow"],
            linkerSettings: [
                .unsafeFlags(["-L../inkstone/target/release", "-linkstone"])
            ]
        ),
    ]
)
