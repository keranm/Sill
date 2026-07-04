import SwiftUI

/// The suggestion card, all five D2c states: resting, "Why?" expanded,
/// naming form, (payoff lives on the stage), and the 120 ms dismissal with
/// its one quiet line. A wash, not a box. Zero exclamation marks.
struct SuggestionCardView: View {
    @Bindable var store: TabStore
    let pattern: PatternStore.PatternRow

    private enum Phase {
        case resting, naming, dismissed
    }

    @State private var phase: Phase = .resting
    @State private var whyExpanded = false
    @State private var name = ""
    @State private var surprised = false
    @FocusState private var nameFocused: Bool

    var body: some View {
        Group {
            switch phase {
            case .dismissed:
                Text("Okay. That one won't come back.")
                    .font(Tokens.font(12.5))
                    .foregroundStyle(Tokens.inkGhost)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8)
            case .naming:
                namingForm
            case .resting:
                restingCard
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Tokens.radiusStage)
                .fill(phase == .dismissed ? Color.clear : Tokens.accentWash)
        )
    }

    // MARK: Resting (+ Why?)

    private var restingCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(store.patterns.observationLine(for: pattern))
                .font(Tokens.font(14))
                .foregroundStyle(Tokens.ink)
                .lineSpacing(3.5)

            Text(pattern.evidenceLine)
                .font(Tokens.font(12.5))
                .foregroundStyle(Tokens.inkFaint)

            if whyExpanded {
                Text(store.patterns.whyText(for: pattern))
                    .font(Tokens.font(12.5))
                    .foregroundStyle(Tokens.inkFaint)
                    .lineSpacing(3.5)
                    .padding(.top, 4)
                Button("See it on the Learning page") {
                    NotificationCenter.default.post(name: .openLearning, object: nil)
                }
                .buttonStyle(.plain)
                .font(Tokens.font(12.5))
                .foregroundStyle(Tokens.accent)
                .underline()
            }

            HStack(spacing: 14) {
                Button {
                    if pattern.kind == .appPromotion {
                        store.patterns.confirm(pattern, name: pattern.suggestedName, surprised: false)
                    } else {
                        name = pattern.suggestedName
                        phase = .naming
                        nameFocused = true
                    }
                } label: {
                    Text(store.patterns.actionQuestion(for: pattern))
                        .font(Tokens.font(13, .medium))
                        .foregroundStyle(Tokens.accent)
                        .underline()
                }
                .buttonStyle(.plain)

                Button("Dismiss") {
                    withAnimation(.easeOut(duration: 0.12)) {
                        phase = .dismissed
                    }
                    store.patterns.dismiss(pattern)
                    Task {
                        try? await Task.sleep(for: .seconds(4))
                        store.patterns.refresh()
                    }
                }
                .buttonStyle(.plain)
                .font(Tokens.font(13))
                .foregroundStyle(Tokens.inkFaint)

                Spacer()

                Button("Why?") {
                    withAnimation(.easeOut(duration: 0.15)) {
                        whyExpanded.toggle()
                    }
                }
                .buttonStyle(.plain)
                .font(Tokens.font(12.5))
                .foregroundStyle(Tokens.inkGhost)
                .underline()
            }
            .padding(.top, 4)
        }
    }

    // MARK: Naming (the card itself becomes the form — no modal, no wizard)

    private var namingForm: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(store.patterns.namingIntro(for: pattern))
                .font(Tokens.font(13.5))
                .foregroundStyle(Tokens.ink)

            Text("Call it")
                .font(Tokens.font(11.5))
                .foregroundStyle(Tokens.inkGhost)

            TextField("", text: $name)
                .textFieldStyle(.plain)
                .font(Tokens.font(14))
                .focused($nameFocused)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: Tokens.radiusControl).fill(Tokens.stage))
                .overlay(
                    RoundedRectangle(cornerRadius: Tokens.radiusControl)
                        .strokeBorder(Tokens.accent, lineWidth: 1.5)
                )
                .onSubmit(makeWorkspace)

            Toggle(isOn: $surprised) {
                Text("This surprised me")
                    .font(Tokens.font(11.5))
                    .foregroundStyle(Tokens.inkGhost)
            }
            .toggleStyle(.checkbox)
            .controlSize(.small)

            HStack {
                Button("Back") {
                    phase = .resting
                }
                .buttonStyle(.plain)
                .font(Tokens.font(13))
                .foregroundStyle(Tokens.inkFaint)

                Spacer()

                Button(action: makeWorkspace) {
                    Text("Make the workspace")
                        .font(Tokens.font(13, .medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(Tokens.accent))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func makeWorkspace() {
        store.patterns.confirm(pattern, name: name, surprised: surprised)
    }
}
