import Foundation
import Observation

/// Suggestion lifecycle (PRD §4.6): global cap of two cards, at most one new
/// card per day, 14-day silent withdrawal, one return after a 30-day cooldown
/// with stronger evidence, never a third time. Dismissal is honoured forever;
/// undo lives only on the Learning page.
@MainActor
@Observable
final class PatternStore {

    struct PatternRow: Identifiable {
        let key: String
        let kind: LearningEngine.Pattern.Kind
        let domains: [String]
        let windowLabel: String?
        let settled: Bool
        let evidenceLine: String
        let suggestedName: String
        let count: Int
        let meanHour: Double?
        let state: String
        let suggestedAt: Double?
        let resolvedAt: Double?
        let timesSuggested: Int
        let firstDetected: Double
        let workspaceName: String?

        var id: String { key }
    }

    private(set) var suggestions: [PatternRow] = []      // the (≤2) live cards
    private(set) var noticedSettled: [PatternRow] = []   // Learning page: noticed so far
    private(set) var stillSettling: [PatternRow] = []
    private(set) var outcomes: [PatternRow] = []         // suggestions made: confirmed/dismissed/withdrawn
    private(set) var confirmedApplications: [PatternRow] = []

    @ObservationIgnored private let db: Database
    @ObservationIgnored private unowned let tabStore: TabStore

    init(db: Database, tabStore: TabStore) {
        self.db = db
        self.tabStore = tabStore
        try? LearningEngine.createSchema(db)
        migrateColumns()
        refresh()
    }

    private func migrateColumns() {
        for column in [
            "suggested_at REAL", "resolved_at REAL",
            "times_suggested INTEGER NOT NULL DEFAULT 0",
            "prev_count INTEGER NOT NULL DEFAULT 0",
            "workspace_name TEXT", "mean_hour REAL",
        ] {
            try? db.execute("ALTER TABLE pattern ADD COLUMN \(column)")
        }
    }

    // MARK: - Lifecycle

    func refresh() {
        let now = Date().timeIntervalSince1970

        // 14 days unanswered → withdraws silently (recorded on the Learning page).
        try? db.run("""
            UPDATE pattern SET state = 'withdrawn', resolved_at = ?
            WHERE state = 'suggested' AND suggested_at < ?
            """, [.real(now), .real(now - 14 * 86400)])

        promoteIfDue(now: now)
        reload()
    }

    /// At most one new card surfaces per day (the demo seed may burst to fill
    /// both slots so the flow can be sense-checked on day one, PRD §4.9).
    private func promoteIfDue(now: Double) {
        let live = (try? db.query("SELECT count(*) AS n FROM pattern WHERE state = 'suggested'").first?.int("n")) ?? 0
        guard live < 2 else { return }

        let today = Self.dayStamp(now)
        let lastCardDay = (try? db.query("SELECT value FROM app_state WHERE key = 'last_card_day'").first?.text("value"))
        let allowance = DemoSeed.isActive ? 2 - Int(live ?? 0) : (lastCardDay == today ? 0 : 1)
        guard allowance > 0 else { return }

        // Candidates: settled + noticed, or withdrawn once, cooled 30 days,
        // with meaningfully stronger evidence. Never a third time.
        let rows = (try? db.query("""
            SELECT * FROM pattern
            WHERE settled = 1 AND (
                state = 'noticed'
                OR (state = 'withdrawn' AND times_suggested = 1
                    AND resolved_at < ? AND count >= prev_count + 3)
            )
            """, [.real(now - 30 * 86400)])) ?? []

        let priority: [LearningEngine.Pattern.Kind: Int] = [
            .sequence: 4, .cooccurrence: 3, .appPromotion: 2, .ritual: 1,
        ]
        let candidates = rows.compactMap(Self.row(from:)).sorted {
            (priority[$0.kind] ?? 0, $0.count) > (priority[$1.kind] ?? 0, $1.count)
        }

        for candidate in candidates.prefix(allowance) {
            try? db.run("""
                UPDATE pattern SET state = 'suggested', suggested_at = ?,
                    times_suggested = times_suggested + 1, prev_count = count
                WHERE key = ?
                """, [.real(now), .text(candidate.key)])
            try? db.run("INSERT OR REPLACE INTO app_state (key, value) VALUES ('last_card_day', ?)", [.text(today)])
            if (try? db.query("SELECT value FROM app_state WHERE key = 'first_card_at'").first) == nil {
                try? db.run("INSERT OR REPLACE INTO app_state (key, value) VALUES ('first_card_at', ?)", [.text(String(now))])
            }
            tabStore.observations.incrementMetric("cards_surfaced")
        }
    }

    private func reload() {
        let rows = ((try? db.query("SELECT * FROM pattern")) ?? []).compactMap(Self.row(from:))
        suggestions = rows.filter { $0.state == "suggested" }
            .sorted { ($0.suggestedAt ?? 0) < ($1.suggestedAt ?? 0) }
        noticedSettled = rows.filter { $0.settled && ["noticed", "suggested"].contains($0.state) }
            .sorted { $0.count > $1.count }
        stillSettling = rows.filter { !$0.settled && $0.state == "noticed" }
            .sorted { $0.count > $1.count }
        outcomes = rows.filter { ["confirmed", "dismissed", "withdrawn"].contains($0.state) }
            .sorted { ($0.resolvedAt ?? 0) > ($1.resolvedAt ?? 0) }
        confirmedApplications = rows.filter { $0.kind == .appPromotion && $0.state == "confirmed" }
    }

    // MARK: - Actions

    /// Confirm births the workspace (the one sanctioned action, PRD §3.5) or
    /// pins the application. `surprised` feeds H2.
    func confirm(_ pattern: PatternRow, name: String, surprised: Bool) {
        let now = Date().timeIntervalSince1970
        let finalName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        try? db.run("""
            UPDATE pattern SET state = 'confirmed', resolved_at = ?, workspace_name = ?
            WHERE key = ?
            """, [.real(now), .text(finalName.isEmpty ? pattern.suggestedName : finalName), .text(pattern.key)])
        tabStore.observations.incrementMetric("cards_confirmed")
        if surprised {
            tabStore.observations.incrementMetric("surprised")
        }
        if pattern.kind != .appPromotion {
            // The real, most-visited URL per domain — never a guessed
            // "https://domain/". For a self-hosted service this is the
            // difference between opening the owner's own instance and
            // opening an unrelated public site that happens to share a name.
            let urls = pattern.domains.compactMap { tabStore.observations.mostVisitedURL(forDomain: $0) }
            let payoff = payoffLine(for: pattern)
            Task {
                await tabStore.birthWorkspace(
                    named: finalName.isEmpty ? pattern.suggestedName : finalName,
                    urls: urls,
                    payoff: payoff
                )
            }
        }
        reload()
    }

    /// 120 ms fade at the surface; here it's permanent suppression.
    func dismiss(_ pattern: PatternRow) {
        try? db.run("UPDATE pattern SET state = 'dismissed', resolved_at = ? WHERE key = ?",
                    [.real(Date().timeIntervalSince1970), .text(pattern.key)])
        tabStore.observations.incrementMetric("cards_dismissed")
        reload()
    }

    /// Learning page: per-item forget — the pattern is gone and stays gone
    /// (the engine's upsert never resurrects a non-noticed state).
    func forget(_ pattern: PatternRow) {
        try? db.run("UPDATE pattern SET state = 'forgotten' WHERE key = ?", [.text(pattern.key)])
        reload()
    }

    /// Undo, Learning page only: dismissal reverses to noticed.
    func undoDismiss(_ pattern: PatternRow) {
        try? db.run("UPDATE pattern SET state = 'noticed', resolved_at = NULL WHERE key = ?", [.text(pattern.key)])
        reload()
    }

    // MARK: - Card copy (every line checkable against D3)

    func observationLine(for pattern: PatternRow) -> String {
        let names = pattern.domains.map(DisplayNames.displayName(for:))
        switch pattern.kind {
        case .sequence:
            let chain = names.count == 2
                ? "\(names[0]), then \(names[1])"
                : names.dropLast().joined(separator: ", then ") + ", then " + names.last!
            var line = "Most \(pattern.windowLabel ?? "day")s here start with \(chain)"
            if let hour = beforeHourWord(pattern) {
                line += " — usually before \(hour)"
            }
            return line + "."
        case .ritual:
            return "\(names[0]) comes up most \(pattern.windowLabel ?? "day")s."
        case .cooccurrence:
            let anchor = names.first!
            let rest = Array(names.dropFirst())
            let others = rest.count == 1 ? "\(rest[0]) is" : DisplayNames.list(Array(pattern.domains.dropFirst())) + " are"
            return "When \(anchor) is open, \(others) usually open with it."
        case .appPromotion:
            return "\(names[0]) gets opened here most days, usually by typing the address."
        }
    }

    func actionQuestion(for pattern: PatternRow) -> String {
        switch pattern.kind {
        case .appPromotion: "Pin it as an application?"
        case .cooccurrence: "Want these grouped as a workspace?"
        default: "Want this as a workspace?"
        }
    }

    /// One tap, inline, no modal — same facts the Learning page holds.
    func whyText(for pattern: PatternRow) -> String {
        let basis = switch pattern.kind {
        case .sequence: "the order sites were opened on \(pattern.windowLabel ?? "recent day")s"
        case .ritual: "when this site tends to come up"
        case .cooccurrence: "which sites are open at the same time"
        case .appPromotion: "how often this address gets typed directly"
        }
        return "This comes from \(basis) — nothing about what was on the pages. It's recorded on this Mac and listed on the Learning page. Dismissing this suggestion also forgets the pattern."
    }

    func namingIntro(for pattern: PatternRow) -> String {
        let list = DisplayNames.list(pattern.domains)
        if let window = pattern.windowLabel {
            return "\(list) — \(window)s."
        }
        return "\(list)."
    }

    func payoffLine(for pattern: PatternRow) -> String {
        let list = DisplayNames.list(pattern.domains)
        let when: String = {
            guard let window = pattern.windowLabel else { return "Next time," }
            if window.contains("morning") { return "Tomorrow morning" }
            if window.contains("evening") { return window.contains("Sunday") ? "Next Sunday evening" : "Tomorrow evening" }
            for day in Calendar.current.weekdaySymbols where window.contains(day) {
                return "Next \(day)"
            }
            return "Next time,"
        }()
        return "\(list) \(pattern.domains.count == 1 ? "is" : "are") here. \(when) this is one click."
    }

    /// Learning-page description ("A weekday-morning routine — Mail, Calendar, Figma").
    func ledgerLine(for pattern: PatternRow) -> String {
        let names = pattern.domains.map(DisplayNames.displayName(for:))
        switch pattern.kind {
        case .sequence:
            return "A \(pattern.windowLabel ?? "recurring") routine — \(names.joined(separator: ", "))"
        case .ritual:
            return "\(names[0]), most \(pattern.windowLabel ?? "day")s"
        case .cooccurrence:
            return "\(names.joined(separator: ", ")) open together"
        case .appPromotion:
            return "\(names[0]) opened most days, usually by typed address"
        }
    }

    private func beforeHourWord(_ pattern: PatternRow) -> String? {
        guard let meanHour = pattern.meanHour else { return nil }
        let hour = Int(ceil(meanHour + 0.5))
        let words = ["midnight", "one", "two", "three", "four", "five", "six", "seven", "eight",
                     "nine", "ten", "eleven", "noon"]
        let clock = hour % 24
        let index = clock <= 12 ? clock : clock - 12
        guard words.indices.contains(index) else { return nil }
        return words[index]
    }

    // MARK: - Row mapping

    private static func row(from dbRow: Database.Row) -> PatternRow? {
        guard let key = dbRow.text("key"),
              let kindRaw = dbRow.text("kind"),
              let kind = LearningEngine.Pattern.Kind(rawValue: kindRaw),
              let domainsRaw = dbRow.text("domains"),
              let state = dbRow.text("state") else { return nil }
        return PatternRow(
            key: key,
            kind: kind,
            domains: domainsRaw.split(separator: ",").map(String.init),
            windowLabel: dbRow.text("window_label"),
            settled: dbRow.int("settled") == 1,
            evidenceLine: dbRow.text("evidence_line") ?? "",
            suggestedName: dbRow.text("suggested_name") ?? "Workspace",
            count: Int(dbRow.int("count") ?? 0),
            meanHour: dbRow.real("mean_hour"),
            state: state,
            suggestedAt: dbRow.real("suggested_at"),
            resolvedAt: dbRow.real("resolved_at"),
            timesSuggested: Int(dbRow.int("times_suggested") ?? 0),
            firstDetected: dbRow.real("first_detected") ?? 0,
            workspaceName: dbRow.text("workspace_name")
        )
    }

    private static func dayStamp(_ ts: Double) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date(timeIntervalSince1970: ts))
    }
}
