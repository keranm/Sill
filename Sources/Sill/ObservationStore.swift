import Foundation
import Observation

/// The observation ledger (PRD §3, §4.4): metadata-only events in the local
/// SQLite file. Consent-gated, pausable, wholly deletable. Excluded domains
/// leave no trace of any kind.
@MainActor
@Observable
final class ObservationStore {
    enum ConsentState: String {
        case undecided, granted, declined
    }

    private(set) var consent: ConsentState = .undecided
    private(set) var isPaused = false
    private(set) var observingSince: Date?
    private(set) var userExclusions: Set<String> = []

    /// Recording happens only here — consent on, not paused.
    var isObserving: Bool {
        consent == .granted && !isPaused
    }

    @ObservationIgnored private let db: Database
    /// Session = activity separated by gaps under 25 minutes (PRD §4.5).
    @ObservationIgnored private var currentSessionID = UUID().uuidString
    @ObservationIgnored private var lastEventAt: Date?
    private static let sessionGap: TimeInterval = 25 * 60

    init(db: Database) {
        self.db = db
        try? createSchema()
        migrateColumns()
        loadState()
    }

    private func createSchema() throws {
        try db.execute("""
            CREATE TABLE IF NOT EXISTS event (
                id INTEGER PRIMARY KEY,
                ts REAL NOT NULL,
                kind TEXT NOT NULL,
                domain TEXT,
                path TEXT,
                title TEXT,
                transition TEXT,
                workspace_id TEXT,
                session_id TEXT,
                open_domains TEXT,
                source TEXT NOT NULL DEFAULT 'live'
            );
            CREATE INDEX IF NOT EXISTS event_ts ON event(ts);
            CREATE INDEX IF NOT EXISTS event_domain ON event(domain);
            CREATE TABLE IF NOT EXISTS user_exclusion (
                domain TEXT PRIMARY KEY,
                added_at REAL NOT NULL
            );
            CREATE TABLE IF NOT EXISTS bookmark (
                url TEXT PRIMARY KEY,
                title TEXT,
                source TEXT NOT NULL
            );
            CREATE TABLE IF NOT EXISTS metric (
                key TEXT PRIMARY KEY,
                value INTEGER NOT NULL DEFAULT 0
            );
            """)
    }

    /// Added after launch: which scheme (http/https) a visit actually used,
    /// so a confirmed pattern can rebuild the real URL instead of guessing
    /// https. Rows recorded before this migration have no scheme on file;
    /// re-importing repopulates them.
    private func migrateColumns() {
        try? db.execute("ALTER TABLE event ADD COLUMN scheme TEXT")
    }

    private func loadState() {
        let rows = (try? db.query("SELECT key, value FROM app_state WHERE key IN ('consent','observing_since','paused')")) ?? []
        for row in rows {
            switch row.text("key") {
            case "consent":
                consent = row.text("value").flatMap(ConsentState.init(rawValue:)) ?? .undecided
            case "observing_since":
                observingSince = row.text("value").flatMap(Double.init).map(Date.init(timeIntervalSince1970:))
            case "paused":
                isPaused = row.text("value") == "1"
            default:
                break
            }
        }
        let exclusionRows = (try? db.query("SELECT domain FROM user_exclusion")) ?? []
        userExclusions = Set(exclusionRows.compactMap { $0.text("domain") })
    }

    // MARK: - Consent (D2f: "Not now" keeps observation off; works fully either way)

    func recordConsent(_ granted: Bool) {
        consent = granted ? .granted : .declined
        try? db.run("INSERT OR REPLACE INTO app_state (key, value) VALUES ('consent', ?)", [.text(consent.rawValue)])
        if granted, observingSince == nil {
            let now = Date()
            observingSince = now
            try? db.run(
                "INSERT OR REPLACE INTO app_state (key, value) VALUES ('observing_since', ?)",
                [.text(String(now.timeIntervalSince1970))]
            )
        }
    }

    func setPaused(_ paused: Bool) {
        isPaused = paused
        try? db.run("INSERT OR REPLACE INTO app_state (key, value) VALUES ('paused', ?)", [.text(paused ? "1" : "0")])
    }

    /// Delete-everything (PRD §3.4): verifiably empties observation data.
    /// Workspaces survive; learning doesn't. Consent survives too — deleting
    /// data is not revoking consent (the Learning page in M5 offers both).
    func deleteEverything() {
        try? db.run("DELETE FROM event")
        try? db.run("DELETE FROM bookmark")
        try? db.execute("DELETE FROM pattern")
        try? db.execute("DELETE FROM metric")
        try? db.execute("VACUUM")
        observingSince = nil
        try? db.run("DELETE FROM app_state WHERE key = 'observing_since'")
    }

    /// Aggregate facts for the Learning page ("about forty sites").
    var distinctDomainCount: Int {
        Int((try? db.query("SELECT count(DISTINCT domain) AS n FROM event WHERE kind = 'visit'").first?.int("n")) ?? 0)
    }

    /// Recent live visits for Home's RECENT list — carries the real URL each
    /// page was actually visited at, not a reconstructed guess.
    func recentVisits(limit: Int) -> [(title: String, url: URL, ts: TimeInterval)] {
        let rows = (try? db.query("""
            SELECT title, domain, path, scheme, max(ts) AS ts FROM event
            WHERE kind = 'visit' AND source = 'live' AND title IS NOT NULL AND title != ''
            GROUP BY domain, title ORDER BY ts DESC LIMIT ?
            """, [.int(Int64(limit))])) ?? []
        return rows.compactMap { row in
            guard let title = row.text("title"), let domain = row.text("domain"), let ts = row.real("ts") else { return nil }
            let scheme = row.text("scheme") ?? "https"
            let path = row.text("path").flatMap { $0.isEmpty ? nil : $0 } ?? "/"
            guard let url = URL(string: "\(scheme)://\(domain)\(path)") else { return nil }
            return (title, url, ts)
        }
    }

    var hasImportedHistory: Bool {
        ((try? db.query("SELECT 1 FROM event WHERE source LIKE 'import%' LIMIT 1").first) != nil)
    }

    func incrementMetric(_ key: String) {
        try? db.run("""
            INSERT INTO metric (key, value) VALUES (?, 1)
            ON CONFLICT(key) DO UPDATE SET value = value + 1
            """, [.text(key)])
    }

    func allMetrics() -> [String: Int] {
        let rows = (try? db.query("SELECT key, value FROM metric")) ?? []
        var metrics: [String: Int] = [:]
        for row in rows {
            if let key = row.text("key"), let value = row.int("value") {
                metrics[key] = Int(value)
            }
        }
        return metrics
    }

    /// H5 proxy: one tick per calendar day the shell is actually used.
    func markActiveDayIfNeeded() {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let today = formatter.string(from: Date())
        let last = (try? db.query("SELECT value FROM app_state WHERE key = 'last_active_day'").first?.text("value"))
        guard last != today else { return }
        try? db.run("INSERT OR REPLACE INTO app_state (key, value) VALUES ('last_active_day', ?)", [.text(today)])
        incrementMetric("active_days")
    }

    func appStateValue(_ key: String) -> String? {
        try? db.query("SELECT value FROM app_state WHERE key = ?", [.text(key)]).first?.text("value")
    }

    /// The publishable aggregate (PRD §4.9): explicit user action only; no
    /// URLs, no titles, no individual timestamps — nothing that leaks history.
    func exportAggregate() -> [String: Any] {
        var export: [String: Any] = [:]
        export["generated"] = ISO8601DateFormatter.string(
            from: Date(), timeZone: .current, formatOptions: [.withFullDate]
        )
        export["consent"] = consent.rawValue
        if let since = observingSince {
            export["days_observing"] = max(1, Int(Date().timeIntervalSince(since) / 86400))
        }

        var events: [String: Int] = [:]
        for row in (try? db.query("SELECT source, count(*) AS n FROM event GROUP BY source")) ?? [] {
            if let source = row.text("source"), let n = row.int("n") {
                events[source] = Int(n)
            }
        }
        export["event_counts"] = events
        export["distinct_domains"] = distinctDomainCount

        var patterns: [String: Int] = [:]
        for row in (try? db.query("SELECT kind || ':' || state AS k, count(*) AS n FROM pattern GROUP BY kind, state")) ?? [] {
            if let key = row.text("k"), let n = row.int("n") {
                patterns[key] = Int(n)
            }
        }
        export["patterns"] = patterns

        let metrics = allMetrics()
        export["metrics"] = metrics

        // H1: share of surfaced cards the owner confirmed as real.
        let confirmed = metrics["cards_confirmed"] ?? 0
        let dismissed = metrics["cards_dismissed"] ?? 0
        if confirmed + dismissed > 0 {
            export["h1_precision"] = Double(confirmed) / Double(confirmed + dismissed)
        }
        // H3 proxy: days from consent to the first card.
        if let since = observingSince,
           let firstCard = appStateValue("first_card_at").flatMap(Double.init) {
            export["days_to_first_card"] = max(0, Int((firstCard - since.timeIntervalSince1970) / 86400))
        }
        return export
    }

    // MARK: - Exclusions

    func isExcluded(domain: String) -> Bool {
        ExclusionList.isExcluded(domain: domain, userAdded: userExclusions)
    }

    func addUserExclusion(_ domain: String) {
        let normalized = HostDisplay.registrableDomain(of: domain.lowercased())
        userExclusions.insert(normalized)
        try? db.run(
            "INSERT OR REPLACE INTO user_exclusion (domain, added_at) VALUES (?, ?)",
            [.text(normalized), .real(Date().timeIntervalSince1970)]
        )
        // Adding an exclusion also scrubs anything already recorded for it.
        try? db.run("DELETE FROM event WHERE domain = ?", [.text(normalized)])
    }

    // MARK: - Recording (metadata only, PRD §3.1)

    struct Visit {
        let url: URL
        let title: String
        let transition: String
        let workspaceID: String?
        let openDomains: [String]
    }

    func recordVisit(_ visit: Visit) {
        guard isObserving else { return }
        guard let scheme = visit.url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = visit.url.host() else { return }
        // Exclusion is judged on the registrable domain (so a category rule
        // like ".gov.au" or a curated bank domain also catches its
        // subdomains); the *stored* identity keeps the full meaningful host
        // (DisplayNames.observationDomain) so distinct self-hosted services
        // on one personal domain are never merged into one guessed identity.
        guard !isExcluded(domain: HostDisplay.registrableDomain(of: host)) else { return } // no rows, no counts, no hashes
        let domain = DisplayNames.observationDomain(for: host)

        let openDomains = visit.openDomains
            .filter { !isExcluded(domain: HostDisplay.registrableDomain(of: $0)) }
            .map { DisplayNames.observationDomain(for: $0) }
        insertEvent(
            ts: Date().timeIntervalSince1970,
            kind: "visit",
            domain: domain,
            path: visit.url.path(), // query and fragment never touch the schema
            title: String(visit.title.prefix(120)),
            transition: visit.transition,
            workspaceID: visit.workspaceID,
            sessionID: liveSessionID(),
            openDomains: openDomains.isEmpty ? nil : Set(openDomains).sorted().joined(separator: ","),
            source: "live",
            scheme: scheme
        )
    }

    func recordTabEvent(kind: String, workspaceID: String?) {
        guard isObserving else { return }
        insertEvent(
            ts: Date().timeIntervalSince1970,
            kind: kind, domain: nil, path: nil, title: nil, transition: nil,
            workspaceID: workspaceID, sessionID: liveSessionID(),
            openDomains: nil, source: "live", scheme: nil
        )
    }

    /// Import path: same schema, `source: import:<browser>`, exclusions applied
    /// here as well — an excluded visit never becomes a row even from history.
    func recordImportedVisit(
        ts: TimeInterval,
        url: URL,
        title: String?,
        transition: String,
        sourceBrowser: String
    ) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host() else { return false }
        guard !isExcluded(domain: HostDisplay.registrableDomain(of: host)) else { return false }
        let domain = DisplayNames.observationDomain(for: host)
        insertEvent(
            ts: ts, kind: "visit", domain: domain, path: url.path(),
            title: title.map { String($0.prefix(120)) }, transition: transition,
            workspaceID: nil, sessionID: nil,
            openDomains: nil, source: "import:\(sourceBrowser)",
            scheme: scheme
        )
        return true
    }

    func clearImports(from sourceBrowser: String) {
        try? db.run("DELETE FROM event WHERE source = ?", [.text("import:\(sourceBrowser)")])
    }

    func addBookmark(url: String, title: String?, source: String) {
        guard let parsed = URL(string: url), let host = parsed.host() else { return }
        guard !isExcluded(domain: HostDisplay.registrableDomain(of: host)) else { return }
        try? db.run(
            "INSERT OR REPLACE INTO bookmark (url, title, source) VALUES (?,?,?)",
            [.text(url), title.map(Database.Value.text) ?? .null, .text(source)]
        )
    }

    /// Wraps bulk work in one transaction so imports land in seconds.
    func performBulk(_ work: () -> Void) {
        try? db.execute("BEGIN IMMEDIATE")
        work()
        try? db.execute("COMMIT")
    }

    var eventCount: Int {
        Int((try? db.query("SELECT count(*) AS n FROM event").first?.int("n")) ?? 0)
    }

    // MARK: - Internals

    private func liveSessionID() -> String {
        let now = Date()
        if let last = lastEventAt, now.timeIntervalSince(last) > Self.sessionGap {
            currentSessionID = UUID().uuidString
        }
        lastEventAt = now
        return currentSessionID
    }

    private func insertEvent(
        ts: TimeInterval, kind: String, domain: String?, path: String?,
        title: String?, transition: String?, workspaceID: String?,
        sessionID: String?, openDomains: String?, source: String, scheme: String?
    ) {
        try? db.run(
            """
            INSERT INTO event (ts, kind, domain, path, title, transition, workspace_id, session_id, open_domains, source, scheme)
            VALUES (?,?,?,?,?,?,?,?,?,?,?)
            """,
            [
                .real(ts), .text(kind),
                domain.map(Database.Value.text) ?? .null,
                path.map(Database.Value.text) ?? .null,
                title.map(Database.Value.text) ?? .null,
                transition.map(Database.Value.text) ?? .null,
                workspaceID.map(Database.Value.text) ?? .null,
                sessionID.map(Database.Value.text) ?? .null,
                openDomains.map(Database.Value.text) ?? .null,
                .text(source),
                scheme.map(Database.Value.text) ?? .null,
            ]
        )
    }

    // MARK: - Real-URL lookup (never guess — read the actual history)

    /// The most-visited actual URL for a learned domain: real scheme, real
    /// path, drawn from the ledger itself. This is what a confirmed pattern's
    /// workspace opens — never a synthesized `https://domain/`. Falls back to
    /// the bare domain over https only when there's truly nothing recorded
    /// for it (shouldn't happen for a pattern the engine detected from this
    /// same ledger).
    func mostVisitedURL(forDomain domain: String) -> URL? {
        let row = try? db.query("""
            SELECT path, scheme, count(*) AS n, max(ts) AS latest
            FROM event WHERE kind = 'visit' AND domain = ?
            GROUP BY path, scheme
            ORDER BY n DESC, latest DESC
            LIMIT 1
            """, [.text(domain)]).first
        let scheme = row?.text("scheme") ?? "https"
        let path = row?.text("path") ?? ""
        let normalizedPath = path.isEmpty ? "/" : path
        return URL(string: "\(scheme)://\(domain)\(normalizedPath)")
    }
}
