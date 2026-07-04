import SwiftUI

extension Notification.Name {
    static let openLearning = Notification.Name("sill.openLearning")
}

/// Home (D2b): one evolving page across three temporal states — greeting,
/// search, recent, an import invitation on day one; Applications once any are
/// confirmed; at most two noticed cards, below the fold of attention.
/// No widgets, no configuration begging.
struct HomeView: View {
    @Bindable var store: TabStore
    let tab: BrowserTab

    @State private var searchText = ""
    @FocusState private var searchFocused: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                Text(greeting)
                    .font(Tokens.font(22, .medium))
                    .foregroundStyle(Tokens.ink)
                    .padding(.top, 70)

                searchField

                if !store.patterns.confirmedApplications.isEmpty {
                    applicationsRow
                }

                ForEach(store.patterns.suggestions) { pattern in
                    SuggestionCardView(store: store, pattern: pattern)
                }

                if showWatchingQuietly {
                    Text("Watching quietly. Patterns usually appear within a few days.")
                        .font(Tokens.font(12))
                        .foregroundStyle(Tokens.inkGhost)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.top, 8)
                }

                if !recent.isEmpty {
                    recentSection
                }

                if !store.observations.hasImportedHistory, store.observations.consent == .granted {
                    importInvitation
                }

                Spacer(minLength: 60)
            }
            .frame(maxWidth: 520)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 40)
        }
        .background(Tokens.stage)
        .onAppear {
            store.patterns.refresh()
        }
    }

    // MARK: Pieces

    /// Day one: "Good morning". Once the browser has lived here a week,
    /// the day itself joins: "Thursday morning".
    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: Date())
        let daypart = switch hour {
        case 5..<12: "morning"
        case 12..<18: "afternoon"
        default: "evening"
        }
        if let since = store.observations.observingSince,
           Date().timeIntervalSince(since) > 7 * 86400 {
            let weekday = Calendar.current.weekdaySymbols[Calendar.current.component(.weekday, from: Date()) - 1]
            return "\(weekday) \(daypart)"
        }
        return "Good \(daypart)"
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            TextField("Search or go to…", text: $searchText)
                .textFieldStyle(.plain)
                .font(Tokens.font(13.5))
                .focused($searchFocused)
                .onSubmit {
                    store.navigate(searchText, in: tab)
                }
            Text("⌘K")
                .font(Tokens.font(11))
                .foregroundStyle(Tokens.inkGhost)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: Tokens.radiusControl).fill(Tokens.well))
        .overlay(
            RoundedRectangle(cornerRadius: Tokens.radiusControl)
                .strokeBorder(searchFocused ? Tokens.accent : .clear, lineWidth: 1.5)
        )
    }

    /// Confirmed applications only (PRD §8.2): discovery alone never places
    /// an icon here.
    private var applicationsRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionLabel("APPLICATIONS")
            HStack(spacing: 18) {
                ForEach(store.patterns.confirmedApplications) { app in
                    Button {
                        if let url = store.observations.mostVisitedURL(forDomain: app.domains[0]) {
                            store.navigate(url.absoluteString, in: tab)
                        }
                    } label: {
                        VStack(spacing: 5) {
                            Text(String(DisplayNames.displayName(for: app.domains[0]).prefix(1)))
                                .font(Tokens.font(13, .semibold))
                                .foregroundStyle(Tokens.accent)
                                .frame(width: 34, height: 34)
                                .background(RoundedRectangle(cornerRadius: 8).fill(Tokens.well))
                            Text(app.workspaceName ?? DisplayNames.displayName(for: app.domains[0]))
                                .font(Tokens.font(11))
                                .foregroundStyle(Tokens.inkFaint)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var recent: [(title: String, url: URL, ts: TimeInterval)] {
        store.observations.recentVisits(limit: 4)
    }

    private var recentSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel("RECENT")
            ForEach(recent, id: \.ts) { item in
                Button {
                    store.navigate(item.url.absoluteString, in: tab)
                } label: {
                    HStack(spacing: 8) {
                        Circle().fill(Tokens.inkGhost.opacity(0.6)).frame(width: 4, height: 4)
                        Text(item.title)
                            .font(Tokens.font(12.5))
                            .foregroundStyle(Tokens.ink.opacity(0.8))
                            .lineLimit(1)
                        Spacer()
                        Text(relative(item.ts))
                            .font(Tokens.font(11.5))
                            .foregroundStyle(Tokens.inkGhost)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var importInvitation: some View {
        HStack(spacing: 6) {
            Text("Coming from another browser?")
                .font(Tokens.font(12))
                .foregroundStyle(Tokens.inkGhost)
            Button("Bring your bookmarks and history") {
                NotificationCenter.default.post(name: .openImport, object: nil)
            }
            .buttonStyle(.plain)
            .font(Tokens.font(12))
            .foregroundStyle(Tokens.accent)
            .underline()
        }
    }

    /// Post-import, pre-detection (D2f): honest, unanxious, no progress bars
    /// pretending to know.
    private var showWatchingQuietly: Bool {
        store.observations.hasImportedHistory
            && store.patterns.suggestions.isEmpty
            && store.patterns.noticedSettled.isEmpty
            && store.observations.isObserving
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(Tokens.font(10, .medium))
            .kerning(0.8)
            .foregroundStyle(Tokens.inkGhost)
    }

    private func relative(_ ts: TimeInterval) -> String {
        let delta = Date().timeIntervalSince1970 - ts
        switch delta {
        case ..<120: return "just now"
        case ..<3600: return "\(Int(delta / 60)) min ago"
        case ..<7200: return "1 hr ago"
        case ..<86400: return "\(Int(delta / 3600)) hrs ago"
        case ..<172800: return "yesterday"
        default: return "\(Int(delta / 86400)) days ago"
        }
    }
}
