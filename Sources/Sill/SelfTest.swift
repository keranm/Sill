import Foundation

/// `Sill --selftest` runs headless checks and exits non-zero on failure.
/// Grows with the milestones (M4's detector harness will hang off this).
enum SelfTest {
    @MainActor
    static func runIfRequested() {
        guard CommandLine.arguments.contains("--selftest") else { return }
        var failures: [String] = []

        func expect(_ condition: Bool, _ label: String) {
            if !condition { failures.append(label) }
        }

        // Punycode (RFC 3492)
        expect(Punycode.decode("mnchen-3ya") == "münchen", "punycode münchen")
        expect(Punycode.decode("bcher-kva") == "bücher", "punycode bücher")
        expect(Punycode.decode("p1ai") == "рф", "punycode рф TLD")

        // Homoglyph policy: single-script IDN renders unicode…
        expect(HostDisplay.displayHost("xn--mnchen-3ya.de") == "münchen.de", "single-script latin IDN shows unicode")
        // …mixed-script lookalikes stay punycode ("аpple": Cyrillic а + Latin pple)
        expect(HostDisplay.displayHost("xn--pple-43d.com") == "xn--pple-43d.com", "mixed-script lookalike stays punycode")
        // Pure-Cyrillic label is single-script, allowed
        expect(HostDisplay.displayHost("xn--e1afmkfd.xn--p1ai") == "пример.рф", "cyrillic host decodes")
        // Plain ASCII untouched
        expect(HostDisplay.displayHost("github.com") == "github.com", "ascii host untouched")

        // Registrable domain
        expect(HostDisplay.registrableDomain(of: "docs.github.com") == "github.com", "eTLD+1 basic")
        expect(HostDisplay.registrableDomain(of: "www.bbc.co.uk") == "bbc.co.uk", "eTLD+1 co.uk")
        expect(HostDisplay.registrableDomain(of: "localhost") == "localhost", "single label passes through")
        expect(HostDisplay.registrableDomain(of: "192.168.1.10") == "192.168.1.10", "IP passes through")

        // Path-or-title rule (≤40 chars, human-readable)
        expect(HostDisplay.pathIsShowable("/pricing"), "short path shows")
        expect(!HostDisplay.pathIsShowable("/d/1aZ9k2fj39FJ39fjAKD93kfj39DKFJ3kd93"), "ID-shaped slug hides")
        expect(!HostDisplay.pathIsShowable("/watch/123456789012"), "long digit run hides")
        expect(!HostDisplay.pathIsShowable("/a%20b"), "percent-encoded hides")

        // Address parsing
        expect(TabStore.destination(for: "github.com")?.absoluteString == "https://github.com", "bare domain gets https")
        expect(TabStore.destination(for: "what is a sill")?.host() == "www.google.com", "words become search")
        expect(TabStore.destination(for: "http://example.com")?.scheme == "http", "explicit http kept")

        // Exclusion rules (PRD §3.3)
        expect(ExclusionList.isExcluded(domain: "commbank.com.au", userAdded: []), "bank domain excluded")
        expect(ExclusionList.isExcluded(domain: "bankwest.com.au", userAdded: []), "bank keyword excluded")
        expect(ExclusionList.isExcluded(domain: "medicare.gov.au", userAdded: []), "gov suffix excluded")
        expect(ExclusionList.isExcluded(domain: "nhs.uk", userAdded: []), "health suffix excluded")
        expect(!ExclusionList.isExcluded(domain: "github.com", userAdded: []), "normal site not excluded")
        expect(ExclusionList.isExcluded(domain: "github.com", userAdded: ["github.com"]), "user exclusion honoured")

        // Observation gating (PRD §3): no consent → no rows; excluded → no rows.
        do {
            let db = try Database(path: ":memory:")
            try db.execute("CREATE TABLE app_state (key TEXT PRIMARY KEY, value TEXT NOT NULL)")
            let observations = ObservationStore(db: db)
            let visit = ObservationStore.Visit(
                url: URL(string: "https://github.com/apple/swift")!,
                title: "GitHub", transition: "link", workspaceID: nil, openDomains: []
            )
            observations.recordVisit(visit)
            expect(observations.eventCount == 0, "undecided consent records nothing")
            observations.recordConsent(false)
            observations.recordVisit(visit)
            expect(observations.eventCount == 0, "declined consent records nothing")
            observations.recordConsent(true)
            observations.recordVisit(visit)
            expect(observations.eventCount == 1, "granted consent records a visit")
            observations.recordVisit(.init(
                url: URL(string: "https://www.commbank.com.au/login")!,
                title: "NetBank", transition: "link", workspaceID: nil, openDomains: []
            ))
            expect(observations.eventCount == 1, "excluded visit leaves no row")
            observations.setPaused(true)
            observations.recordVisit(visit)
            expect(observations.eventCount == 1, "paused records nothing")
            observations.setPaused(false)
            observations.addUserExclusion("github.com")
            expect(observations.eventCount == 0, "user exclusion scrubs existing rows")
            observations.recordVisit(visit)
            expect(observations.eventCount == 0, "user-excluded visit leaves no row")
            _ = observations.recordImportedVisit(
                ts: 1_700_000_000, url: URL(string: "https://www.anz.com/personal/")!,
                title: nil, transition: "typed", sourceBrowser: "safari"
            )
            expect(observations.eventCount == 0, "excluded import leaves no row")
            observations.deleteEverything()
            expect(observations.eventCount == 0, "delete-everything leaves zero events")
        } catch {
            failures.append("observation harness: \(error)")
        }

        // Domain identity: a self-hosted service on a personal domain must
        // keep its own host, not collapse to the registrable domain and lose
        // itself — and workspace birth must read the real URL, never guess
        // "https://domain/". Regression for the bug where a Home Assistant
        // instance at home.example.com got confused with an unrelated site.
        expect(DisplayNames.observationDomain(for: "home.keranmckenzie.com") == "home.keranmckenzie.com",
               "self-hosted subdomain keeps its own identity")
        expect(DisplayNames.observationDomain(for: "www.example.com") == "example.com",
               "www. mirror prefix still collapses")
        expect(DisplayNames.observationDomain(for: "mail.google.com") == "mail.google.com",
               "app subdomain keeps its own identity")
        do {
            let db = try Database(path: ":memory:")
            try db.execute("CREATE TABLE app_state (key TEXT PRIMARY KEY, value TEXT NOT NULL)")
            let observations = ObservationStore(db: db)
            observations.recordConsent(true)
            observations.recordVisit(.init(
                url: URL(string: "http://home.keranmckenzie.com/lovelace/default_view")!,
                title: "Home Assistant", transition: "typed", workspaceID: nil, openDomains: []
            ))
            observations.recordVisit(.init(
                url: URL(string: "http://home.keranmckenzie.com/lovelace/default_view")!,
                title: "Home Assistant", transition: "typed", workspaceID: nil, openDomains: []
            ))
            let resolved = observations.mostVisitedURL(forDomain: "home.keranmckenzie.com")
            expect(resolved?.absoluteString == "http://home.keranmckenzie.com/lovelace/default_view",
                   "real scheme and path read back, not guessed (got \(resolved?.absoluteString ?? "nil"))")
            // A same-registrable-domain bank subdomain must still be excluded
            // even though identity is no longer collapsed to eTLD+1.
            observations.recordVisit(.init(
                url: URL(string: "https://secure.commbank.com.au/netbank/")!,
                title: "NetBank", transition: "link", workspaceID: nil, openDomains: []
            ))
            expect(observations.eventCount == 2, "bank subdomain still excluded despite full-host identity")
        } catch {
            failures.append("domain identity harness: \(error)")
        }

        // M4 acceptance gate (PRD §5): against the demo seed the detectors
        // must find ≥3 of 4 planted routines with ≤2 false positives.
        do {
            let visits = DemoSeed.generateVisits(seed: 42)
            let patterns = LearningEngine.analyze(visits: visits)
            let settled = patterns.filter(\.settled)

            let sequenceHit = settled.contains {
                $0.kind == .sequence && Set($0.domains).isSubset(of: Set(DemoSeed.plantedSequence)) && $0.domains.count >= 2
            }
            let ritualHit = settled.contains {
                $0.kind == .ritual && $0.domains == [DemoSeed.plantedRitualDomain]
                    && ($0.windowLabel?.contains("Sunday") ?? false)
            }
            let clusterHit = settled.contains {
                $0.kind == .cooccurrence && Set($0.domains).intersection(Set(DemoSeed.plantedCluster)).count >= 2
            }
            let promotionHit = settled.contains {
                $0.kind == .appPromotion && $0.domains == [DemoSeed.plantedApplication]
            }
            let hits = [sequenceHit, ritualHit, clusterHit, promotionHit].filter { $0 }.count

            let plantedUniverse = Set(DemoSeed.plantedSequence + [DemoSeed.plantedRitualDomain] +
                                      DemoSeed.plantedCluster + [DemoSeed.plantedApplication])
            let falsePositives = settled.filter { !Set($0.domains).isSubset(of: plantedUniverse) }

            print("engine harness: \(hits)/4 planted found "
                  + "(seq \(sequenceHit) ritual \(ritualHit) cluster \(clusterHit) promo \(promotionHit)), "
                  + "\(falsePositives.count) false positives, \(settled.count) settled of \(patterns.count) total")
            for fp in falsePositives {
                print("  FP: \(fp.kind.rawValue) \(fp.domains.joined(separator: " > ")) [\(fp.windowLabel ?? "-")] — \(fp.evidenceLine)")
            }
            expect(hits >= 3, "engine finds ≥3 of 4 planted routines (found \(hits))")
            expect(falsePositives.count <= 2, "engine ≤2 false positives (got \(falsePositives.count))")
        }

        // Cost accountant register (D3: aggressive rounding, no false precision)
        expect(CostAccountant.countPhrase(13) == "about a dozen", "dozen phrasing")
        expect(CostAccountant.spanPhrase(days: 21) == "the past three weeks", "three weeks phrasing")
        expect(!CostAccountant.sequenceEvidence(count: 13, window: "weekday morning", spanDays: 21).contains("13"),
               "evidence line never carries raw counts")

        // Optional import smoke test against a real Chromium History file:
        //   Sill --selftest --chromium-fixture /path/to/History
        if let flagIndex = CommandLine.arguments.firstIndex(of: "--chromium-fixture"),
           CommandLine.arguments.indices.contains(flagIndex + 1) {
            do {
                let db = try Database(path: ":memory:")
                try db.execute("CREATE TABLE app_state (key TEXT PRIMARY KEY, value TEXT NOT NULL)")
                let observations = ObservationStore(db: db)
                observations.recordConsent(true)
                let importer = HistoryImporter(observations: observations)
                let started = Date()
                let result = try importer.importHistory(
                    from: .chrome,
                    overridePath: CommandLine.arguments[flagIndex + 1]
                )
                let elapsed = Date().timeIntervalSince(started)
                print(String(format: "chromium fixture: %d visits, %d bookmarks in %.2fs (events now %d)",
                             result.visits, result.bookmarks, elapsed, observations.eventCount))
                expect(result.visits > 0, "chromium fixture yields visits")
                expect(observations.eventCount == result.visits, "fixture visits all recorded")
            } catch {
                failures.append("chromium fixture import: \(error)")
            }
        }

        if failures.isEmpty {
            print("selftest: all checks passed")
            exit(0)
        } else {
            print("selftest: \(failures.count) FAILED\n - " + failures.joined(separator: "\n - "))
            exit(1)
        }
    }

    /// `Sill --run-engine`: run the detectors against the real database and
    /// print the raw output — the M4 gate's "review together before any card
    /// exists" step. Read-mostly; safe alongside a running Sill (WAL).
    @MainActor
    static func runEngineIfRequested() {
        guard CommandLine.arguments.contains("--run-engine") else { return }
        do {
            let db = try Database(path: TabStore.defaultDatabasePath())
            let visitCount = (try? db.query("SELECT count(*) AS n FROM event WHERE kind = 'visit'").first?.int("n")) ?? 0
            print("events: \(visitCount ?? 0) visits in the ledger\n")
            let patterns = LearningEngine.run(db: db)
            if patterns.isEmpty {
                print("No patterns yet. Watching quietly — patterns usually appear within a few days.")
            }
            for pattern in patterns.sorted(by: { ($0.settled ? 0 : 1, $0.kind.rawValue) < ($1.settled ? 0 : 1, $1.kind.rawValue) }) {
                let status = pattern.settled ? "SETTLED " : "settling"
                print("[\(status)] \(pattern.kind.rawValue): \(pattern.domains.joined(separator: " > "))")
                print("           window: \(pattern.windowLabel ?? "—")  name: \(pattern.suggestedName)")
                print("           \(pattern.evidenceLine)  (count \(pattern.count), days \(pattern.dayCount), span \(pattern.spanDays)d)\n")
            }
            exit(0)
        } catch {
            print("run-engine failed: \(error)")
            exit(1)
        }
    }
}
