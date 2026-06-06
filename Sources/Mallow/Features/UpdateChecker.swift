// UpdateChecker — a lightweight "is there a newer release?" check against GitHub Releases, with NO
// Sparkle / auto-install dependency. It asks the GitHub API for the repo's latest published release,
// compares that release's semver tag to this bundle's version, and — when a newer one exists — offers
// to open the Releases page in the browser (we never auto-download/replace the running app).
//
// Two entry points:
//   • checkOnLaunchIfDue()  — a throttled (once/day) SILENT check fired at launch. It only surfaces UI
//     when a newer release actually exists; "up to date" and network failures stay quiet.
//   • checkNow()            — the explicit “Check for Updates…” menu command. Always reports a result
//     (newer release / up to date / couldn't check).
//
// Security: the API endpoint and the page we open are BOTH hardcoded to this repo. We deliberately do
// NOT open any URL taken from the network response (no `html_url` follow) — only the constant Releases
// page — so a malformed/hostile response can never redirect the user somewhere unexpected.

import AppKit

enum UpdateChecker {
    private static let repo = "gurumdeva/mallow"
    private static let apiURL = URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!
    /// The page we open on "View Release" — CONSTANT (never derived from the response). `/releases/latest`
    /// redirects to whatever the newest published release is.
    private static let releasesPage = URL(string: "https://github.com/\(repo)/releases/latest")!
    private static let lastCheckKey = "MallowLastUpdateCheck"
    private static let autoInterval: TimeInterval = 24 * 60 * 60   // once a day for the silent launch check

    /// This running build's marketing version, e.g. "1.0.4" (CFBundleShortVersionString). "0" if absent
    /// (e.g. under `swift test`, where there's no app bundle — the pure compare is unit-tested directly).
    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    /// Only the tag is needed; we intentionally don't decode/use `html_url` (see the security note above).
    private struct Release: Decodable { let tag_name: String }

    // MARK: - Entry points

    /// Throttled silent check at launch. Records the attempt time regardless of outcome (so a flaky
    /// network doesn't make every launch hammer the API), and shows the alert ONLY for a newer release.
    static func checkOnLaunchIfDue() {
        let now = Date().timeIntervalSince1970
        guard now - UserDefaults.standard.double(forKey: lastCheckKey) >= autoInterval else { return }
        UserDefaults.standard.set(now, forKey: lastCheckKey)
        fetchLatest { result in
            if case .success(let tag) = result, isNewer(tag, than: currentVersion) {
                presentAvailable(latestTag: tag)
            }
            // up-to-date or failure → stay silent on the automatic path
        }
    }

    /// The explicit menu command — always reports an outcome to the user.
    static func checkNow() {
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: lastCheckKey)
        fetchLatest { result in
            switch result {
            case .success(let tag) where isNewer(tag, than: currentVersion):
                presentAvailable(latestTag: tag)
            case .success:
                info(L.t("update.upToDate.title"),
                     L.t("update.upToDate.body", ["current": currentVersion]))
            case .failure:
                info(L.t("update.failed.title"), L.t("update.failed.body"))
            }
        }
    }

    // MARK: - Version comparison (pure, unit-tested)

    /// True iff release tag `tag` ("v1.0.4") is a strictly higher version than `current` ("1.0.3").
    /// Tolerant + NUMERIC (so 1.0.10 > 1.0.9, which a string compare gets wrong): strip a leading "v",
    /// split on ".", compare integer components, treating a missing trailing component as 0.
    static func isNewer(_ tag: String, than current: String) -> Bool {
        func parts(_ s: String) -> [Int] {
            s.drop(while: { $0 == "v" || $0 == "V" })
                .split(separator: ".")
                .map { Int($0.prefix(while: \.isNumber)) ?? 0 }
        }
        let a = parts(tag), b = parts(current)
        for i in 0 ..< max(a.count, b.count) {
            let l = i < a.count ? a[i] : 0
            let r = i < b.count ? b[i] : 0
            if l != r { return l > r }
        }
        return false
    }

    // MARK: - Networking

    private static func fetchLatest(_ done: @escaping (Result<String, Error>) -> Void) {
        var req = URLRequest(url: apiURL, timeoutInterval: 15)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("Mallow/\(currentVersion)", forHTTPHeaderField: "User-Agent")   // GitHub API requires a UA
        URLSession.shared.dataTask(with: req) { data, _, err in
            let result: Result<String, Error>
            if let data, let rel = try? JSONDecoder().decode(Release.self, from: data) {
                result = .success(rel.tag_name)
            } else {
                result = .failure(err ?? URLError(.badServerResponse))
            }
            DispatchQueue.main.async { done(result) }   // all UI / UserDefaults follow-up on the main thread
        }.resume()
    }

    // MARK: - UI

    private static func presentAvailable(latestTag tag: String) {
        let latest = tag.hasPrefix("v") || tag.hasPrefix("V") ? String(tag.dropFirst()) : tag
        let alert = NSAlert()
        alert.messageText = L.t("update.available.title")
        alert.informativeText = L.t("update.available.body", ["latest": latest, "current": currentVersion])
        alert.addButton(withTitle: L.t("update.available.view"))                       // default ⏎
        alert.addButton(withTitle: L.t("update.available.later")).keyEquivalent = "\u{1b}"  // Esc
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(releasesPage)   // CONSTANT page, never a response-derived URL
        }
    }

    private static func info(_ title: String, _ body: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = body
        alert.runModal()
    }
}
