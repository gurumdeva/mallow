// swift-tools-version:5.9
import PackageDescription

// Mallow — the native macOS app (Swift/AppKit) on the Inkstone engine. The Rust core lives in the
// sibling `inkstone` repo and links in as a C-ABI staticlib; build it first:
//   cargo build --features ffi --release        (from ../../inkstone)
// then from this `native/` directory:
//   swift build && swift run Mallow
// (See ./build.sh, which does both. The sibling layout ../../inkstone is assumed.)
let package = Package(
    name: "Mallow",
    platforms: [.macOS(.v12)],
    targets: [
        // The Inkstone C-ABI: header + module map only (the header symlinks to the engine's
        // include/inkstone.h). The actual symbols come from libinkstone.a, linked below.
        .systemLibrary(name: "CInkstone", path: "Sources/CInkstone"),
        .executableTarget(
            name: "Mallow",
            dependencies: ["CInkstone"],
            // Link the sibling inkstone repo's staticlib. The -L path resolves from this package
            // root (native/) → ../../inkstone/target/release. AppKit / UniformTypeIdentifiers are
            // auto-linked by Swift from their imports.
            linkerSettings: [
                .unsafeFlags(["-L../../inkstone/target/release", "-linkstone"])
            ]
        ),
    ]
)
