import Foundation

/// History and bookmark import (PRD §4.4) — the cold-start killer. Reads other
/// browsers' local stores, normalises into the event schema flagged
/// `source: import:<browser>`, exclusions applied during ingest.
@MainActor
struct HistoryImporter {
    enum Browser: String, CaseIterable, Identifiable {
        case safari, chrome, arc, firefox, zen
        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .safari: "Safari"
            case .chrome: "Chrome"
            case .arc: "Arc"
            case .firefox: "Firefox"
            case .zen: "Zen"
            }
        }

        var historyPath: String? {
            let home = NSHomeDirectory()
            switch self {
            case .safari:
                return home + "/Library/Safari/History.db"
            case .chrome:
                return home + "/Library/Application Support/Google/Chrome/Default/History"
            case .arc:
                return home + "/Library/Application Support/Arc/User Data/Default/History"
            case .firefox, .zen:
                let base = home + "/Library/Application Support/\(self == .firefox ? "Firefox" : "zen")/Profiles"
                let profiles = (try? FileManager.default.contentsOfDirectory(atPath: base)) ?? []
                for profile in profiles {
                    let candidate = base + "/" + profile + "/places.sqlite"
                    if FileManager.default.fileExists(atPath: candidate) { return candidate }
                }
                return nil
            }
        }

        var bookmarksPath: String? {
            let home = NSHomeDirectory()
            switch self {
            case .safari: return home + "/Library/Safari/Bookmarks.plist"
            case .chrome: return home + "/Library/Application Support/Google/Chrome/Default/Bookmarks"
            case .arc: return home + "/Library/Application Support/Arc/User Data/Default/Bookmarks"
            case .firefox, .zen: return historyPath // places.sqlite holds both
            }
        }

        var isInstalled: Bool {
            historyPath.map { FileManager.default.fileExists(atPath: $0) } ?? false
        }
    }

    enum ImportError: Error {
        /// TCC denied the read — the designed Full Disk Access flow, not a bare OS dialog.
        case needsFullDiskAccess
        case unreadable(String)
    }

    struct Result {
        var visits = 0
        var bookmarks = 0
        var oldest: Date?
    }

    let observations: ObservationStore

    // MARK: - Entry

    func importHistory(from browser: Browser, overridePath: String? = nil) throws -> Result {
        guard let path = overridePath ?? browser.historyPath else {
            throw ImportError.unreadable("no history file found")
        }
        let workingCopy = try copyToTemp(path)
        defer { try? FileManager.default.removeItem(atPath: workingCopy) }
        let source = try Database(path: workingCopy, readOnly: true)

        observations.clearImports(from: browser.rawValue) // re-import replaces, never duplicates
        var result = Result()
        observations.performBulk {
            switch browser {
            case .safari:
                result = importSafariVisits(source)
            case .chrome, .arc:
                result = importChromiumVisits(source, browser: browser)
            case .firefox, .zen:
                result = importMozillaVisits(source, browser: browser)
            }
            result.bookmarks = importBookmarks(from: browser, mozillaDB: source)
        }
        return result
    }

    /// Source DBs are locked while their browser runs; copy first, read the copy.
    /// A TCC-protected path (Safari) fails here with EPERM → the FDA flow.
    private func copyToTemp(_ path: String) throws -> String {
        let temp = NSTemporaryDirectory() + "sill-import-\(UUID().uuidString).sqlite"
        do {
            try FileManager.default.copyItem(atPath: path, toPath: temp)
        } catch {
            let nsError = error as NSError
            let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError
            if nsError.code == NSFileReadNoPermissionError || underlying?.code == Int(EPERM) {
                throw ImportError.needsFullDiskAccess
            }
            throw ImportError.unreadable(error.localizedDescription)
        }
        // WAL sidecar carries recent visits; best effort, absence is fine.
        try? FileManager.default.copyItem(atPath: path + "-wal", toPath: temp + "-wal")
        try? FileManager.default.copyItem(atPath: path + "-shm", toPath: temp + "-shm")
        return temp
    }

    // MARK: - Per-engine readers

    /// Safari: Core Data epoch (2001-01-01).
    private func importSafariVisits(_ source: Database) -> Result {
        var result = Result()
        let rows = (try? source.query("""
            SELECT v.visit_time AS t, i.url AS url, v.title AS title
            FROM history_visits v JOIN history_items i ON v.history_item = i.id
            """)) ?? []
        for row in rows {
            guard let t = row.real("t"), let urlString = row.text("url"), let url = URL(string: urlString) else { continue }
            let ts = t + 978307200
            if observations.recordImportedVisit(ts: ts, url: url, title: row.text("title"), transition: "other", sourceBrowser: "safari") {
                result.visits += 1
                tallyOldest(&result, ts)
            }
        }
        return result
    }

    /// Chromium: microseconds since 1601-01-01; transition core type in the low byte.
    private func importChromiumVisits(_ source: Database, browser: Browser) -> Result {
        var result = Result()
        let rows = (try? source.query("""
            SELECT v.visit_time AS t, v.transition AS tr, u.url AS url, u.title AS title
            FROM visits v JOIN urls u ON v.url = u.id
            """)) ?? []
        for row in rows {
            guard let t = row.real("t"), let urlString = row.text("url"), let url = URL(string: urlString) else { continue }
            let ts = t / 1_000_000 - 11_644_473_600
            let transition: String = switch (row.int("tr") ?? 0) & 0xFF {
            case 1: "typed"
            case 0: "link"
            case 7: "form"
            case 8: "reload"
            default: "other"
            }
            if observations.recordImportedVisit(ts: ts, url: url, title: row.text("title"), transition: transition, sourceBrowser: browser.rawValue) {
                result.visits += 1
                tallyOldest(&result, ts)
            }
        }
        return result
    }

    /// Mozilla: microseconds since the unix epoch; visit_type 2 = typed.
    private func importMozillaVisits(_ source: Database, browser: Browser) -> Result {
        var result = Result()
        let rows = (try? source.query("""
            SELECT h.visit_date AS t, h.visit_type AS tr, p.url AS url, p.title AS title
            FROM moz_historyvisits h JOIN moz_places p ON h.place_id = p.id
            """)) ?? []
        for row in rows {
            guard let t = row.real("t"), let urlString = row.text("url"), let url = URL(string: urlString) else { continue }
            let ts = t / 1_000_000
            let transition: String = switch row.int("tr") ?? 0 {
            case 2: "typed"
            case 1: "link"
            case 9: "reload"
            default: "other"
            }
            if observations.recordImportedVisit(ts: ts, url: url, title: row.text("title"), transition: transition, sourceBrowser: browser.rawValue) {
                result.visits += 1
                tallyOldest(&result, ts)
            }
        }
        return result
    }

    private func tallyOldest(_ result: inout Result, _ ts: TimeInterval) {
        let date = Date(timeIntervalSince1970: ts)
        if result.oldest.map({ date < $0 }) ?? true {
            result.oldest = date
        }
    }

    // MARK: - Bookmarks (flat, unpromoted — reachable from the palette in M6)

    private func importBookmarks(from browser: Browser, mozillaDB: Database) -> Int {
        switch browser {
        case .safari:
            return importSafariBookmarks()
        case .chrome, .arc:
            return importChromiumBookmarks(browser)
        case .firefox, .zen:
            let rows = (try? mozillaDB.query("""
                SELECT p.url AS url, b.title AS title
                FROM moz_bookmarks b JOIN moz_places p ON b.fk = p.id
                WHERE b.type = 1
                """)) ?? []
            var count = 0
            for row in rows {
                guard let url = row.text("url") else { continue }
                observations.addBookmark(url: url, title: row.text("title"), source: browser.rawValue)
                count += 1
            }
            return count
        }
    }

    private func importSafariBookmarks() -> Int {
        guard let path = Browser.safari.bookmarksPath,
              let data = FileManager.default.contents(atPath: path),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            return 0
        }
        var count = 0
        func walk(_ node: [String: Any]) {
            if node["WebBookmarkType"] as? String == "WebBookmarkTypeLeaf",
               let url = node["URLString"] as? String {
                let title = (node["URIDictionary"] as? [String: Any])?["title"] as? String
                observations.addBookmark(url: url, title: title, source: "safari")
                count += 1
            }
            for child in node["Children"] as? [[String: Any]] ?? [] {
                walk(child)
            }
        }
        walk(plist)
        return count
    }

    private func importChromiumBookmarks(_ browser: Browser) -> Int {
        guard let path = browser.bookmarksPath,
              let data = FileManager.default.contents(atPath: path),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let roots = json["roots"] as? [String: Any] else {
            return 0
        }
        var count = 0
        func walk(_ node: [String: Any]) {
            if node["type"] as? String == "url", let url = node["url"] as? String {
                observations.addBookmark(url: url, title: node["name"] as? String, source: browser.rawValue)
                count += 1
            }
            for child in node["children"] as? [[String: Any]] ?? [] {
                walk(child)
            }
        }
        for root in roots.values {
            if let node = root as? [String: Any] {
                walk(node)
            }
        }
        return count
    }
}
