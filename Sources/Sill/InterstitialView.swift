import SwiftUI

/// Certificate-error interstitial in the product's own voice (PRD §4.1):
/// factual sentences, no alarm theatre, and no "proceed anyway" path that
/// makes danger look calm. If a trusted-but-broken site matters to the owner,
/// that's a logged annoyance, not a bypass button.
struct InterstitialView: View {
    let host: String
    let reason: String
    let goBack: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Spacer()
            Text("This connection can't be trusted.")
                .font(Tokens.font(22, .semibold))
                .foregroundStyle(Tokens.ink)
            Text("\(host) presented a certificate that can't be verified — \(reason) That usually means a misconfigured site; it can also mean something between you and the site is rewriting what you see. Sill won't load it.")
                .font(Tokens.font(13.5))
                .foregroundStyle(Tokens.inkFaint)
                .lineSpacing(4)
                .frame(maxWidth: 440, alignment: .leading)
            Button(action: goBack) {
                Text("Go back")
                    .font(Tokens.font(13, .medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 7)
                    .background(Capsule().fill(Tokens.accent))
            }
            .buttonStyle(.plain)
            .padding(.top, 6)
            Spacer()
            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .background(Tokens.stage)
    }
}
