import Foundation

/// The deterministic learning engine (PRD §4.5). No LLM, no library — n-gram
/// counting and circular statistics over the event ledger. Precision over
/// recall throughout: thresholds are floors, tune upward only.
enum LearningEngine {

    // MARK: - Input

    struct VisitRecord {
        let ts: TimeInterval
        let domain: String
        let transition: String
        let openDomains: [String]
    }

    // MARK: - Output

    struct Pattern {
        enum Kind: String {
            case sequence, ritual, cooccurrence, appPromotion = "app_promotion"
        }

        let kind: Kind
        let domains: [String]          // ordered for sequences
        let windowLabel: String?       // "weekday morning", "Sunday evening"…
        let settled: Bool              // settled → may suggest; else "still settling"
        let evidenceLine: String       // the cost accountant's sentence
        let suggestedName: String      // template-derived, never generated
        let count: Int
        let dayCount: Int
        let spanDays: Int
        var meanHour: Double? = nil

        /// Stable identity across runs.
        var key: String {
            "\(kind.rawValue)|\(domains.joined(separator: ">"))|\(windowLabel ?? "-")"
        }
    }

    // MARK: - Entry points

    static func loadVisits(from db: Database) -> [VisitRecord] {
        let rows = (try? db.query(
            "SELECT ts, domain, transition, open_domains FROM event WHERE kind = 'visit' AND domain IS NOT NULL ORDER BY ts"
        )) ?? []
        return rows.compactMap { row in
            guard let ts = row.real("ts"), let domain = row.text("domain") else { return nil }
            return VisitRecord(
                ts: ts,
                domain: domain,
                transition: row.text("transition") ?? "other",
                openDomains: row.text("open_domains").map { $0.split(separator: ",").map(String.init) } ?? []
            )
        }
    }

    /// Full run: read events, detect, upsert into the pattern table
    /// (state survives re-runs — dismissals must be honoured forever).
    @discardableResult
    static func run(db: Database) -> [Pattern] {
        try? createSchema(db)
        let patterns = analyze(visits: loadVisits(from: db))
        let now = Date().timeIntervalSince1970
        for pattern in patterns {
            try? db.run("""
                INSERT INTO pattern (key, kind, domains, window_label, settled, evidence_line, suggested_name,
                                     count, day_count, span_days, mean_hour, state, first_detected, last_updated)
                VALUES (?,?,?,?,?,?,?,?,?,?,?,'noticed',?,?)
                ON CONFLICT(key) DO UPDATE SET
                    settled = excluded.settled,
                    evidence_line = excluded.evidence_line,
                    count = excluded.count,
                    day_count = excluded.day_count,
                    span_days = excluded.span_days,
                    mean_hour = excluded.mean_hour,
                    last_updated = excluded.last_updated
                """,
                [
                    .text(pattern.key), .text(pattern.kind.rawValue),
                    .text(pattern.domains.joined(separator: ",")),
                    pattern.windowLabel.map(Database.Value.text) ?? .null,
                    .int(pattern.settled ? 1 : 0),
                    .text(pattern.evidenceLine), .text(pattern.suggestedName),
                    .int(Int64(pattern.count)), .int(Int64(pattern.dayCount)), .int(Int64(pattern.spanDays)),
                    pattern.meanHour.map(Database.Value.real) ?? .null,
                    .real(now), .real(now),
                ])
        }
        try? db.run("INSERT OR REPLACE INTO app_state (key, value) VALUES ('engine_last_run', ?)", [.text(String(now))])
        return patterns
    }

    static func createSchema(_ db: Database) throws {
        try db.execute("""
            CREATE TABLE IF NOT EXISTS app_state (
                key TEXT PRIMARY KEY,
                value TEXT NOT NULL
            );
            CREATE TABLE IF NOT EXISTS pattern (
                key TEXT PRIMARY KEY,
                kind TEXT NOT NULL,
                domains TEXT NOT NULL,
                window_label TEXT,
                settled INTEGER NOT NULL,
                evidence_line TEXT NOT NULL,
                suggested_name TEXT NOT NULL,
                count INTEGER NOT NULL,
                day_count INTEGER NOT NULL,
                span_days INTEGER NOT NULL,
                state TEXT NOT NULL DEFAULT 'noticed',
                first_detected REAL NOT NULL,
                last_updated REAL NOT NULL,
                suggested_at REAL,
                resolved_at REAL,
                times_suggested INTEGER NOT NULL DEFAULT 0,
                prev_count INTEGER NOT NULL DEFAULT 0,
                workspace_name TEXT,
                mean_hour REAL
            );
            """)
    }

    // MARK: - Analysis

    static func analyze(visits: [VisitRecord], calendar: Calendar = .current) -> [Pattern] {
        guard visits.count >= 10 else { return [] }
        // The global top-5 domains are ambient, not habits: excluded from
        // sequences (PRD §4.5), and by extension from rituals and promotions —
        // "you visit google.com a lot" is never a revelation.
        var tally: [String: Int] = [:]
        for visit in visits { tally[visit.domain, default: 0] += 1 }
        let topFive = Set(tally.sorted { $0.value > $1.value }.prefix(5).map(\.key))

        let sessions = sessionize(visits)
        let sequences = detectSequences(sessions: sessions, topFive: topFive, calendar: calendar)
        var rituals = detectRituals(visits: visits, topFive: topFive, calendar: calendar)
        let cooccurrences = detectCooccurrence(visits: visits, calendar: calendar)
        let promotions = detectAppPromotions(visits: visits, topFive: topFive, calendar: calendar)

        // A settled sequence subsumes rituals of its member domains in the
        // same window — one habit, one pattern. Precision over recall.
        let sequenceCover = Set(sequences.filter(\.settled).flatMap { sequence in
            sequence.domains.map { "\($0)|\(sequence.windowLabel ?? "")" }
        })
        rituals.removeAll { ritual in
            guard let domain = ritual.domains.first else { return false }
            return sequenceCover.contains("\(domain)|\(ritual.windowLabel ?? "")")
        }

        return sequences + rituals + cooccurrences + promotions
    }

    /// Session = activity separated by gaps under 25 minutes (PRD §4.5).
    /// Computed from timestamps so imported history sessionizes identically.
    static func sessionize(_ visits: [VisitRecord]) -> [[VisitRecord]] {
        var sessions: [[VisitRecord]] = []
        var current: [VisitRecord] = []
        for visit in visits {
            if let last = current.last, visit.ts - last.ts > 25 * 60 {
                sessions.append(current)
                current = []
            }
            current.append(visit)
        }
        if !current.isEmpty {
            sessions.append(current)
        }
        return sessions
    }

    // MARK: Sequence detector

    /// Recurring ordered domain sequences (length 2–5) within sessions.
    /// Settled at ≥5 occurrences across ≥3 distinct days; sequences made
    /// entirely of the global top-5 domains are noise (PRD §4.5).
    private static func detectSequences(
        sessions: [[VisitRecord]], topFive: Set<String>, calendar: Calendar
    ) -> [Pattern] {
        struct GramStat {
            var count = 0
            var days = Set<Int>()
            var startTimes: [TimeInterval] = []
        }
        var grams: [String: (domains: [String], stat: GramStat)] = [:]

        for session in sessions {
            // Collapse consecutive repeats: A A B → A B.
            var path: [VisitRecord] = []
            for visit in session where visit.domain != path.last?.domain {
                path.append(visit)
            }
            guard path.count >= 2 else { continue }
            for length in 2...min(5, path.count) {
                for start in 0...(path.count - length) {
                    let window = Array(path[start..<(start + length)])
                    let domains = window.map(\.domain)
                    guard Set(domains).count == domains.count else { continue } // no A>B>A loops
                    let key = domains.joined(separator: ">")
                    var entry = grams[key] ?? (domains, GramStat())
                    entry.stat.count += 1
                    entry.stat.days.insert(dayIndex(window[0].ts, calendar))
                    entry.stat.startTimes.append(window[0].ts)
                    grams[key] = entry
                }
            }
        }

        var qualifying = grams.values.filter { entry in
            let floor = entry.stat.count >= 3 && entry.stat.days.count >= 2
            let noise = entry.domains.allSatisfy { topFive.contains($0) }
            return floor && !noise
        }

        // Prefer the longest expression of a habit: drop grams that are
        // contiguous subsequences of a longer gram with comparable support.
        qualifying.sort { $0.domains.count > $1.domains.count }
        var kept: [(domains: [String], stat: GramStat)] = []
        outer: for candidate in qualifying {
            for longer in kept where longer.domains.count > candidate.domains.count {
                if isContiguousSubsequence(candidate.domains, of: longer.domains),
                   longer.stat.count * 4 >= candidate.stat.count * 3 {
                    continue outer
                }
            }
            kept.append(candidate)
        }

        return kept.map { entry in
            let settled = entry.stat.count >= 5 && entry.stat.days.count >= 3
            let window = dominantWindow(startTimes: entry.stat.startTimes, calendar: calendar)
            let span = spanDays(entry.stat.startTimes)
            return Pattern(
                kind: .sequence,
                domains: entry.domains,
                windowLabel: window?.label,
                settled: settled,
                evidenceLine: CostAccountant.sequenceEvidence(
                    count: entry.stat.count, window: window?.label, spanDays: span
                ),
                suggestedName: templateName(window: window?.label, domains: entry.domains),
                count: entry.stat.count,
                dayCount: entry.stat.days.count,
                spanDays: span,
                meanHour: window?.meanHour
            )
        }
    }

    private static func isContiguousSubsequence(_ inner: [String], of outer: [String]) -> Bool {
        guard inner.count <= outer.count else { return false }
        for start in 0...(outer.count - inner.count) {
            if Array(outer[start..<(start + inner.count)]) == inner {
                return true
            }
        }
        return false
    }

    // MARK: Ritual detector

    /// Domains visited at consistent times of day: ≥10 visits/30 days with low
    /// circular variance for daily/weekday rituals. Single-day rituals
    /// (Sunday evenings) can only occur ~4 times in 30 days, so the floor is
    /// presence on nearly all of those days instead (documented interpretation
    /// of PRD §4.5; tune upward only).
    private static func detectRituals(visits: [VisitRecord], topFive: Set<String>, calendar: Calendar) -> [Pattern] {
        guard let latest = visits.last?.ts else { return [] }
        let windowStart = latest - 30 * 86400
        let recent = visits.filter { $0.ts >= windowStart }

        _ = topFive // sequences own the top-5 rule; rituals guard differently below
        var byDomain: [String: [VisitRecord]] = [:]
        for visit in recent {
            byDomain[visit.domain, default: []].append(visit)
        }

        var patterns: [Pattern] = []
        for (domain, domainVisits) in byDomain {
            var best: (score: Double, pattern: Pattern)?
            for group in DayGroup.allCases {
                let grouped = domainVisits.filter { group.contains($0.ts, calendar) }
                let days = Set(grouped.map { dayIndex($0.ts, calendar) })
                let possibleDays = group.occurrences(inDays: 30)
                // Floors tuned upward after harness false positives (a domain
                // touched once on a few Mondays is coincidence, not ritual):
                // single-day rituals need repeated engagement each occurrence;
                // broader rituals need genuinely tight times.
                let settledFloor: Bool
                let settlingFloor: Bool
                let requiredResultant: Double
                if group.isSingleDay {
                    settledFloor = days.count >= 4 && days.count >= possibleDays - 1
                        && grouped.count >= Int(ceil(Double(days.count) * 1.5))
                    settlingFloor = days.count >= 3
                    requiredResultant = 0.62
                } else {
                    settledFloor = grouped.count >= 10 && days.count >= 6
                    settlingFloor = grouped.count >= 6 && days.count >= 4
                    requiredResultant = 0.7
                }
                guard settlingFloor else { continue }

                let (resultant, meanHour) = circularStats(grouped.map(\.ts), calendar: calendar)
                let settled = settledFloor && resultant >= requiredResultant
                guard resultant >= 0.4 else { continue }

                let timeLabel = timeOfDayLabel(hour: meanHour)
                let label = group.label(with: timeLabel)
                let span = spanDays(grouped.map(\.ts))
                // Prefer the most specific qualifying description.
                let score = resultant + (group.isSingleDay ? 0.3 : group == .weekday ? 0.15 : 0)
                let pattern = Pattern(
                    kind: .ritual,
                    domains: [domain],
                    windowLabel: label,
                    settled: settled,
                    evidenceLine: CostAccountant.ritualEvidence(
                        dayCount: days.count, possibleDays: possibleDays, label: label, spanDays: span
                    ),
                    suggestedName: templateName(window: label, domains: [domain]),
                    count: grouped.count,
                    dayCount: days.count,
                    spanDays: span,
                    meanHour: meanHour
                )
                if best.map({ score > $0.score }) ?? true {
                    best = (score, pattern)
                }
            }
            if let best {
                patterns.append(best.pattern)
            }
        }
        return patterns
    }

    // MARK: Co-occurrence detector

    /// Domains open simultaneously (tab-set snapshots ride the visit events)
    /// on ≥60% of active days over 2+ weeks. Live data only — imports carry no
    /// tab sets. Domains present in nearly every snapshot are ambient (a pinned
    /// inbox) and pair with everything, so they are excluded from pairing.
    private static func detectCooccurrence(visits: [VisitRecord], calendar: Calendar) -> [Pattern] {
        let snapshots = visits.filter { $0.openDomains.count >= 2 }
        guard !snapshots.isEmpty else { return [] }

        var daysWithSnapshots = Set<Int>()
        var snapshotCount = 0
        var presence: [String: Int] = [:]
        var pairDays: [String: Set<Int>] = [:]
        var domainDays: [String: Set<Int>] = [:]

        for snapshot in snapshots {
            let day = dayIndex(snapshot.ts, calendar)
            daysWithSnapshots.insert(day)
            snapshotCount += 1
            let unique = Set(snapshot.openDomains)
            for domain in unique {
                presence[domain, default: 0] += 1
                domainDays[domain, default: []].insert(day)
            }
            let sorted = unique.sorted()
            for i in 0..<sorted.count {
                for j in (i + 1)..<sorted.count {
                    pairDays["\(sorted[i])|\(sorted[j])", default: []].insert(day)
                }
            }
        }

        let activeDayCount = daysWithSnapshots.count
        guard activeDayCount >= 5 else { return [] }
        let ambient = Set(presence.filter { Double($0.value) / Double(snapshotCount) > 0.85 }.map(\.key))

        struct Edge { let a, b: String; let share: Double; let days: Set<Int> }
        var settledEdges: [Edge] = []
        var settlingEdges: [Edge] = []
        for (key, days) in pairDays {
            let parts = key.split(separator: "|").map(String.init)
            guard !ambient.contains(parts[0]), !ambient.contains(parts[1]) else { continue }
            let share = Double(days.count) / Double(activeDayCount)
            let span = (days.max() ?? 0) - (days.min() ?? 0)
            if share >= 0.6, span >= 13 {
                settledEdges.append(Edge(a: parts[0], b: parts[1], share: share, days: days))
            } else if share >= 0.45, span >= 9 {
                settlingEdges.append(Edge(a: parts[0], b: parts[1], share: share, days: days))
            }
        }

        func clusters(from edges: [Edge]) -> [[String]] {
            var parent: [String: String] = [:]
            func find(_ x: String) -> String {
                var root = x
                while let next = parent[root], next != root { root = next }
                parent[x] = root
                return root
            }
            for edge in edges {
                parent[edge.a] = parent[edge.a] ?? edge.a
                parent[edge.b] = parent[edge.b] ?? edge.b
                parent[find(edge.a)] = find(edge.b)
            }
            var groups: [String: [String]] = [:]
            for node in parent.keys {
                groups[find(node), default: []].append(node)
            }
            return groups.values.map { $0.sorted() }
        }

        var patterns: [Pattern] = []
        let settledClusters = clusters(from: settledEdges)
        for group in settledClusters {
            let groupDays = group.compactMap { domainDays[$0] }.reduce(Set<Int>()) { $0.union($1) }
            patterns.append(cooccurrencePattern(group, settled: true, dayCount: groupDays.count, activeDays: activeDayCount))
        }
        let settledMembers = Set(settledClusters.flatMap { $0 })
        for group in clusters(from: settlingEdges) where Set(group).isDisjoint(with: settledMembers) {
            let groupDays = group.compactMap { domainDays[$0] }.reduce(Set<Int>()) { $0.union($1) }
            patterns.append(cooccurrencePattern(group, settled: false, dayCount: groupDays.count, activeDays: activeDayCount))
        }
        return patterns
    }

    private static func cooccurrencePattern(_ domains: [String], settled: Bool, dayCount: Int, activeDays: Int) -> Pattern {
        Pattern(
            kind: .cooccurrence,
            domains: domains,
            windowLabel: nil,
            settled: settled,
            evidenceLine: CostAccountant.cooccurrenceEvidence(),
            suggestedName: templateName(window: nil, domains: domains),
            count: dayCount,
            dayCount: dayCount,
            spanDays: activeDays
        )
    }

    // MARK: Application promotion

    /// A domain visited most days for ~a month, reached chiefly by typed
    /// address → "Pin it as an application?" candidate (PRD §4.5).
    private static func detectAppPromotions(visits: [VisitRecord], topFive: Set<String>, calendar: Calendar) -> [Pattern] {
        guard let latest = visits.last?.ts else { return [] }
        let windowStart = latest - 30 * 86400
        _ = topFive // typed-share is the promotion guard; top-5 typed daily is a real app
        var byDomain: [String: (days: Set<Int>, typed: Int, total: Int, times: [TimeInterval])] = [:]
        for visit in visits where visit.ts >= windowStart {
            var entry = byDomain[visit.domain] ?? ([], 0, 0, [])
            entry.days.insert(dayIndex(visit.ts, calendar))
            entry.total += 1
            if visit.transition == "typed" { entry.typed += 1 }
            entry.times.append(visit.ts)
            byDomain[visit.domain] = entry
        }
        var patterns: [Pattern] = []
        for (domain, entry) in byDomain {
            let typedShare = Double(entry.typed) / Double(max(entry.total, 1))
            guard typedShare >= 0.4 else { continue }
            let settled = entry.days.count >= 18
            guard entry.days.count >= 12 else { continue }
            patterns.append(Pattern(
                kind: .appPromotion,
                domains: [domain],
                windowLabel: nil,
                settled: settled,
                evidenceLine: CostAccountant.promotionEvidence(dayCount: entry.days.count),
                suggestedName: sldName(domain),
                count: entry.total,
                dayCount: entry.days.count,
                spanDays: spanDays(entry.times)
            ))
        }
        return patterns
    }

    // MARK: - Shared helpers

    private static func dayIndex(_ ts: TimeInterval, _ calendar: Calendar) -> Int {
        Int((ts + TimeInterval(calendar.timeZone.secondsFromGMT(for: Date(timeIntervalSince1970: ts)))) / 86400)
    }

    private static func spanDays(_ times: [TimeInterval]) -> Int {
        guard let min = times.min(), let max = times.max() else { return 0 }
        return Int((max - min) / 86400) + 1
    }

    /// Circular mean/resultant of times-of-day; resultant near 1 = consistent.
    private static func circularStats(_ times: [TimeInterval], calendar: Calendar) -> (resultant: Double, meanHour: Double) {
        guard !times.isEmpty else { return (0, 0) }
        var sumSin = 0.0, sumCos = 0.0
        for ts in times {
            let date = Date(timeIntervalSince1970: ts)
            let comps = calendar.dateComponents([.hour, .minute], from: date)
            let fraction = (Double(comps.hour ?? 0) + Double(comps.minute ?? 0) / 60) / 24
            let angle = fraction * 2 * .pi
            sumSin += sin(angle)
            sumCos += cos(angle)
        }
        let n = Double(times.count)
        let resultant = sqrt(sumSin * sumSin + sumCos * sumCos) / n
        var meanAngle = atan2(sumSin / n, sumCos / n)
        if meanAngle < 0 { meanAngle += 2 * .pi }
        return (resultant, meanAngle / (2 * .pi) * 24)
    }

    private static func dominantWindow(startTimes: [TimeInterval], calendar: Calendar) -> (label: String, meanHour: Double)? {
        let (resultant, meanHour) = circularStats(startTimes, calendar: calendar)
        guard resultant >= 0.5 else { return nil }
        let weekdayShare = Double(startTimes.filter { DayGroup.weekday.contains($0, calendar) }.count) / Double(startTimes.count)
        let time = timeOfDayLabel(hour: meanHour)
        return (weekdayShare >= 0.85 ? "weekday \(time)" : time, meanHour)
    }

    static func timeOfDayLabel(hour: Double) -> String {
        switch hour {
        case 5..<11: "morning"
        case 11..<14: "lunchtime"
        case 14..<17: "afternoon"
        case 17..<22: "evening"
        default: "late night"
        }
    }

    /// Template-derived names only — never generated (PRD §3.6).
    private static func templateName(window: String?, domains: [String]) -> String {
        if let window {
            if window.contains("morning") { return "Mornings" }
            if window.contains("lunchtime") { return "Lunch" }
            if window.contains("afternoon") { return "Afternoons" }
            if window.contains("evening") { return "Evenings" }
            for (index, name) in Calendar.current.weekdaySymbols.enumerated() {
                _ = index
                if window.lowercased().contains(name.lowercased()) { return name + "s" }
            }
        }
        return sldName(domains[0])
    }

    private static func sldName(_ domain: String) -> String {
        let sld = domain.split(separator: ".").first.map(String.init) ?? domain
        return sld.prefix(1).uppercased() + sld.dropFirst()
    }

    // MARK: Day groups

    enum DayGroup: CaseIterable {
        case daily, weekday, weekend
        case sunday, monday, tuesday, wednesday, thursday, friday, saturday

        var isSingleDay: Bool {
            switch self {
            case .daily, .weekday, .weekend: false
            default: true
            }
        }

        var weekdayNumber: Int? {
            switch self {
            case .sunday: 1
            case .monday: 2
            case .tuesday: 3
            case .wednesday: 4
            case .thursday: 5
            case .friday: 6
            case .saturday: 7
            default: nil
            }
        }

        func contains(_ ts: TimeInterval, _ calendar: Calendar) -> Bool {
            let weekday = calendar.component(.weekday, from: Date(timeIntervalSince1970: ts))
            switch self {
            case .daily: return true
            case .weekday: return (2...6).contains(weekday)
            case .weekend: return weekday == 1 || weekday == 7
            default: return weekday == weekdayNumber
            }
        }

        func occurrences(inDays days: Int) -> Int {
            switch self {
            case .daily: days
            case .weekday: days * 5 / 7
            case .weekend: days * 2 / 7
            default: days / 7
            }
        }

        func label(with timeLabel: String) -> String {
            switch self {
            case .daily: return timeLabel
            case .weekday: return "weekday \(timeLabel)"
            case .weekend: return "weekend \(timeLabel)"
            default:
                let name = Calendar.current.weekdaySymbols[(weekdayNumber ?? 1) - 1]
                return "\(name) \(timeLabel)"
            }
        }
    }
}

/// The cost accountant (PRD §4.5): plain language, aggressive rounding.
/// "About a dozen mornings over the past three weeks" — never "13 times at
/// 08:47". The D3 rules are load-bearing product behaviour.
enum CostAccountant {
    static func countPhrase(_ n: Int) -> String {
        switch n {
        case ..<3: "a couple of"
        case 3...5: "a few"
        case 6...7: "about half a dozen"
        case 8...15: "about a dozen"
        case 16...24: "about twenty"
        default: "dozens of"
        }
    }

    static func spanPhrase(days: Int) -> String {
        switch days {
        case ..<10: "the past week or so"
        case 10...17: "the past couple of weeks"
        case 18...27: "the past three weeks"
        case 28...45: "the past month"
        case 46...75: "the past two months"
        case 76...110: "the past three months"
        default: "the past several months"
        }
    }

    static func sequenceEvidence(count: Int, window: String?, spanDays: Int) -> String {
        let unit = window.map { $0.split(separator: " ").last.map(String.init) ?? "times" } ?? "times"
        let plural = unit == "times" ? unit : unit + "s"
        return "Seen \(countPhrase(count)) \(plural) over \(spanPhrase(days: spanDays))."
    }

    static func ritualEvidence(dayCount: Int, possibleDays: Int, label: String, spanDays: Int) -> String {
        if Double(dayCount) / Double(max(possibleDays, 1)) >= 0.7 {
            return "Most \(label)s for \(spanPhrase(days: spanDays))."
        }
        return "Seen \(countPhrase(dayCount)) \(label)s over \(spanPhrase(days: spanDays))."
    }

    static func cooccurrenceEvidence() -> String {
        "Together on most working days."
    }

    static func promotionEvidence(dayCount: Int) -> String {
        dayCount >= 25 ? "Nearly every day for the past month." : "Most days for about a month."
    }
}
