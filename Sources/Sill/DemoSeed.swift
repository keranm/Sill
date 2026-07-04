import Foundation

/// Synthetic 30-day history: 4 planted routines + realistic noise (PRD §4.9).
/// One generator, two jobs: the M4 detection harness (`--selftest`) and the
/// demo flag (`--demo-seed`, separate database — never mixed with real data).
enum DemoSeed {

    /// Deterministic RNG so the harness is reproducible.
    struct SplitMix64: RandomNumberGenerator {
        var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func next() -> UInt64 {
            state &+= 0x9E3779B97F4A7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            return z ^ (z >> 31)
        }
    }

    // The four planted routines the detectors must find:
    static let plantedSequence = ["mail.google.com", "calendar.google.com", "figma.com"]
    static let plantedRitualDomain = "allrecipes.com"          // Sunday evenings
    static let plantedCluster = ["linear.app", "github.com", "staging.acme.dev"]
    static let plantedApplication = "notion.so"                 // typed, most days

    private static let noiseDomains: [String] = [
        "wikipedia.org", "stackoverflow.com", "medium.com", "dev.to", "vercel.com",
        "netlify.com", "aws.amazon.com", "cloudflare.com", "npmjs.com", "swift.org",
        "apple.com", "arstechnica.com", "theverge.com", "smh.com.au", "abc.net.au",
        "bom.gov.au", "openweathermap.org", "spotify.com", "bandcamp.com", "twitch.tv",
        "etsy.com", "ebay.com.au", "amazon.com.au", "bunnings.com.au", "jbhifi.com.au",
        "gumtree.com.au", "realestate.com.au", "domain.com.au", "seek.com.au",
        "canva.com", "dribbble.com", "unsplash.com", "fonts.google.com", "codepen.io",
    ]
    /// Heavy hitters so the global top-5 is noise, exercising the
    /// top-5-sequence exclusion rule.
    private static let heavyNoise = ["google.com", "youtube.com", "reddit.com", "news.com.au", "x.com"]

    static func generateVisits(seed: UInt64 = 42, days: Int = 30, endingAt end: Date = Date()) -> [LearningEngine.VisitRecord] {
        var rng = SplitMix64(seed: seed)
        var visits: [LearningEngine.VisitRecord] = []
        let calendar = Calendar.current

        func minute(_ base: Double, jitter: Double) -> TimeInterval {
            (base + Double.random(in: -jitter...jitter, using: &rng)) * 60
        }

        for dayOffset in stride(from: days - 1, through: 0, by: -1) {
            guard let dayStart = calendar.date(byAdding: .day, value: -dayOffset, to: calendar.startOfDay(for: end)) else { continue }
            let startTS = dayStart.timeIntervalSince1970
            let weekday = calendar.component(.weekday, from: dayStart)
            let isWeekday = (2...6).contains(weekday)

            var ambientTabs = Array(noiseDomains.shuffled(using: &rng).prefix(3))

            func emit(_ domain: String, _ ts: TimeInterval, transition: String = "link", extraOpen: [String] = []) {
                visits.append(.init(
                    ts: ts, domain: domain, transition: transition,
                    openDomains: Array(Set(ambientTabs + extraOpen + [domain]))
                ))
            }

            // Routine 1 — weekday-morning sequence, ~08:30, 80% of weekdays.
            if isWeekday, Double.random(in: 0...1, using: &rng) < 0.8 {
                var t = startTS + minute(8 * 60 + 30, jitter: 35)
                for domain in plantedSequence {
                    emit(domain, t)
                    t += Double.random(in: 40...240, using: &rng)
                }
            }

            // Routine 2 — Sunday-evening recipes, ~19:00, every Sunday.
            if weekday == 1 {
                let t = startTS + minute(19 * 60, jitter: 40)
                emit(plantedRitualDomain, t)
                emit(plantedRitualDomain, t + Double.random(in: 300...900, using: &rng))
            }

            // Routine 3 — the work cluster open together on every weekday.
            if isWeekday {
                let sessionStart = startTS + minute(10 * 60, jitter: 60)
                for hop in 0..<Int.random(in: 3...6, using: &rng) {
                    let domain = plantedCluster.randomElement(using: &rng)!
                    emit(domain, sessionStart + Double(hop) * Double.random(in: 300...1200, using: &rng),
                         extraOpen: plantedCluster)
                }
            }

            // Routine 4 — notion.so typed, ~75% of all days.
            if Double.random(in: 0...1, using: &rng) < 0.75 {
                emit(plantedApplication, startTS + minute(Double.random(in: 9...21, using: &rng) * 60, jitter: 30),
                     transition: "typed")
            }

            // Noise: 6–14 scattered visits, plus the heavy hitters.
            for _ in 0..<Int.random(in: 6...14, using: &rng) {
                let pool = Double.random(in: 0...1, using: &rng) < 0.35 ? heavyNoise : noiseDomains
                let domain = pool.randomElement(using: &rng)!
                let t = startTS + Double.random(in: 7...23, using: &rng) * 3600
                emit(domain, t, transition: Double.random(in: 0...1, using: &rng) < 0.08 ? "typed" : "link")
                if Double.random(in: 0...1, using: &rng) < 0.3 {
                    ambientTabs = Array(noiseDomains.shuffled(using: &rng).prefix(3))
                }
            }
        }

        return visits.sorted { $0.ts < $1.ts }
    }

    // MARK: - The demo flag (separate database, PRD §4.9)

    static var isActive: Bool {
        CommandLine.arguments.contains("--demo-seed")
    }

    static var databasePathOverride: String? {
        guard isActive else { return nil }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Sill", isDirectory: true)
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        let path = support.appendingPathComponent("sill-demo.sqlite").path
        try? FileManager.default.removeItem(atPath: path)
        try? FileManager.default.removeItem(atPath: path + "-wal")
        try? FileManager.default.removeItem(atPath: path + "-shm")
        return path
    }

    /// Populates the demo database and runs the engine so the whole
    /// card→confirm→workspace flow can be sense-checked on day one.
    @MainActor
    static func startIfRequested(store: TabStore) {
        guard isActive else { return }
        store.observations.recordConsent(true)
        let visits = generateVisits()
        store.observations.performBulk {
            for visit in visits {
                _ = store.observations.recordImportedVisit(
                    ts: visit.ts, url: URL(string: "https://\(visit.domain)/")!,
                    title: nil, transition: visit.transition, sourceBrowser: "demo"
                )
            }
        }
        // The importer path drops open-tab sets; restore them for co-occurrence.
        store.observations.performBulk {
            for visit in visits where !visit.openDomains.isEmpty {
                try? store.database.run(
                    "UPDATE event SET open_domains = ? WHERE ts = ? AND domain = ?",
                    [.text(visit.openDomains.sorted().joined(separator: ",")), .real(visit.ts), .text(visit.domain)]
                )
            }
        }
        let patterns = LearningEngine.run(db: store.database)
        NSLog("Sill demo seed: \(visits.count) visits, \(patterns.count) patterns (\(patterns.filter(\.settled).count) settled)")
    }
}
