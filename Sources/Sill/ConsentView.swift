import SwiftUI

/// The single import-consent screen (D2f) — under 60 words, verbatim from the
/// design package. "Not now" keeps observation off; the browser works fully
/// either way. Revisitable from the Learning page (M5).
struct ConsentView: View {
    let decide: (Bool) -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.12).ignoresSafeArea()

            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Before anything else")
                        .font(Tokens.font(15, .semibold))
                        .foregroundStyle(Tokens.ink)

                    Text("This browser notices patterns in how you use it — which sites, in what order, at what times. Banking, health, and private windows are never observed. Everything stays on this Mac. You can read, pause, or delete all of it, any time, from the Learning page.")
                        .font(Tokens.font(13))
                        .foregroundStyle(Tokens.ink.opacity(0.85))
                        .lineSpacing(4)

                    HStack {
                        Spacer()
                        Button("Not now") { decide(false) }
                            .buttonStyle(.plain)
                            .font(Tokens.font(13))
                            .foregroundStyle(Tokens.inkFaint)
                            .padding(.trailing, 14)
                        Button {
                            decide(true)
                        } label: {
                            Text("Okay")
                                .font(Tokens.font(13, .medium))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 18)
                                .padding(.vertical, 6)
                                .background(Capsule().fill(Tokens.accent))
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.top, 4)
                }
                .padding(20)
                .frame(width: 380)
                .background(
                    RoundedRectangle(cornerRadius: Tokens.radiusStage)
                        .fill(Tokens.canvas)
                        .shadow(color: .black.opacity(0.16), radius: 26, y: 10)
                )

                Text("\u{201C}Not now\u{201D} keeps observation off. The browser works fully either way.")
                    .font(Tokens.font(11.5))
                    .foregroundStyle(Tokens.inkGhost)
                    .padding(.top, 10)
                    .padding(.leading, 4)
            }
        }
    }
}
