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
            let text = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
            RecentFiles.add(path)
            return EditorDocument(text: text, path: path)
        case .blank, .none:
            let key = "mallow.welcomed"
            if !UserDefaults.standard.bool(forKey: key) {
                UserDefaults.standard.set(true, forKey: key)
                return EditorDocument(text: demoMarkdown, path: nil)
            }
            return EditorDocument(text: "", path: nil)
        }
    }
}
