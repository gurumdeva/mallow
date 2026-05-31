// RecentFilesStore (Service) — the persisted recent-files list backing File ▸ Open Recent. Up to 5
// most-recent paths in Application Support/MallowNative/recent.json (atomic), missing files filtered
// out at read time. `rebuildRecentMenu()` repopulates the live submenu.

import AppKit

/// URL of a file named `name` inside Application Support/MallowNative, creating that directory if
/// needed. Every per-app persisted file (recent.json, window.json, …) sits here, so the dir-resolve +
/// createDirectory lives in one place. Falls back to the home directory on the (effectively impossible)
/// chance Application Support can't be located, so callers always get a usable URL.
func mallowSupportFile(_ name: String) -> URL {
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        ?? FileManager.default.homeDirectoryForCurrentUser
    let dir = base.appendingPathComponent("MallowNative", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir.appendingPathComponent(name)
}

enum RecentFiles {
    static let maxCount = 5
    private static var storeURL: URL { mallowSupportFile("recent.json") }
    /// Most-recent-first, with paths that no longer exist on disk filtered out.
    static func list() -> [String] {
        guard let data = try? Data(contentsOf: storeURL),
              let arr = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return arr.filter { FileManager.default.fileExists(atPath: $0) }
    }
    static func add(_ path: String) {
        var arr = list().filter { $0 != path }
        arr.insert(path, at: 0)
        arr = Array(arr.prefix(maxCount))
        try? JSONEncoder().encode(arr).write(to: storeURL, options: .atomic)
    }
    static func clear() {
        try? JSONEncoder().encode([String]()).write(to: storeURL, options: .atomic)
    }
}
