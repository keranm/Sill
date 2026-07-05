import SwiftUI
import WebKit

/// Drives a Quick Look window's identity. A fresh UUID per request guarantees
/// a new window every time, even for two blank lookups back to back.
struct QuickLookRequest: Codable, Hashable {
    var id = UUID()
    var initialURLString: String?
}

/// Quick Look (inspired by Arc's Little Arc): a frameless, single-page window
/// for a quick lookup that never touches your workspaces unless you say so.
/// Close it and it's gone — no tab clutter. "Open in…" promotes it into a
/// real workspace, keeping the page exactly as loaded.
struct QuickLookView: View {
    @Bindable var store: TabStore
    let initialURLString: String?

    @Environment(\.dismissWindow) private var dismissWindow
    @State private var tab: BrowserTab?
    @State private var addressText = ""
    @FocusState private var addressFocused: Bool
    /// Set just before promoting, so .onDisappear doesn't tear down the
    /// webview that was just adopted into a workspace.
    @State private var promoted = false

    var body: some View {
        VStack(spacing: 0) {
            header
            content
        }
        .frame(minWidth: 480, minHeight: 400)
        .background(WindowConfigurator())
        .onAppear {
            guard tab == nil else { return }
            let newTab = BrowserTab(url: initialURLString.flatMap(TabStore.destination(for:))) {}
            tab = newTab
            if newTab.url != nil {
                store.materialize(newTab)
            } else {
                addressFocused = true
            }
        }
        .onDisappear {
            if let tab, !promoted { Task { await tab.dehydrate() } }
        }
    }

    // MARK: Header — back button, address, promote. Deliberately no forward,
    // no reload, no share: a quick look, not a second shell.

    private var header: some View {
        HStack(spacing: 10) {
            Button {
                tab?.webView?.goBack()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle((tab?.canGoBack ?? false) ? Tokens.inkFaint : Tokens.inkGhost.opacity(0.5))
                    .frame(width: 24, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!(tab?.canGoBack ?? false))

            if tab?.url != nil {
                addressReadout
            } else {
                TextField("Search or go to…", text: $addressText)
                    .textFieldStyle(.plain)
                    .font(Tokens.font(13))
                    .focused($addressFocused)
                    .onSubmit(loadTypedAddress)
            }

            Spacer(minLength: 8)

            if tab?.url != nil {
                promoteMenu
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 14)
        .padding(.bottom, 10)
    }

    private var addressReadout: some View {
        let host = tab?.url?.host() ?? ""
        let domain = HostDisplay.displayHost(HostDisplay.registrableDomain(of: host))
        return Text(domain)
            .font(Tokens.font(12.5, .medium))
            .foregroundStyle(Tokens.ink)
            .lineLimit(1)
    }

    private var promoteMenu: some View {
        HStack(spacing: 0) {
            Button {
                promote(into: store.activeWorkspace)
            } label: {
                Text("Open in \(store.railTitle)")
                    .font(Tokens.font(12))
                    .foregroundStyle(Tokens.ink)
            }
            .buttonStyle(.plain)
            .keyboardShortcut("o", modifiers: .command)

            Menu {
                ForEach(store.workspaces) { workspace in
                    Button(workspace.name) { promote(into: workspace) }
                }
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(Tokens.inkGhost)
            }
            .menuStyle(.borderlessButton)
            .frame(width: 20)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Capsule().fill(Tokens.well))
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if let tab, let webView = tab.webView, tab.url != nil {
            WebViewContainer(webView: webView)
        } else {
            Tokens.stage
        }
    }

    // MARK: Actions

    private func loadTypedAddress() {
        guard let tab, let destination = TabStore.destination(for: addressText) else { return }
        store.materialize(tab)
        tab.load(destination)
    }

    private func promote(into workspace: Workspace) {
        guard let tab, tab.url != nil else { return }
        promoted = true
        store.adopt(tab, into: workspace)
        Task {
            await store.switchWorkspace(to: workspace.id)
            dismissWindow()
        }
    }
}
