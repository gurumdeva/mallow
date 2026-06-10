// OpenSpec — what a window should open with. SwiftUI's WindowGroup creates identical windows, so to
// open blank vs a specific file we parameterize the group with this value: `WindowGroup(for: OpenSpec)`
// + `openWindow(value:)`. New Window / first launch arrive as `nil` (→ blank, or the welcome demo on the
// very first run); File ▸ Open and Open Recent push a `.file(path)`.

import Foundation

enum OpenSpec: Codable, Hashable {
    case blank
    case file(path: String)
}

extension EditorDocument {
    /// Cap for synchronously opening a file in the editor (read + decode + parse on the window-init main
    /// thread). 50 MB is orders of magnitude above any real markdown note; a file larger than this opens
    /// as an empty untitled window rather than hanging the app.
    static let maxOpenBytes = 50 * 1024 * 1024

    /// Build a document for an open request. A file is read off disk (empty on failure) and recorded in
    /// the recent list; `nil`/`.blank` is an empty buffer, except the first ever launch, which seeds the
    /// welcome demo so a new user sees live styling immediately.
    static func make(for spec: OpenSpec?) -> EditorDocument {
        switch spec {
        case .file(let path):
            // Stability guard: never read + parse a pathologically large file synchronously on the main
            // thread (this runs in the window's init) — a few-hundred-MB `.md` would beachball the app at
            // open. Above the cap, open an empty UNTITLED window instead; the file on disk is left untouched
            // (path unbound → no autosave can clobber it). A real markdown note is never anywhere near this.
            if let attrs = try? FileManager.default.attributesOfItem(atPath: path),
               let size = attrs[.size] as? Int, size > maxOpenBytes {
                return EditorDocument(text: "", path: nil)
            }
            // Read the raw bytes once. Strip a leading UTF-8 BOM (EF BB BF) before decoding (Foundation
            // would consume it anyway) but REMEMBER it (`hadBOM`) so save re-prepends it — a Windows /
            // PowerShell BOM file isn't silently de-BOM'd on an open→save round-trip.
            // CRITICAL data-safety guard: if the bytes aren't valid UTF-8 (UTF-16, Latin-1, binary) or the
            // file can't be read, do NOT open an empty buffer bound to `path` — the 1.5s autosave (or a ⌘S)
            // would then write it over the original, silently destroying it. Instead recover the content via
            // the file's own encoding and open it UNTITLED (path: nil → autosave off, Save prompts), so the
            // original is never touched.
            if let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
               let decoded = EditorDocument.decodeUTF8(data) {
                RecentFiles.add(path)
                return EditorDocument(text: decoded.text, path: path, hadBOM: decoded.hadBOM)
            }
            var usedEncoding = String.Encoding.utf8
            let recovered = (try? String(contentsOf: URL(fileURLWithPath: path), usedEncoding: &usedEncoding)) ?? ""
            return EditorDocument(text: recovered, path: nil)
        case .blank:
            return EditorDocument(text: "", path: nil)   // New Window: always an empty buffer
        case .none:
            // First launch only (New uses .blank): reopen the last-edited file, else the welcome demo on
            // the first ever run, else blank. SessionStore.planStartup owns the welcomed flag + the read.
            switch SessionStore.planStartup(explicitPath: nil, demo: demoMarkdown) {
            case let .explicit(content, path), let .restore(content, path):
                return EditorDocument(text: content, path: path)
            case .welcome:
                return EditorDocument(text: demoMarkdown, path: nil)
            case .blank:
                return EditorDocument(text: "", path: nil)
            }
        }
    }

    /// Decode raw file bytes as UTF-8, stripping (and remembering) a leading UTF-8 BOM (EF BB BF). Returns
    /// nil when the bytes aren't valid UTF-8 — the caller (`make(for:)`) then refuses to bind the path, so a
    /// non-UTF-8 file is opened untitled and can't be clobbered. Pure + unit-tested: the data-safety guard
    /// and the BOM-preservation guarantee both ride on this.
    static func decodeUTF8(_ data: Data) -> (text: String, hadBOM: Bool)? {
        let hadBOM = data.starts(with: [0xEF, 0xBB, 0xBF])
        let body = hadBOM ? data.dropFirst(3) : data
        guard let text = String(data: body, encoding: .utf8) else { return nil }
        return (text, hadBOM)
    }
}
