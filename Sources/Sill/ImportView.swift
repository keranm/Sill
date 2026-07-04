import SwiftUI

/// History + bookmarks import sheet (PRD §4.4). Detected browsers, one action
/// each; Safari's Full Disk Access wall gets a designed explanation, not a
/// bare OS dialog. Register per D3: factual, no exclamation marks, no theatre.
struct ImportView: View {
    let store: TabStore
    @Binding var isPresented: Bool

    private var observations: ObservationStore { store.observations }

    private struct BrowserState: Identifiable {
        let browser: HistoryImporter.Browser
        var id: String { browser.id }
        var status: Status = .idle

        enum Status: Equatable {
            case idle
            case running
            case done(visits: Int, bookmarks: Int, oldest: Date?)
            case needsFullDiskAccess
            case failed(String)
        }
    }

    @State private var browsers: [BrowserState] = HistoryImporter.Browser.allCases
        .filter(\.isInstalled)
        .map { BrowserState(browser: $0) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Bring your history")
                .font(Tokens.font(15, .semibold))
                .foregroundStyle(Tokens.ink)

            Text("Months of existing history give the Learning page something to notice from day one. Visits are recorded as metadata only — site, order, time. Excluded sites are skipped entirely during import; they leave no trace, not even a count.")
                .font(Tokens.font(12.5))
                .foregroundStyle(Tokens.inkFaint)
                .lineSpacing(3.5)

            if browsers.isEmpty {
                Text("No other browsers were found on this Mac.")
                    .font(Tokens.font(12.5))
                    .foregroundStyle(Tokens.inkGhost)
            }

            ForEach($browsers) { $state in
                browserRow($state)
            }

            HStack {
                Spacer()
                Button("Done") { isPresented = false }
                    .buttonStyle(.plain)
                    .font(Tokens.font(13, .medium))
                    .foregroundStyle(Tokens.accent)
            }
        }
        .padding(20)
        .frame(width: 440)
        .background(Tokens.canvas)
    }

    @ViewBuilder
    private func browserRow(_ state: Binding<BrowserState>) -> some View {
        let value = state.wrappedValue
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(value.browser.displayName)
                    .font(Tokens.font(13, .medium))
                    .foregroundStyle(Tokens.ink)
                Spacer()
                switch value.status {
                case .idle:
                    Button("Import") { runImport(state) }
                        .buttonStyle(.plain)
                        .font(Tokens.font(12.5))
                        .foregroundStyle(Tokens.accent)
                case .running:
                    ProgressView().controlSize(.small)
                case .done(let visits, let bookmarks, let oldest):
                    Text(summary(visits: visits, bookmarks: bookmarks, oldest: oldest))
                        .font(Tokens.font(12))
                        .foregroundStyle(Tokens.inkFaint)
                case .needsFullDiskAccess:
                    Button("Try again") { runImport(state) }
                        .buttonStyle(.plain)
                        .font(Tokens.font(12.5))
                        .foregroundStyle(Tokens.accent)
                case .failed:
                    Button("Retry") { runImport(state) }
                        .buttonStyle(.plain)
                        .font(Tokens.font(12.5))
                        .foregroundStyle(Tokens.accent)
                }
            }

            if value.status == .needsFullDiskAccess {
                VStack(alignment: .leading, spacing: 8) {
                    Text("macOS keeps Safari's history off-limits until you allow it. To let Sill read it: System Settings → Privacy & Security → Full Disk Access → add Sill. Sill reads the history file once, on this Mac; nothing leaves it.")
                        .font(Tokens.font(12))
                        .foregroundStyle(Tokens.inkFaint)
                        .lineSpacing(3.5)
                    Button("Open System Settings") {
                        NSWorkspace.shared.open(
                            URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!
                        )
                    }
                    .buttonStyle(.plain)
                    .font(Tokens.font(12, .medium))
                    .foregroundStyle(Tokens.accent)
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: Tokens.radiusControl).fill(Tokens.well))
            } else if case .failed(let message) = value.status {
                Text(message)
                    .font(Tokens.font(11.5))
                    .foregroundStyle(Tokens.danger)
            }
        }
        .padding(.vertical, 2)
    }

    private func runImport(_ state: Binding<BrowserState>) {
        state.wrappedValue.status = .running
        Task { @MainActor in
            let importer = HistoryImporter(observations: observations)
            do {
                let result = try importer.importHistory(from: state.wrappedValue.browser)
                // Months of history just landed: detect now, not in 12 hours.
                LearningEngine.run(db: store.database)
                store.patterns.refresh()
                state.wrappedValue.status = .done(
                    visits: result.visits,
                    bookmarks: result.bookmarks,
                    oldest: result.oldest
                )
            } catch HistoryImporter.ImportError.needsFullDiskAccess {
                state.wrappedValue.status = .needsFullDiskAccess
            } catch {
                state.wrappedValue.status = .failed("That didn't work: \(error)")
            }
        }
    }

    /// Aggressively rounded, per the D3 register — never false precision.
    private func summary(visits: Int, bookmarks: Int, oldest: Date?) -> String {
        var parts: [String] = []
        if visits > 0 {
            let rounded = visits >= 1000
                ? "about \((visits + 500) / 1000) thousand visits"
                : "about \(max(visits, 10) / 10 * 10) visits"
            if let oldest {
                let months = max(1, Int(Date().timeIntervalSince(oldest) / 2_592_000))
                parts.append("\(rounded), back about \(months == 1 ? "a month" : "\(months) months")")
            } else {
                parts.append(rounded)
            }
        }
        if bookmarks > 0 {
            parts.append("\(bookmarks) bookmarks")
        }
        return parts.isEmpty ? "Nothing to bring over." : parts.joined(separator: " · ")
    }
}
