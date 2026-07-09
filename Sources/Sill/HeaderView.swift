import SwiftUI

extension Notification.Name {
    static let openGoTo = Notification.Name("sill.openGoTo")
    static let urlCopied = Notification.Name("sill.urlCopied")
}

/// The page header (D2a): back/forward and the address readout.
/// The readout is a security surface (PRD §4.1): registrable domain in full
/// ink, path in faint ink (or title when the path is ID-shaped). No padlock
/// for secure pages (§8.6) — only negative states get marked.
struct HeaderView: View {
    @Bindable var store: TabStore

    @State private var explanationShown = false
    @State private var annoyanceShown = false
    @State private var annoyanceLogged = false
    @State private var transientMessage: String?
    @State private var transientMessageTask: Task<Void, Never>?

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 2) {
                navButton("chevron.left", enabled: store.selectedTab?.canGoBack ?? false) {
                    store.selectedTab?.webView?.goBack()
                }
                navButton("chevron.right", enabled: store.selectedTab?.canGoForward ?? false) {
                    store.selectedTab?.webView?.goForward()
                }
            }

            readout

            if let transientMessage {
                Text(transientMessage)
                    .font(Tokens.font(11.5))
                    .foregroundStyle(Tokens.inkGhost)
                    .transition(.opacity)
            }

            Spacer()

            importAPIButton

            shareButton

            annoyanceButton

            navButton("arrow.clockwise", enabled: store.selectedTab?.url != nil) {
                store.selectedTab?.webView?.reload()
            }
        }
        .padding(.horizontal, 10)
        .padding(.top, 12)
        .padding(.bottom, 7)
        .animation(.easeOut(duration: 0.15), value: transientMessage)
        .onReceive(NotificationCenter.default.publisher(for: .urlCopied)) { _ in
            showTransient("Copied")
        }
        .onReceive(NotificationCenter.default.publisher(for: .pageCaptured)) { _ in
            showTransient("Saved to Desktop")
        }
        .onReceive(NotificationCenter.default.publisher(for: .downloadFinished)) { notification in
            let filename = (notification.userInfo?["filename"] as? String) ?? "file"
            showTransient("Downloaded \(filename)")
        }
        .onReceive(NotificationCenter.default.publisher(for: .localFilesBlocked)) { _ in
            showTransient("Local file access is off — see Settings (⌘,)")
        }
    }

    private func showTransient(_ message: String) {
        transientMessage = message
        transientMessageTask?.cancel()
        transientMessageTask = Task {
            try? await Task.sleep(for: .seconds(1.4))
            guard !Task.isCancelled else { return }
            transientMessage = nil
        }
    }

    /// Shown only when the current tab is a raw OpenAPI/Swagger/Postman
    /// Collection JSON file (WebKitDelegate detects this fresh on every
    /// navigation) — a direct shortcut to the manual file/URL import already
    /// in the API client, for the common case where you're already looking
    /// right at the spec.
    @ViewBuilder
    private var importAPIButton: some View {
        if let collection = store.selectedTab?.detectedAPICollection {
            Button {
                store.apiClient.importCollection(collection)
                showTransient("Imported \"\(collection.name)\"")
            } label: {
                Image(systemName: "square.and.arrow.down.on.square")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(Tokens.accent)
                    .frame(width: 24, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Import \"\(collection.name)\" into the API client")
        }
    }

    @ViewBuilder
    private var shareButton: some View {
        if let tab = store.selectedTab, let url = tab.url, !tab.isInternalTab {
            ShareLink(item: url) {
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(Tokens.inkGhost)
                    .frame(width: 24, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Share")
        } else {
            Image(systemName: "square.and.arrow.up")
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(Tokens.inkGhost.opacity(0.5))
                .frame(width: 24, height: 22)
        }
    }

    /// The one-tap "that was annoying" counter (PRD §4.9): friction moments,
    /// taggable — the password-manager gap and Chrome-first sites are its
    /// expected customers. Quiet ghost; a diary, not a feature.
    private var annoyanceButton: some View {
        Button {
            annoyanceShown.toggle()
        } label: {
            Image(systemName: "hand.raised")
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(Tokens.inkGhost)
                .frame(width: 24, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("That was annoying")
        .popover(isPresented: $annoyanceShown, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                if annoyanceLogged {
                    Text("Noted.")
                        .font(Tokens.font(12.5))
                        .foregroundStyle(Tokens.inkFaint)
                } else {
                    Text("That was annoying. What kind?")
                        .font(Tokens.font(12.5))
                        .foregroundStyle(Tokens.ink)
                    HStack(spacing: 8) {
                        ForEach(["password", "engine", "other"], id: \.self) { tag in
                            Button {
                                store.observations.incrementMetric("annoyance_\(tag)")
                                annoyanceLogged = true
                                Task {
                                    try? await Task.sleep(for: .seconds(0.7))
                                    annoyanceShown = false
                                    annoyanceLogged = false
                                }
                            } label: {
                                Text(tag)
                                    .font(Tokens.font(12))
                                    .foregroundStyle(Tokens.ink)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 4)
                                    .background(Capsule().fill(Tokens.well))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding(12)
            .background(Tokens.canvas)
        }
    }

    private func navButton(_ symbol: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(enabled ? Tokens.inkFaint : Tokens.inkGhost.opacity(0.5))
                .frame(width: 24, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }

    // MARK: Readout

    @ViewBuilder
    private var readout: some View {
        if let tab = store.selectedTab, tab.isInternalTab {
            // No navigable URL to show or edit — an internal tab isn't a
            // website. Not clickable: opening Go-To and submitting a URL
            // here would otherwise overwrite `tab.url` away from `sill://`
            // with no webview to load it into, stranding the tab blank.
            Text(tab.isMCPClientTab ? "MCP Explorer" : "API Client")
                .font(Tokens.font(12.5))
                .foregroundStyle(Tokens.inkGhost)
                .padding(.horizontal, 8)
        } else if let tab = store.selectedTab, let url = tab.url, url.isFileURL {
            // Local file: filename in ink, its folder as the faint fact —
            // there's no host for the domain readout to speak for.
            Button {
                NotificationCenter.default.post(name: .openGoTo, object: nil)
            } label: {
                HStack(spacing: 5) {
                    Text(url.lastPathComponent)
                        .font(Tokens.font(12.5, .medium))
                        .foregroundStyle(Tokens.ink)
                    Text(url.deletingLastPathComponent().path(percentEncoded: false))
                        .font(Tokens.font(12.5))
                        .foregroundStyle(Tokens.inkFaint)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        } else if let tab = store.selectedTab, let url = tab.url, let host = url.host() {
            let state = tab.securityState
            HStack(spacing: 6) {
                if state.isNegative {
                    warningChip(state)
                }
                // Clicking the readout honours twenty years of muscle memory: ⌘L.
                Button {
                    NotificationCenter.default.post(name: .openGoTo, object: nil)
                } label: {
                    readoutText(url: url, host: host, tab: tab, negative: state.isNegative)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        } else {
            Text("New tab")
                .font(Tokens.font(12.5))
                .foregroundStyle(Tokens.inkGhost)
                .padding(.horizontal, 8)
        }
    }

    private func readoutText(url: URL, host: String, tab: BrowserTab, negative: Bool) -> some View {
        let domain = HostDisplay.displayHost(HostDisplay.registrableDomain(of: host))
        let path = url.path()
        let secondary: String? = {
            if HostDisplay.pathIsShowable(path) {
                let trimmed = path.hasPrefix("/") ? String(path.dropFirst()) : path
                return trimmed.isEmpty ? nil : trimmed
            }
            return tab.title.isEmpty ? nil : tab.title
        }()

        return HStack(spacing: 5) {
            Text(domain)
                .font(Tokens.font(12.5, .medium))
                .foregroundStyle(negative ? Tokens.warning : Tokens.ink)
            if let secondary {
                Text("/")
                    .font(Tokens.font(12.5))
                    .foregroundStyle(Tokens.inkGhost)
                Text(secondary)
                    .font(Tokens.font(12.5))
                    .foregroundStyle(Tokens.inkFaint)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
    }

    private func warningChip(_ state: SecurityState) -> some View {
        Button {
            explanationShown.toggle()
        } label: {
            Text("Not private")
                .font(Tokens.font(10.5, .medium))
                .foregroundStyle(Tokens.warning)
                .padding(.horizontal, 6)
                .padding(.vertical, 2.5)
                .background(Capsule().fill(Tokens.warning.opacity(0.1)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .popover(isPresented: $explanationShown, arrowEdge: .bottom) {
            Text(state.explanation ?? "")
                .font(Tokens.font(12.5))
                .foregroundStyle(Tokens.ink)
                .lineSpacing(3)
                .frame(width: 260, alignment: .leading)
                .padding(14)
                .background(Tokens.canvas)
        }
    }
}
