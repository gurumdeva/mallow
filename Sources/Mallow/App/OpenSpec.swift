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
    /// Build a document for an open request. A file is read off disk (empty on failure) and recorded in
    /// the recent list; `nil`/`.blank` is an empty buffer, except the first ever launch, which seeds the
    /// welcome demo so a new user sees live styling immediately.
    static func make(for spec: OpenSpec?) -> EditorDocument {
        switch spec {
        case .file(let path):
            // Read as UTF-8 (the common case + the encoding we save as). CRITICAL data-safety guard: if the
            // file is NOT valid UTF-8 (UTF-16, Latin-1, binary) or can't be read, do NOT open an empty
            // buffer bound to `path` — the 1.5s autosave (or a ⌘S) would then write that empty buffer over
            // the original, silently destroying it. Instead recover the content via the file's own encoding
            // and open it UNTITLED (path: nil → autosave is disabled and Save prompts for a location), so
            // the original is never touched. (Round-tripping in the source encoding is a follow-up; the
            // invariant enforced here is simply: never clobber a file we couldn't read as UTF-8.)
            if let text = try? String(contentsOfFile: path, encoding: .utf8) {
                RecentFiles.add(path)
                return EditorDocument(text: text, path: path)
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
}
