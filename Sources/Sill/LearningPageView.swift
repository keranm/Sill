import SwiftUI

/// The Learning page (D2d): the trust ledger — your own well-kept notebook,
/// not an admin panel. Pause and delete-everything visible without scrolling.
/// Factual, no guilt, no theatre.
struct LearningPageView: View {
    @Bindable var store: TabStore
    let close: () -> Void

    @State private var deleteConfirmShown = false
    @State private var newExclusion = ""
    @FocusState private var exclusionFocused: Bool

    private var observations: ObservationStore { store.observations }
    private var patterns: PatternStore { store.patterns }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                controls

                if observations.consent == .granted {
                    section("OBSERVED, IN AGGREGATE") { aggregate }
                    section("NOTICED SO FAR") { noticedList }
                    section("SUGGESTIONS MADE") { outcomesList }
                }
                section("NEVER OBSERVED") { neverObserved }

                Spacer(minLength: 60)
            }
            .frame(maxWidth: 520)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 40)
        }
        .background(Tokens.stage)
        .overlay(alignment: .topLeading) {
            Button {
                close()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left").font(.system(size: 10, weight: .medium))
                    Text("Back").font(Tokens.font(12))
                }
                .foregroundStyle(Tokens.inkFaint)
                .padding(10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: Header + controls (above the fold, PRD §3.4)

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Learning")
                .font(Tokens.font(22, .medium))
                .foregroundStyle(Tokens.ink)
                .padding(.top, 56)

            Text(statusLine)
                .font(Tokens.font(12.5))
                .foregroundStyle(Tokens.inkFaint)
                .lineSpacing(3.5)
        }
    }

    private var statusLine: String {
        switch observations.consent {
        case .declined, .undecided:
            return "Observation is off. The browser works fully without it; turn it on below if you change your mind."
        case .granted:
            if observations.isPaused {
                return "Paused. What was learned before is kept below, untouched, until you say otherwise."
            }
            if let since = observations.observingSince {
                let formatter = DateFormatter()
                formatter.dateFormat = "d MMMM"
                return "Observing locally since \(formatter.string(from: since)). Nothing has left this machine."
            }
            return "Observing locally. Nothing has left this machine."
        }
    }

    private var controls: some View {
        HStack(spacing: 12) {
            if observations.consent == .granted {
                Button {
                    observations.setPaused(!observations.isPaused)
                } label: {
                    Text(observations.isPaused ? "Resume observation" : "Pause observation")
                        .font(Tokens.font(12.5, .medium))
                        .foregroundStyle(Tokens.ink)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                        .background(Capsule().strokeBorder(Tokens.hairline, lineWidth: 1))
                }
                .buttonStyle(.plain)
            } else {
                Button {
                    observations.recordConsent(true)
                } label: {
                    Text("Turn observation on")
                        .font(Tokens.font(12.5, .medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(Tokens.accent))
                }
                .buttonStyle(.plain)
            }

            Button("Delete everything") {
                deleteConfirmShown = true
            }
            .buttonStyle(.plain)
            .font(Tokens.font(12.5))
            .foregroundStyle(Tokens.inkFaint)
            .popover(isPresented: $deleteConfirmShown, arrowEdge: .bottom) {
                deleteConfirm
            }
        }
    }

    /// D2d: sober, specific, honoured immediately. The consequence stated exactly.
    private var deleteConfirm: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Delete everything learned?")
                .font(Tokens.font(13.5, .semibold))
                .foregroundStyle(Tokens.ink)
            Text("Every observation, pattern and suggestion record is erased from this Mac. Workspaces you created stay. This can't be undone.")
                .font(Tokens.font(12.5))
                .foregroundStyle(Tokens.inkFaint)
                .lineSpacing(3.5)
            HStack {
                Spacer()
                Button("Keep it") { deleteConfirmShown = false }
                    .buttonStyle(.plain)
                    .font(Tokens.font(12.5))
                    .foregroundStyle(Tokens.inkFaint)
                Button {
                    observations.deleteEverything()
                    patterns.refresh()
                    deleteConfirmShown = false
                } label: {
                    Text("Delete")
                        .font(Tokens.font(12.5, .medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(Tokens.danger))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(16)
        .frame(width: 320)
        .background(Tokens.canvas)
    }

    // MARK: Sections

    private var aggregate: some View {
        Text("Site visits and their order, on about \(roundedForty(observations.distinctDomainCount)) sites. Times of day, rounded to the hour. Which sites get opened together. Nothing about page content, and nothing from the excluded list below.")
            .font(Tokens.font(12.5))
            .foregroundStyle(Tokens.inkFaint)
            .lineSpacing(4)
    }

    @ViewBuilder
    private var noticedList: some View {
        if patterns.noticedSettled.isEmpty && patterns.stillSettling.isEmpty {
            Text("Nothing yet. Patterns usually appear within a few days.")
                .font(Tokens.font(12.5))
                .foregroundStyle(Tokens.inkGhost)
        }
        ForEach(patterns.noticedSettled) { pattern in
            ledgerRow(
                text: patterns.ledgerLine(for: pattern),
                note: "since \(monthWord(pattern.firstDetected))"
            ) {
                patterns.forget(pattern)
            }
        }
        ForEach(patterns.stillSettling) { pattern in
            ledgerRow(
                text: patterns.ledgerLine(for: pattern),
                note: "recent, still settling"
            ) {
                patterns.forget(pattern)
            }
        }
    }

    @ViewBuilder
    private var outcomesList: some View {
        if patterns.outcomes.isEmpty {
            Text("None yet.")
                .font(Tokens.font(12.5))
                .foregroundStyle(Tokens.inkGhost)
        }
        ForEach(patterns.outcomes) { pattern in
            HStack(spacing: 8) {
                Text(patterns.ledgerLine(for: pattern))
                    .font(Tokens.font(12.5))
                    .foregroundStyle(Tokens.ink.opacity(0.8))
                    .lineLimit(1)
                Spacer()
                switch pattern.state {
                case "confirmed":
                    Text("accepted — became \u{201C}\(pattern.workspaceName ?? pattern.suggestedName)\u{201D}")
                        .font(Tokens.font(11.5))
                        .foregroundStyle(Tokens.accent)
                case "dismissed":
                    Text("dismissed \(shortDate(pattern.resolvedAt))")
                        .font(Tokens.font(11.5))
                        .foregroundStyle(Tokens.inkGhost)
                    Button("undo") {
                        patterns.undoDismiss(pattern)
                    }
                    .buttonStyle(.plain)
                    .font(Tokens.font(11.5))
                    .foregroundStyle(Tokens.accent)
                    .underline()
                default:
                    Text("withdrawn, unanswered")
                        .font(Tokens.font(11.5))
                        .foregroundStyle(Tokens.inkGhost)
                }
            }
        }
    }

    private var neverObserved: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Private windows. Banking and health sites, by category. Government sites. Adult sites. And anything you add:")
                .font(Tokens.font(12.5))
                .foregroundStyle(Tokens.inkFaint)
                .lineSpacing(4)

            HStack(spacing: 6) {
                ForEach(observations.userExclusions.sorted(), id: \.self) { domain in
                    Text(domain)
                        .font(Tokens.font(11.5))
                        .foregroundStyle(Tokens.inkFaint)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Tokens.well))
                }
                TextField("+ add a site", text: $newExclusion)
                    .textFieldStyle(.plain)
                    .font(Tokens.font(11.5))
                    .focused($exclusionFocused)
                    .frame(width: 90)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(
                        Capsule().strokeBorder(Tokens.hairline, style: StrokeStyle(lineWidth: 1, dash: [3]))
                    )
                    .onSubmit {
                        let trimmed = newExclusion.trimmingCharacters(in: .whitespaces)
                        guard !trimmed.isEmpty else { return }
                        observations.addUserExclusion(trimmed)
                        newExclusion = ""
                    }
            }

            Text("Excluded sites leave no trace here at all — not even a count.")
                .font(Tokens.font(11.5))
                .foregroundStyle(Tokens.inkGhost)
        }
    }

    // MARK: Helpers

    private func section(_ label: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(label)
                .font(Tokens.font(10, .medium))
                .kerning(0.8)
                .foregroundStyle(Tokens.inkGhost)
            content()
        }
    }

    private func ledgerRow(text: String, note: String, forget: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            Text(text)
                .font(Tokens.font(12.5))
                .foregroundStyle(Tokens.ink.opacity(0.85))
                .lineLimit(2)
            Spacer()
            Text(note)
                .font(Tokens.font(11.5))
                .foregroundStyle(Tokens.inkGhost)
            Button("forget") {
                forget()
            }
            .buttonStyle(.plain)
            .font(Tokens.font(11.5))
            .foregroundStyle(Tokens.inkFaint)
            .underline()
        }
    }

    private func roundedForty(_ n: Int) -> String {
        switch n {
        case ..<15: return "\(max(n, 1))"
        case ..<25: return "twenty"
        case ..<35: return "thirty"
        case ..<50: return "forty"
        case ..<75: return "sixty"
        case ..<125: return "a hundred"
        default: return "a few hundred"
        }
    }

    private func monthWord(_ ts: Double) -> String {
        let date = Date(timeIntervalSince1970: ts)
        let formatter = DateFormatter()
        formatter.dateFormat = "MMMM"
        let month = formatter.string(from: date)
        let day = Calendar.current.component(.day, from: date)
        return day <= 10 ? "early \(month)" : (day <= 20 ? "mid-\(month)" : "late \(month)")
    }

    private func shortDate(_ ts: Double?) -> String {
        guard let ts else { return "" }
        let formatter = DateFormatter()
        formatter.dateFormat = "d MMMM"
        return formatter.string(from: Date(timeIntervalSince1970: ts))
    }
}
