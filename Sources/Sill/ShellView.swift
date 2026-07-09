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
    @State private var panelDropTargeted = false

    /// The full rail sliding out over the stage while the rail is collapsed.
    /// The dwell before it opens is the Edge trick: long enough to click a
    /// glyph on the strip without triggering it, short enough to feel instant
    /// when you do want the full rail.
    @State private var railFlyoutShown = false
    @State private var railHoverTask: Task<Void, Never>?
    private static let flyoutDwell: Duration = .milliseconds(200)

    var body: some View {
        ZStack {
            HStack(spacing: 0) {
                if store.railCollapsed {
                    CollapsedRailView(store: store)
                        .onHover { hovering in
                            railHoverTask?.cancel()
                            guard hovering, !railFlyoutShown else { return }
                            railHoverTask = Task {
                                try? await Task.sleep(for: Self.flyoutDwell)
                                guard !Task.isCancelled else { return }
                                railFlyoutShown = true
                            }
                        }
                } else {
                    RailView(store: store)
                }

                VStack(spacing: 0) {
                    HeaderView(store: store)
                    stage
                        .padding([.horizontal, .bottom], 10)
                        .padding(.top, 2)
                }
            }
            .background(Tokens.canvas)
            .ignoresSafeArea(.container, edges: .top)
            .animation(.easeOut(duration: 0.18), value: store.railCollapsed)

            // Mounted (offscreen) the whole time the rail is collapsed, not
            // inserted on hover: an insertion transition lays the rail out at
            // its final position for one frame before the move animation
            // starts — the favorites grid visibly snapped from the strip's
            // single column to its 3-wide layout over the page. Sliding a
            // pre-laid-out view by offset can't pop.
            if store.railCollapsed {
                railFlyout
            }

            if let mode = paletteMode {
                PaletteOverlay(store: store, mode: mode, isPresented: Binding(
                    get: { paletteMode != nil },
                    set: { if !$0 { paletteMode = nil } }
                ))
            }

            if let glanceURL = store.glanceURL {
                GlanceView(store: store, url: glanceURL)
                    .animation(.easeOut(duration: 0.15), value: store.glanceURL)
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
        .onChange(of: store.railCollapsed) {
            railHoverTask?.cancel()
            railFlyoutShown = false
        }
    }

    /// The full rail floating over the stage while collapsed — content is
    /// never pushed, mirroring Arc/Edge. Leaves the flyout when the mouse
    /// does, unless a rail drag is in flight (closing mid-drag would yank
    /// the drag source out from under the drop).
    private var railFlyout: some View {
        RailView(store: store)
            .background(Tokens.canvas)
            .overlay(alignment: .trailing) {
                Rectangle()
                    .fill(Tokens.hairline)
                    .frame(width: 1)
            }
            .shadow(color: .black.opacity(0.18), radius: 18, x: 6, y: 0)
            .onHover { hovering in
                railHoverTask?.cancel()
                guard !hovering else { return }
                railHoverTask = Task {
                    try? await Task.sleep(for: .milliseconds(150))
                    guard !Task.isCancelled, store.dragState.draggingTabID == nil else { return }
                    railFlyoutShown = false
                }
            }
            // Parked just past the leading edge (rail width + shadow spill)
            // when hidden; the offset is the only thing that animates.
            .offset(x: railFlyoutShown ? 0 : -(Tokens.railWidth + 30))
            .animation(.easeOut(duration: 0.16), value: railFlyoutShown)
            .allowsHitTesting(railFlyoutShown)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .ignoresSafeArea(.container, edges: .top)
    }

    @ViewBuilder
    private var stage: some View {
        Group {
            if learningShown {
                LearningPageView(store: store) { learningShown = false }
            } else if let tab = store.selectedTab {
                if tab.isMCPClientTab {
                    MCPClientView(store: store, tab: tab)
                        .id(tab.id)
                } else if tab.isAPIClientTab {
                    APIClientView(store: store, tab: tab)
                        .id(tab.id)
                } else if let partner = store.panelPartner(of: tab) {
                    PanelSplitView(store: store, leftTab: tab.panelIsLeft ? tab : partner, rightTab: tab.panelIsLeft ? partner : tab)
                        .id(tab.panelIsLeft ? tab.id : partner.id)
                        .transition(.opacity)
                } else if case .certificateFailure(let host, let reason) = tab.securityState {
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
                        .id(tab.id)
                }
            } else {
                Tokens.stage
            }
        }
        .animation(.easeOut(duration: 0.22), value: store.selectedTab?.panelPartnerID)
        .overlay(restoreOverlay)
        .overlay(payoffOverlay)
        .overlay(panelDropTarget)
        .clipShape(RoundedRectangle(cornerRadius: Tokens.radiusStage))
        .overlay(
            RoundedRectangle(cornerRadius: Tokens.radiusStage)
                .strokeBorder(Tokens.hairline, lineWidth: 1)
        )
    }

    /// Panel view: drop a dragged rail tab onto the current page to pair
    /// them, 50/50. Only present in the hierarchy while a rail drag is
    /// actually in flight, so it never intercepts normal page interaction
    /// (scrolling, clicking links) the rest of the time — same trick as the
    /// mouse-up safety net in RailView.
    @ViewBuilder
    private var panelDropTarget: some View {
        if let draggingID = store.dragState.draggingTabID, let tab = store.selectedTab,
           tab.panelPartnerID == nil, draggingID != tab.id, !tab.isInternalTab,
           store.tabs.first(where: { $0.id == draggingID })?.isInternalTab != true {
            GeometryReader { geo in
                RoundedRectangle(cornerRadius: Tokens.radiusStage)
                    .fill(panelDropTargeted ? Tokens.accentWash : .clear)
                    .overlay(
                        RoundedRectangle(cornerRadius: Tokens.radiusStage)
                            .strokeBorder(panelDropTargeted ? Tokens.accent.opacity(0.6) : .clear, lineWidth: 2)
                    )
                    .contentShape(Rectangle())
                    .onDrop(
                        of: [.plainText],
                        delegate: PanelDropDelegate(stageWidth: geo.size.width, store: store, isTargeted: $panelDropTargeted)
                    )
            }
        }
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
