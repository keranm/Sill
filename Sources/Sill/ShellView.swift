import SwiftUI

extension Notification.Name {
    static let openImport = Notification.Name("sill.openImport")
    static let openPalette = Notification.Name("sill.openPalette")
}

/// The sidebar-first shell (D2a v2): rail on the left, the page is the stage.
struct ShellView: View {
    @Bindable var store: TabStore

    @State private var paletteMode: PaletteOverlay.Mode?
    @State private var importPresented = false
    @State private var learningShown = false

    var body: some View {
        ZStack {
            HStack(spacing: 0) {
                RailView(store: store)

                VStack(spacing: 0) {
                    HeaderView(store: store)
                    stage
                        .padding([.horizontal, .bottom], 10)
                        .padding(.top, 2)
                }
            }
            .background(Tokens.canvas)
            .ignoresSafeArea(.container, edges: .top)

            if let mode = paletteMode {
                PaletteOverlay(store: store, mode: mode, isPresented: Binding(
                    get: { paletteMode != nil },
                    set: { if !$0 { paletteMode = nil } }
                ))
            }

            // First run: the D2f consent screen, before anything else.
            if store.observations.consent == .undecided {
                ConsentView { granted in
                    store.observations.recordConsent(granted)
                    if granted {
                        importPresented = true
                    }
                }
            }
        }
        .sheet(isPresented: $importPresented) {
            ImportView(store: store, isPresented: $importPresented)
        }
        .onReceive(NotificationCenter.default.publisher(for: .openGoTo)) { _ in
            paletteMode = .goTo
        }
        .onReceive(NotificationCenter.default.publisher(for: .openPalette)) { _ in
            paletteMode = .command
        }
        .onReceive(NotificationCenter.default.publisher(for: .openImport)) { _ in
            importPresented = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .openLearning)) { _ in
            learningShown = true
        }
    }

    @ViewBuilder
    private var stage: some View {
        Group {
            if learningShown {
                LearningPageView(store: store) { learningShown = false }
            } else if let tab = store.selectedTab {
                if case .certificateFailure(let host, let reason) = tab.securityState {
                    InterstitialView(host: host, reason: reason) {
                        tab.certificateFailure = nil
                        if tab.canGoBack {
                            tab.webView?.goBack()
                        }
                    }
                } else if let webView = tab.webView, tab.url != nil {
                    WebViewContainer(webView: webView)
                        .id(tab.id)
                } else {
                    HomeView(store: store, tab: tab)
                }
            } else {
                Tokens.stage
            }
        }
        .overlay(restoreOverlay)
        .overlay(payoffOverlay)
        .clipShape(RoundedRectangle(cornerRadius: Tokens.radiusStage))
        .overlay(
            RoundedRectangle(cornerRadius: Tokens.radiusStage)
                .strokeBorder(Tokens.hairline, lineWidth: 1)
        )
    }

    /// The restore transition (D2a): context preserved, never a lone spinner.
    @ViewBuilder
    private var restoreOverlay: some View {
        if let banner = store.restoreBanner {
            ZStack {
                Tokens.stage
                Text(banner)
                    .font(Tokens.font(12.5))
                    .foregroundStyle(Tokens.inkGhost)
            }
            .transition(.opacity)
            .animation(.easeOut(duration: 0.25), value: store.restoreBanner)
        }
    }

    /// The payoff (D2c): a settled room, not confetti.
    @ViewBuilder
    private var payoffOverlay: some View {
        if let payoff = store.payoff {
            ZStack {
                Tokens.stage
                VStack(spacing: 10) {
                    Circle().fill(Tokens.accent).frame(width: 5, height: 5)
                    Text(payoff.title)
                        .font(Tokens.font(17, .semibold))
                        .foregroundStyle(Tokens.ink)
                    Text(payoff.line)
                        .font(Tokens.font(12.5))
                        .foregroundStyle(Tokens.inkFaint)
                }
            }
            .transition(.opacity)
            .animation(.easeOut(duration: 0.3), value: store.payoff?.title)
        }
    }
}
