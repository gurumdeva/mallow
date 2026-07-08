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
            let read = readFile(atPath: path, recordRecent: true)
            // Bind the path ONLY for a clean UTF-8 read within the size cap. A too-large or non-UTF-8
            // file opens UNTITLED (path: nil → autosave off, Save prompts) so the 1.5s autosave / ⌘S can
            // never write over an original we can't faithfully round-trip. (See `readFile`.)
            if read.boundPathAllowed {
                return EditorDocument(text: read.text, path: path, hadBOM: read.hadBOM)
            }
            return EditorDocument(text: read.text, path: nil)
        case .blank:
            return EditorDocument(text: "", path: nil)   // New Window: always an empty buffer
        case .none:
            // First launch only (New uses .blank): reopen the last-edited file, else the welcome demo on
            // the first ever run, else blank. SessionStore.planStartup owns the welcomed flag + the read.
            switch SessionStore.planStartup(demo: demoMarkdown) {
            case let .restore(content, path, hadBOM):
                return EditorDocument(text: content, path: path, hadBOM: hadBOM)
            case .welcome:
                return EditorDocument(text: demoMarkdown, path: nil)
            case .blank:
                return EditorDocument(text: "", path: nil)
            }
        }
    }

    /// The outcome of reading a file into an editor buffer: the decoded text, whether it carried a UTF-8
    /// BOM (so save re-prepends it), and whether the path is SAFE to bind. `boundPathAllowed` is true only
    /// for a valid-UTF-8 read within the size cap — a too-large or non-UTF-8 file must open untitled so no
    /// autosave can clobber an original we can't round-trip.
    struct FileRead {
        let text: String
        let hadBOM: Bool
        let boundPathAllowed: Bool
    }

    /// THE file reader — the single guarded path every consumer that pulls a file into an editor buffer
    /// must use (initial open via OpenSpec, session restore, external-reload reconcile). Applies, in one
    /// place, the three data-safety guards that used to be duplicated or skipped:
    ///   • 50 MB cap — never read+parse a pathological file synchronously on the window-init main thread;
    ///     above it, return empty + unbound (restore/reload previously had NO cap).
    ///   • UTF-8 BOM detect+remember — a Windows/PowerShell BOM file isn't de-BOM'd on open→save (restore
    ///     previously read BOM-blind and lost it on the next save).
    ///   • non-UTF-8 recovery WITHOUT binding the path — recover via the file's own encoding but open
    ///     untitled so autosave/⌘S can't destroy an original we can't faithfully re-encode.
    /// `recordRecent` adds the path to Open Recent on a successful UTF-8 read — right for a user-driven
    /// open, wrong for a background reconcile / launch restore (which would reorder the menu).
    static func readFile(atPath path: String, recordRecent: Bool) -> FileRead {
        if let attrs = try? FileManager.default.attributesOfItem(atPath: path),
           let size = attrs[.size] as? Int, size > maxOpenBytes {
            return FileRead(text: "", hadBOM: false, boundPathAllowed: false)
        }
        // Read the raw bytes once; strip+remember a leading UTF-8 BOM. Valid UTF-8 → safe to bind path.
        if let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
           let decoded = decodeUTF8(data) {
            if recordRecent { RecentFiles.add(path) }
            return FileRead(text: decoded.text, hadBOM: decoded.hadBOM, boundPathAllowed: true)
        }
        // Not valid UTF-8 (or unreadable): recover via the file's own encoding, but DON'T bind the path.
        var usedEncoding = String.Encoding.utf8
        let recovered = (try? String(contentsOf: URL(fileURLWithPath: path), usedEncoding: &usedEncoding)) ?? ""
        return FileRead(text: recovered, hadBOM: false, boundPathAllowed: false)
    }

    /// Decode raw file bytes as UTF-8, stripping (and remembering) a leading UTF-8 BOM (EF BB BF). Returns
    /// nil when the bytes aren't valid UTF-8 — `readFile` then refuses to bind the path, so a non-UTF-8
    /// file is opened untitled and can't be clobbered. Pure + unit-tested: the data-safety guard and the
    /// BOM-preservation guarantee both ride on this.
    static func decodeUTF8(_ data: Data) -> (text: String, hadBOM: Bool)? {
        let hadBOM = data.starts(with: [0xEF, 0xBB, 0xBF])
        let body = hadBOM ? data.dropFirst(3) : data
        guard let text = String(data: body, encoding: .utf8) else { return nil }
        return (text, hadBOM)
    }
}
