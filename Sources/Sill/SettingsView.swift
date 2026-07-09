import SwiftUI

/// Sill's Settings window (⌘,) — born 2026-07-10 to give the local-file
/// toggle a home. Safety-relevant switches default off; a setting earns a
/// place here only when a menu item wouldn't do.
struct SettingsView: View {
    @Bindable var store: TabStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: $store.cookieBannerBlockingEnabled) {
                Text("Hide cookie-consent pop-ups")
                    .font(Tokens.font(13, .medium))
                    .foregroundStyle(Tokens.ink)
            }
            .toggleStyle(.switch)
            .controlSize(.small)

            Text("Hides consent banners and blocks the services that serve them, using the community-maintained EasyList Cookie List. Off by default: answering or suppressing these prompts is your decision, not the browser's. Applies to pages loaded after changing it.")
                .font(Tokens.font(11.5))
                .foregroundStyle(Tokens.inkFaint)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)

            Divider()
                .overlay(Tokens.hairline)
                .padding(.vertical, 6)

            Toggle(isOn: $store.localFileAccessEnabled) {
                Text("Allow local file access")
                    .font(Tokens.font(13, .medium))
                    .foregroundStyle(Tokens.ink)
            }
            .toggleStyle(.switch)
            .controlSize(.small)

            Text("Open files on this Mac by typing a path (~/… or /…) or a file:// address — submit a bare file:// to browse for one — or by dropping a file onto the sidebar. Off, typed paths are treated as searches and pages can never reach your files. Sill stays safe out of the box; turning this on is your call.")
                .font(Tokens.font(11.5))
                .foregroundStyle(Tokens.inkFaint)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
        .frame(width: 400)
        .background(Tokens.canvas)
    }
}
