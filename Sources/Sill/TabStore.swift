import AppKit
import WebKit
import Observation

/// Which rail list a tab belongs in — the drag-and-drop target for
/// reordering and for moving a tab between Pinned and Tabs.
enum RailSection {
    case pinned
    case unpinned
}

/// Owns workspaces and their tabs, the shared WebKit configuration, hibernation,
/// and SQLite persistence.
///
/// Login-critical configuration (documented in docs/M0-login-spike.md):
/// - `WKWebsiteDataStore.default()` — one persistent store, real logins.
/// - UA byte-identical to Safari via `applicationNameForUserAgent`.
@MainActor
@Observable
final class TabStore {
    private(set) var workspaces: [Workspace] = []
    private(set) var activeWorkspaceID: Workspace.ID!
    let downloads = DownloadsStore()

    /// Global, workspace-independent — reachable from every workspace.
    private(set) var favorites: [Favorite] = []

    /// The one shared, workspace-independent tab backing each Favorite —
    /// created lazily on first open, then kept alive for the rest of the
    /// run (never dehydrated, since it never belongs to any `Workspace.tabs`
    /// for `switchWorkspace`'s hibernation loop to find). This is the actual
    /// fix for favorites drifting into different states per workspace: there
    /// used to be one independent `BrowserTab` per workspace that had ever
    /// opened this favorite, each free to navigate away on its own. Now
    /// there's exactly one, same object no matter which workspace is active.
    private(set) var favoriteTabs: [Favorite.ID: BrowserTab] = [:]

    /// Non-nil while a Favorite's shared tab is what's actually on stage,
    /// overriding the active workspace's own selection. Cleared by selecting
    /// any ordinary tab or switching workspace — both are "I'm looking at
    /// this workspace's own tabs now," which a favorite (by definition
    /// workspace-independent) isn't part of.
    var selectedFavoriteID: Favorite.ID?

    /// "Research, as you left it — 12 tabs" (D2a restore transition).
    private(set) var restoreBanner: String?

    /// Glance (Arc's "Peek"): a lightweight overlay shown when a link inside
    /// a Pinned/Favorited tab points outside its home domain. Non-nil shows
    /// the overlay in ShellView; reachable here (not view-local @State) so
    /// the global Cmd-W command can dismiss it instead of closing a tab.
    var glanceURL: URL?

    /// Set right after creating a tab that should land on Home with the
    /// search field already focused (⌘T, the rail's "+ New tab"). Checked by
    /// HomeView's own `.onAppear` — the moment it actually mounts, not a
    /// fire-and-forget notification that can be posted before the new tab's
    /// view exists yet to hear it.
    var focusRequestedTabID: BrowserTab.ID?

    /// Cross-view drag-and-drop UI state (rail reordering, and the stage's
    /// Panel-view drop target both need it) — lives here, not as view-local
    /// @State, since RailView and ShellView are siblings.
    let dragState = TabReorderState()

    @ObservationIgnored private var db: Database!
    @ObservationIgnored private lazy var webKitDelegate = WebKitDelegate(store: self)
    @ObservationIgnored private var bannerTask: Task<Void, Never>?
    @ObservationIgnored private let contentBlocker = ContentBlocker()
    private(set) var observations: ObservationStore!
    private(set) var patterns: PatternStore!
    private(set) var apiClient: APIClientStore!
    private(set) var mcpClient: MCPClientStore!

    /// The payoff moment after confirming a card (D2c): quietly momentous,
    /// a settled room, no confetti.
    private(set) var payoff: (title: String, line: String)?

    static let safariUASuffix = "Version/26.0 Safari/605.1.15"

    // MARK: - Init and schema

    init(databasePath: String? = nil) {
        do {
            let path = try databasePath ?? Self.defaultDatabasePath()
            db = try Database(path: path)
            try createSchema()
            migrateColumns()
            observations = ObservationStore(db: db)
            apiClient = APIClientStore(db: db)
            mcpClient = MCPClientStore(db: db)
            try loadWorkspaces()
            try loadFavorites()
            migrateLegacySessionIfNeeded()
        } catch {
            fatalError("Sill cannot open its database: \(error)")
        }

        if workspaces.isEmpty {
            let everythingElse = Workspace(name: "Everything else", isEverythingElse: true)
            workspaces = [everythingElse]
            activeWorkspaceID = everythingElse.id
            try? persistWorkspaceRow(everythingElse, sort: 0)
            saveAppState()
        }
        contentBlocker.compile()
        patterns = PatternStore(db: db, tabStore: self)
        if activeWorkspace.tabs.isEmpty {
            newTab()
        } else {
            materializeSelected(in: activeWorkspace)
        }
    }

    /// Confirm's one sanctioned action (PRD §3.5): the workspace is born
    /// pre-populated and the shell lands in it, payoff on the stage.
    func birthWorkspace(named name: String, urls: [URL], payoff payoffLine: String) async {
        let workspace = createWorkspace(named: name)
        for url in urls {
            let tab = BrowserTab(url: url, title: url.host() ?? "Tab") { [weak self] in
                self?.persistSession()
            }
            workspace.tabs.append(tab)
        }
        workspace.selectedTabID = workspace.tabs.first?.id
        await switchWorkspace(to: workspace.id)
        restoreBanner = nil
        payoff = (title: name, line: payoffLine)
        bannerTask?.cancel()
        bannerTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            self?.payoff = nil
        }
    }

    /// The one local database (engine runs, dev flags, demo seed share it).
    var database: Database { db }

    static func defaultDatabasePath() throws -> String {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Sill", isDirectory: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        return support.appendingPathComponent("sill.sqlite").path
    }

    private func createSchema() throws {
        try db.execute("""
            CREATE TABLE IF NOT EXISTS workspace (
                id TEXT PRIMARY KEY,
                name TEXT NOT NULL,
                sort INTEGER NOT NULL,
                is_everything_else INTEGER NOT NULL DEFAULT 0,
                created_at REAL NOT NULL
            );
            CREATE TABLE IF NOT EXISTS tab_snapshot (
                id TEXT PRIMARY KEY,
                workspace_id TEXT NOT NULL REFERENCES workspace(id) ON DELETE CASCADE,
                sort INTEGER NOT NULL,
                url TEXT,
                title TEXT NOT NULL DEFAULT 'New Tab',
                scroll_y REAL NOT NULL DEFAULT 0,
                is_selected INTEGER NOT NULL DEFAULT 0
            );
            CREATE TABLE IF NOT EXISTS app_state (
                key TEXT PRIMARY KEY,
                value TEXT NOT NULL
            );
            CREATE TABLE IF NOT EXISTS favorite (
                id TEXT PRIMARY KEY,
                sort INTEGER NOT NULL,
                url TEXT NOT NULL,
                title TEXT NOT NULL DEFAULT ''
            );
            """)
    }

    private func migrateColumns() {
        try? db.execute("ALTER TABLE tab_snapshot ADD COLUMN is_pinned INTEGER NOT NULL DEFAULT 0")
        try? db.execute("ALTER TABLE tab_snapshot ADD COLUMN pinned_url TEXT")
        try? db.execute("ALTER TABLE tab_snapshot ADD COLUMN panel_partner_id TEXT")
        try? db.execute("ALTER TABLE tab_snapshot ADD COLUMN panel_is_left INTEGER NOT NULL DEFAULT 0")
        try? db.execute("ALTER TABLE tab_snapshot ADD COLUMN panel_split_ratio REAL NOT NULL DEFAULT 0.5")
    }

    private func loadWorkspaces() throws {
        let workspaceRows = try db.query("SELECT id, name, is_everything_else FROM workspace ORDER BY sort")
        for row in workspaceRows {
            guard let idText = row.text("id"), let id = UUID(uuidString: idText),
                  let name = row.text("name") else { continue }
            let workspace = Workspace(
                id: id,
                name: name,
                isEverythingElse: row.int("is_everything_else") == 1
            )
            let tabRows = try db.query(
                """
                SELECT id, url, title, scroll_y, is_selected, is_pinned, pinned_url,
                    panel_partner_id, panel_is_left, panel_split_ratio
                FROM tab_snapshot WHERE workspace_id = ? ORDER BY sort
                """,
                [.text(idText)]
            )
            for tabRow in tabRows {
                guard let tabIDText = tabRow.text("id"), let tabID = UUID(uuidString: tabIDText) else { continue }
                let tab = BrowserTab(
                    id: tabID,
                    url: tabRow.text("url").flatMap(URL.init(string:)),
                    title: tabRow.text("title") ?? "New Tab",
                    scrollY: tabRow.real("scroll_y") ?? 0,
                    isPinned: tabRow.int("is_pinned") == 1,
                    pinnedURL: tabRow.text("pinned_url").flatMap(URL.init(string:)),
                    panelPartnerID: tabRow.text("panel_partner_id").flatMap(UUID.init(uuidString:)),
                    panelIsLeft: tabRow.int("panel_is_left") == 1,
                    panelSplitRatio: tabRow.real("panel_split_ratio") ?? 0.5,
                    onStateChange: { [weak self] in self?.persistSession() }
                )
                workspace.tabs.append(tab)
                if tabRow.int("is_selected") == 1 {
                    workspace.selectedTabID = tab.id
                }
            }
            if workspace.selectedTabID == nil {
                workspace.selectedTabID = workspace.tabs.first?.id
            }
            workspaces.append(workspace)
        }

        if let activeText = try db.query("SELECT value FROM app_state WHERE key = 'active_workspace'").first?.text("value"),
           let activeID = UUID(uuidString: activeText),
           workspaces.contains(where: { $0.id == activeID }) {
            activeWorkspaceID = activeID
        } else {
            activeWorkspaceID = workspaces.first?.id
        }
    }

    private func loadFavorites() throws {
        let rows = try db.query("SELECT id, url, title FROM favorite ORDER BY sort")
        favorites = rows.compactMap { row in
            guard let idText = row.text("id"), let id = UUID(uuidString: idText),
                  let urlText = row.text("url"), let url = URL(string: urlText) else { return nil }
            return Favorite(id: id, url: url, title: row.text("title") ?? "")
        }
    }

    private func persistFavorites() {
        guard let db else { return }
        try? db.run("DELETE FROM favorite")
        for (index, favorite) in favorites.enumerated() {
            try? db.run(
                "INSERT INTO favorite (id, sort, url, title) VALUES (?,?,?,?)",
                [.text(favorite.id.uuidString), .int(Int64(index)), .text(favorite.url.absoluteString), .text(favorite.title)]
            )
        }
    }

    /// One-time migration from the M0/M1 UserDefaults session.
    private func migrateLegacySessionIfNeeded() {
        struct LegacySession: Codable { var urls: [String]; var selectedIndex: Int }
        let key = "sill.session.v1"
        guard workspaces.isEmpty,
              let data = UserDefaults.standard.data(forKey: key),
              let legacy = try? JSONDecoder().decode(LegacySession.self, from: data) else { return }
        let everythingElse = Workspace(name: "Everything else", isEverythingElse: true)
        for urlString in legacy.urls {
            guard let url = URL(string: urlString) else { continue }
            everythingElse.tabs.append(BrowserTab(url: url, title: url.host() ?? "Tab") { [weak self] in
                self?.persistSession()
            })
        }
        let index = min(max(legacy.selectedIndex, 0), max(everythingElse.tabs.count - 1, 0))
        everythingElse.selectedTabID = everythingElse.tabs.isEmpty ? nil : everythingElse.tabs[index].id
        workspaces = [everythingElse]
        activeWorkspaceID = everythingElse.id
        try? persistWorkspaceRow(everythingElse, sort: 0)
        persistTabs(of: everythingElse)
        saveAppState()
        UserDefaults.standard.removeObject(forKey: key)
    }

    // MARK: - Workspace accessors

    var activeWorkspace: Workspace {
        workspaces.first { $0.id == activeWorkspaceID } ?? workspaces[0]
    }

    /// Before the first user workspace exists, Sill has a single unnamed
    /// context — "Everything else" is only *born* (becomes visible) with the
    /// first user workspace (PRD §4.2).
    var hasUserWorkspaces: Bool {
        workspaces.contains { !$0.isEverythingElse }
    }

    var dormantWorkspaces: [Workspace] {
        guard hasUserWorkspaces else { return [] }
        return workspaces.filter { $0.id != activeWorkspaceID }
    }

    var railTitle: String {
        hasUserWorkspaces ? activeWorkspace.name : "Sill"
    }

    // MARK: - Tab accessors (the views' surface)

    var tabs: [BrowserTab] { activeWorkspace.tabs }

    /// Pinned Tabs (PRD-adjacent, owner-requested): tabs you want to stick
    /// around, shown above the regular list, never auto-archived. Excludes
    /// tabs opened from a Favorite — the favorite chip *is* that tab, so it
    /// isn't also listed here (no duplicate row) — and the follower side of
    /// a Panel, which the leader's merged row speaks for.
    var pinnedTabs: [BrowserTab] { activeWorkspace.tabs.filter { $0.isPinned && !isHiddenFromRail($0) } }
    var unpinnedTabs: [BrowserTab] { activeWorkspace.tabs.filter { !$0.isPinned && !isHiddenFromRail($0) } }

    /// A tab is hidden from its section's rail row when something else
    /// already speaks for it — a Favorite chip, or a Panel's merged row.
    /// One shared predicate so `pinnedTabs`, `unpinnedTabs`, and `placeTab`'s
    /// storage reconstruction can never disagree on what counts as hidden.
    private func isHiddenFromRail(_ tab: BrowserTab) -> Bool {
        isFavoriteBacked(tab) || isPanelFollower(tab)
    }

    private func isFavoriteBacked(_ tab: BrowserTab) -> Bool {
        guard let domain = tab.pinnedHomeDomain else { return false }
        return favorites.contains { DisplayNames.observationDomain(for: $0.url.host() ?? "") == domain }
    }

    private func isPanelFollower(_ tab: BrowserTab) -> Bool {
        tab.panelPartnerID != nil && !tab.panelIsLeft
    }

    /// The workspace holding `tab` — shared by every close/panel operation
    /// that needs to find it, so there's exactly one place that knows how.
    private func workspace(containing tab: BrowserTab) -> Workspace? {
        workspaces.first { $0.tabs.contains { $0.id == tab.id } }
    }

    // MARK: - Panel view (owner's "Panel view", Arc's Split View)

    func panelPartner(of tab: BrowserTab, in workspace: Workspace) -> BrowserTab? {
        guard let partnerID = tab.panelPartnerID else { return nil }
        return workspace.tabs.first { $0.id == partnerID }
    }

    func panelPartner(of tab: BrowserTab) -> BrowserTab? {
        panelPartner(of: tab, in: activeWorkspace)
    }

    /// Pairs the current page with `dragged` — a 50/50 split, `current`
    /// `draggedOnLeft` matches wherever the drop actually landed — dropping
    /// on the left half of the stage puts the dragged-in tab on the left and
    /// pushes the current page right, and vice versa, rather than always
    /// defaulting to one fixed side. Declines if either side is already
    /// paneled (no 3-way splits yet), they're the same tab, either side is
    /// the API client, or either side is a Favorite's shared tab — pairing a
    /// tab that follows the user across every workspace with one that
    /// belongs to just this workspace would leave a dangling partner
    /// reference the moment the workspace changes.
    func formPanel(with dragged: BrowserTab, draggedOnLeft: Bool) {
        guard let current = selectedTab,
              current.id != dragged.id,
              current.panelPartnerID == nil,
              dragged.panelPartnerID == nil,
              !current.isInternalTab,
              !dragged.isInternalTab,
              !isFavoriteTab(current),
              !isFavoriteTab(dragged) else { return }
        current.panelPartnerID = dragged.id
        dragged.panelPartnerID = current.id
        current.panelIsLeft = !draggedOnLeft
        dragged.panelIsLeft = draggedOnLeft
        current.panelSplitRatio = 0.5
        dragged.panelSplitRatio = 0.5
        materialize(dragged)
        persistSession()
    }

    /// "Separate Panels": un-pairs both sides back into two ordinary tabs,
    /// each reappearing in its own rail row wherever its pin state puts it.
    func separatePanel(_ tab: BrowserTab) {
        guard let workspace = workspace(containing: tab),
              let partner = panelPartner(of: tab, in: workspace) else { return }
        tab.panelPartnerID = nil
        tab.panelIsLeft = false
        partner.panelPartnerID = nil
        partner.panelIsLeft = false
        persistSession()
    }

    /// Reads never observably land on a hidden Panel follower — whichever
    /// side becomes the follower (via `formPanel`'s asymmetric drop side, or
    /// any future path that sets this to a tab that later becomes a
    /// follower) transparently resolves to its leader, since the follower
    /// has no rail row for an `isSelected`/highlight check to match against.
    var selectedTabID: BrowserTab.ID? {
        get {
            guard selectedFavoriteID == nil else { return nil }
            guard let raw = activeWorkspace.selectedTabID,
                  let tab = activeWorkspace.tabs.first(where: { $0.id == raw }) else { return activeWorkspace.selectedTabID }
            if isPanelFollower(tab), let partner = panelPartner(of: tab, in: activeWorkspace) {
                return partner.id
            }
            return raw
        }
        set {
            selectedFavoriteID = nil
            activeWorkspace.selectedTabID = newValue
            if let tab = activeWorkspace.selectedTab {
                if !tab.isMaterialized {
                    materialize(tab)
                }
                if let partner = panelPartner(of: tab), !partner.isMaterialized {
                    materialize(partner)
                }
            }
            persistSession()
        }
    }

    var selectedTab: BrowserTab? {
        if let selectedFavoriteID {
            return favoriteTabs[selectedFavoriteID]
        }
        guard let id = selectedTabID else { return nil }
        return activeWorkspace.tabs.first { $0.id == id }
    }

    // MARK: - WebView construction

    private func makeConfiguration() -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.applicationNameForUserAgent = Self.safariUASuffix
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.preferences.isFraudulentWebsiteWarningEnabled = true
        configuration.preferences.isElementFullscreenEnabled = true
        return configuration
    }

    /// Popups must be built from the configuration WebKit hands us, or the
    /// opener relationship login flows rely on breaks.
    func makeWebView(configuration: WKWebViewConfiguration? = nil) -> WKWebView {
        let webView = WKWebView(frame: .zero, configuration: configuration ?? makeConfiguration())
        contentBlocker.attach(to: webView.configuration.userContentController)
        webView.navigationDelegate = webKitDelegate
        webView.uiDelegate = webKitDelegate
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsMagnification = true
        // Developer tooling commitment (developer-tools.md #1): Safari's own
        // Web Inspector, always on, no custom build. `isInspectable` used to
        // be the whole story, but the context menu's "Inspect Element" (and
        // the programmatic show() in DeveloperTools.swift) turned out to
        // also gate on WebKit's older private developer-extras preference —
        // without it, the menu item simply doesn't appear. Same guarded
        // private-API risk tier as _inspector itself.
        webView.isInspectable = true
        let preferences = webView.configuration.preferences
        if preferences.responds(to: NSSelectorFromString("_setDeveloperExtrasEnabled:")) {
            preferences.setValue(true, forKey: "developerExtrasEnabled")
        }
        JSONFormatting.attach(to: webView.configuration.userContentController)
        return webView
    }

    func materialize(_ tab: BrowserTab) {
        guard !tab.isMaterialized else { return }
        tab.materialize(webView: makeWebView())
    }

    private func materializeSelected(in workspace: Workspace) {
        if workspace.selectedTabID == nil {
            workspace.selectedTabID = workspace.tabs.first?.id
        }
        if let tab = workspace.selectedTab {
            materialize(tab)
            if let partner = panelPartner(of: tab, in: workspace) {
                materialize(partner)
            }
        }
    }

    // MARK: - Workspace lifecycle (PRD §4.2)

    /// Creates without switching; call sites decide when to switch. The moment
    /// the first user workspace is born, the existing unnamed context becomes
    /// the visible "Everything else" (PRD §4.2).
    @discardableResult
    func createWorkspace(named name: String) -> Workspace {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let workspace = Workspace(name: trimmed.isEmpty ? "New workspace" : trimmed)
        workspaces.append(workspace)
        persistAllWorkspaceRows()
        return workspace
    }

    func renameWorkspace(_ workspace: Workspace, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        workspace.name = trimmed
        persistAllWorkspaceRows()
    }

    /// Deleting a workspace folds its tabs back into "Everything else".
    func deleteWorkspace(_ workspace: Workspace) {
        guard workspaces.count > 1 else { return }
        if workspace.isEverythingElse {
            // Undeletable while it is the only other context; and if user
            // workspaces exist, unclaimed tabs need somewhere to live.
            return
        }
        let everythingElse = workspaces.first { $0.isEverythingElse }
        for tab in workspace.tabs {
            Task { await tab.dehydrate() }
            everythingElse?.tabs.append(tab)
        }
        workspaces.removeAll { $0.id == workspace.id }
        try? db.run("DELETE FROM workspace WHERE id = ?", [.text(workspace.id.uuidString)])
        persistAllWorkspaceRows()
        if let everythingElse {
            persistTabs(of: everythingElse)
        }
        if activeWorkspaceID == workspace.id {
            Task { await self.switchWorkspace(to: (everythingElse ?? workspaces[0]).id) }
        }
    }

    /// The restore transition (D2a): departing workspace fully hibernates —
    /// every WKWebView deallocated after a scroll snapshot; arriving rail
    /// rebuilds instantly from in-memory snapshots; selected page rematerializes.
    func switchWorkspace(to id: Workspace.ID) async {
        guard id != activeWorkspaceID,
              let arriving = workspaces.first(where: { $0.id == id }) else { return }
        let departing = activeWorkspace
        // A Favorite's shared tab isn't part of any workspace — switching
        // away from it is switching away from favorites entirely, back to
        // whichever workspace tab was last selected there.
        selectedFavoriteID = nil

        persistTabs(of: departing)
        for tab in departing.tabs {
            await tab.dehydrate()
        }
        persistTabs(of: departing) // now with scroll positions

        activeWorkspaceID = id
        saveAppState()
        observations.recordTabEvent(kind: "workspace_switch", workspaceID: id.uuidString)

        if arriving.tabs.isEmpty {
            newTab()
        } else {
            // Snapshot immediately — a freshly birthed workspace's non-selected
            // tabs have no live webview yet, so nothing would otherwise persist
            // them before the *next* time this workspace is left. A quit in
            // between would silently lose them.
            persistTabs(of: arriving)
            let count = arriving.tabs.count
            showRestoreBanner("\(arriving.name), as you left it — \(count) tab\(count == 1 ? "" : "s")")
            materializeSelected(in: arriving)
        }
    }

    private func showRestoreBanner(_ text: String) {
        restoreBanner = text
        bannerTask?.cancel()
        bannerTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2.2))
            guard !Task.isCancelled else { return }
            self?.restoreBanner = nil
        }
    }

    // MARK: - Tab lifecycle

    /// Popup tabs remember their opener: they sit next to it, and closing them
    /// hands selection back to the opener.
    @ObservationIgnored private var openerByTabID = [BrowserTab.ID: BrowserTab.ID]()

    @discardableResult
    func newTab(
        url: URL? = nil,
        configuration: WKWebViewConfiguration? = nil,
        select: Bool = true,
        openedFrom opener: BrowserTab? = nil
    ) -> BrowserTab {
        let tab = BrowserTab(url: url) { [weak self] in
            self?.persistSession()
        }
        tab.materialize(webView: makeWebView(configuration: configuration))
        let workspace = activeWorkspace
        if let opener, let openerIndex = workspace.tabs.firstIndex(where: { $0.id == opener.id }) {
            workspace.tabs.insert(tab, at: openerIndex + 1)
            openerByTabID[tab.id] = opener.id
        } else {
            workspace.tabs.append(tab)
        }
        if select {
            // Through the store-level setter, not workspace.selectedTabID:
            // it clears selectedFavoriteID, which otherwise keeps the
            // favorite on screen and hides the new tab.
            selectedTabID = tab.id
        }
        persistSession()
        observations.recordTabEvent(kind: "tab_open", workspaceID: workspace.id.uuidString)
        return tab
    }

    /// developer-tools.md #3's API client, as an ordinary tab — a `BrowserTab`
    /// with the internal `sill://` scheme instead of a real webpage.
    /// `isMaterialized` already treats this scheme as always-materialized
    /// (BrowserTab.swift), so no webview is ever created for it.
    @discardableResult
    func newAPIClientTab(select: Bool = true) -> BrowserTab {
        let tab = BrowserTab(url: URL(string: "sill://api-client"), title: "API Client") { [weak self] in
            self?.persistSession()
        }
        let workspace = activeWorkspace
        workspace.tabs.append(tab)
        if select {
            selectedTabID = tab.id
        }
        persistSession()
        return tab
    }

    /// Right-click → "Open in API Client": a new API client tab with the
    /// link prefilled as a GET, ready to send. If the URL turns out to be
    /// an OpenAPI/Swagger/Postman spec, it's also imported as a browsable
    /// collection — the same `APISpecParser.detect` path the header's
    /// import button and the sidebar's Import URL… already use.
    func openInAPIClient(url: URL) {
        let tab = newAPIClientTab()
        // A fresh API client tab seeds its first request tab with the
        // browser tab's own id (see APIClientStore.requestTabsState), so
        // this draft is the one on screen.
        let draft = apiClient.draftState(for: tab.id)
        draft.method = "GET"
        draft.urlText = url.absoluteString
        apiClient.scheduleDraftPersist(tabID: tab.id, draft: draft)

        Task { [weak self] in
            guard let (data, _) = try? await URLSession.shared.data(from: url),
                  let json = try? JSONSerialization.jsonObject(with: data),
                  let collection = APISpecParser.detect(json, name: url.deletingPathExtension().lastPathComponent, sourceURL: url) else { return }
            self?.apiClient.importCollection(collection)
        }
    }

    /// The MCP explorer, the API client's sibling — same `sill://` internal-tab
    /// machinery, different host so ShellView routes it to `MCPClientView`.
    @discardableResult
    func newMCPClientTab(select: Bool = true) -> BrowserTab {
        let tab = BrowserTab(url: URL(string: "sill://mcp-client"), title: "MCP Explorer") { [weak self] in
            self?.persistSession()
        }
        let workspace = activeWorkspace
        workspace.tabs.append(tab)
        if select {
            selectedTabID = tab.id
        }
        persistSession()
        return tab
    }

    /// Closing a paneled tab closes its partner too — a Panel is one unit to
    /// close, even though every call site (Cmd-W, the merged row's single X)
    /// just closes "the tab" without needing to know panels exist. Un-pairs
    /// in memory only (no persist) rather than routing through
    /// `separatePanel` — both tabs are about to be removed anyway, so
    /// there's no reason to write the briefly-unpaired state to disk first.
    func closeTab(_ tab: BrowserTab) {
        if let workspace = workspace(containing: tab),
           let partner = panelPartner(of: tab, in: workspace) {
            tab.panelPartnerID = nil
            tab.panelIsLeft = false
            partner.panelPartnerID = nil
            partner.panelIsLeft = false
            closeTabIndividually(partner)
        }
        closeTabIndividually(tab)
    }

    private func closeTabIndividually(_ tab: BrowserTab) {
        guard let workspace = workspace(containing: tab),
              let index = workspace.tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        if tab.isAPIClientTab {
            apiClient.removeAllRequestTabs(for: tab.id)
        }
        if tab.isMCPClientTab {
            mcpClient.removeTabState(for: tab.id)
        }
        workspace.tabs.remove(at: index)
        Task { await tab.dehydrate() }
        let openerID = openerByTabID.removeValue(forKey: tab.id)
        observations.recordTabEvent(kind: "tab_close", workspaceID: workspace.id.uuidString)
        if workspace.id == activeWorkspaceID {
            if workspace.tabs.isEmpty {
                newTab()
                return
            }
            if workspace.selectedTabID == tab.id {
                if let openerID, workspace.tabs.contains(where: { $0.id == openerID }) {
                    selectedTabID = openerID
                } else {
                    selectedTabID = workspace.tabs[min(index, workspace.tabs.count - 1)].id
                }
            }
        }
        persistTabs(of: workspace)
    }

    func closeTab(webView: WKWebView) {
        if let tab = tab(for: webView) {
            closeTab(tab)
        }
    }

    func tab(for webView: WKWebView) -> BrowserTab? {
        for workspace in workspaces {
            if let tab = workspace.tabs.first(where: { $0.webView === webView }) {
                return tab
            }
        }
        // Favorite-backed tabs live outside every workspace (openFavorite),
        // but their webviews still route here — without this, Glance never
        // fires for links inside a favorite and outbound clicks leak into
        // plain new tabs.
        return favoriteTabs.values.first { $0.webView === webView }
    }

    /// Places `tab` at `index` within `section`'s visible order (drag-to-
    /// reorder within a section, or drag between Pinned and Tabs — pinning or
    /// unpinning as needed to match). Favorite-backed pinned tabs and Panel
    /// followers are both hidden from the rail lists (something else stands
    /// in for them — the favorite chip, or the leader's merged row), so
    /// their relative position is inconsequential; they're preserved
    /// untouched and only the two *visible* orders are reconstructed around
    /// the moved tab. (`tab` here is never itself a follower or favorite-
    /// backed — neither has a rail row to drag from.)
    /// A blank tab (no URL yet) can't actually be pinned — `BrowserTab.pin()`
    /// silently no-ops without one, same as the disabled "Pin Tab" menu item
    /// — so dropping one onto Pinned must decline the whole move rather than
    /// still splicing it into the pinned position while it's really still
    /// unpinned (it would then reappear, misplaced, next time `unpinnedTabs`
    /// is read, since that reads the real `isPinned` flag, not array position).
    func placeTab(_ tab: BrowserTab, inSection section: RailSection, atIndex index: Int) {
        if section == .pinned, !tab.isPinned {
            guard tab.url != nil else { return }
            tab.pin()
            if let url = tab.url {
                discoverAndCacheFavicon(for: url, sourceTab: tab)
            }
        } else if section == .unpinned, tab.isPinned {
            tab.unpin()
        }

        let hidden = activeWorkspace.tabs.filter { isHiddenFromRail($0) && $0.id != tab.id }
        var pinnedVisible = pinnedTabs.filter { $0.id != tab.id }
        var unpinnedVisible = unpinnedTabs.filter { $0.id != tab.id }

        switch section {
        case .pinned:
            pinnedVisible.insert(tab, at: min(max(index, 0), pinnedVisible.count))
        case .unpinned:
            unpinnedVisible.insert(tab, at: min(max(index, 0), unpinnedVisible.count))
        }

        activeWorkspace.tabs = hidden + pinnedVisible + unpinnedVisible
        persistSession()
    }

    func pin(_ tab: BrowserTab) {
        tab.pin()
        persistSession()
        if let url = tab.url {
            discoverAndCacheFavicon(for: url, sourceTab: tab)
        }
    }

    func unpin(_ tab: BrowserTab) {
        tab.unpin()
        persistSession()
    }

    /// "Reset Tab": back to the URL it was pinned at.
    func resetPinnedTab(_ tab: BrowserTab) {
        guard let pinnedURL = tab.pinnedURL else { return }
        materialize(tab)
        tab.load(pinnedURL)
    }

    /// Promotes a Quick Look tab (materialized outside any workspace) into a
    /// real one, preserving its already-loaded webview and session.
    func adopt(_ tab: BrowserTab, into workspace: Workspace) {
        workspace.tabs.append(tab)
        workspace.selectedTabID = tab.id
        if workspace.id == activeWorkspace.id {
            selectedFavoriteID = nil
        }
        persistTabs(of: workspace)
        observations.recordTabEvent(kind: "tab_open", workspaceID: workspace.id.uuidString)
    }

    // MARK: - Favorites ("Pinned Tabs accessible in every Space")

    func addFavorite(title: String, url: URL, sourceTab: BrowserTab?) {
        guard favorites.count < Favorite.maxCount else { return }
        let domain = DisplayNames.observationDomain(for: url.host() ?? url.absoluteString)
        guard !favorites.contains(where: { DisplayNames.observationDomain(for: $0.url.host() ?? "") == domain }) else { return }

        favorites.append(Favorite(id: UUID(), url: url, title: title))
        persistFavorites()

        // Favoriting converts the tab — it disappears from the list as the
        // favorite appears, not a duplicate. Discovery runs first so closing
        // (and tearing down the webview) can't race the JS evaluation.
        discoverAndCacheFavicon(for: url, sourceTab: sourceTab) { [weak self] in
            if let sourceTab { self?.closeTab(sourceTab) }
        }
    }

    /// The shared tab currently backing a favorite, if it's ever been opened
    /// this run — `nil` means nobody's clicked this favorite chip yet.
    func backingTab(for favorite: Favorite) -> BrowserTab? {
        favoriteTabs[favorite.id]
    }

    private func isFavoriteTab(_ tab: BrowserTab) -> Bool {
        favoriteTabs.values.contains { $0.id == tab.id }
    }

    /// Removing a favorite demotes its shared tab (if it was ever opened)
    /// back into an ordinary Tabs-stack tab in the *current* workspace — it
    /// must not stay stranded with no workspace at all, and it must not
    /// close. If it was what's currently on stage, selection moves to it in
    /// its new, ordinary home rather than leaving the stage blank.
    func removeFavorite(_ favorite: Favorite) {
        favorites.removeAll { $0.id == favorite.id }
        persistFavorites()
        guard let tab = favoriteTabs.removeValue(forKey: favorite.id) else { return }
        tab.unpin()
        activeWorkspace.tabs.append(tab)
        persistTabs(of: activeWorkspace)
        if selectedFavoriteID == favorite.id {
            selectedTabID = tab.id
        }
    }

    /// Favorites act like a Dock icon: the same shared tab regardless of
    /// which workspace is active, created lazily on first open and kept
    /// alive (never dehydrated — it never belongs to any workspace's `tabs`
    /// for `switchWorkspace`'s hibernation loop to find) for the rest of the
    /// run. Pinned, so outbound links open in Quick Look rather than
    /// replacing it.
    func openFavorite(_ favorite: Favorite) {
        if let existing = favoriteTabs[favorite.id] {
            materialize(existing)
            selectedFavoriteID = favorite.id
            return
        }
        let tab = BrowserTab(url: favorite.url, title: favorite.title) { [weak self] in
            self?.persistSession()
        }
        favoriteTabs[favorite.id] = tab
        materialize(tab)
        tab.pin()
        selectedFavoriteID = favorite.id
        observations.recordTabEvent(kind: "tab_open", workspaceID: activeWorkspace.id.uuidString)
    }

    /// Persisted favicon fetch for Pinned/Favorited tabs: discover the page's
    /// declared icon via JS against its live webview when possible (most
    /// accurate), then hand off to FaviconStore's disk-cached fetch.
    private func discoverAndCacheFavicon(for url: URL, sourceTab: BrowserTab?, then completion: @escaping () -> Void = {}) {
        if let webView = sourceTab?.webView {
            webView.evaluateJavaScript(FaviconStore.discoveryScript) { result, _ in
                FaviconStore.shared.fetchAndCache(for: url, discoveredIconURLString: result as? String)
                completion()
            }
        } else {
            FaviconStore.shared.fetchAndCache(for: url)
            completion()
        }
    }

    // MARK: - Navigation input

    func navigate(_ input: String, in tab: BrowserTab) {
        // An internal tab has no webview to load into — `tab.load` would
        // silently overwrite its `sill://` URL with the typed destination,
        // stranding it with neither the client nor a live page (issue found
        // in review, before this guard existed). Open the destination
        // elsewhere instead of destroying the tab.
        guard !tab.isInternalTab else {
            openInNewTab(input)
            return
        }
        if let destination = Self.destination(for: input) {
            materialize(tab)
            tab.transitionHint = "typed"
            tab.load(destination)
        }
    }

    func openInNewTab(_ input: String) {
        if let destination = Self.destination(for: input) {
            let tab = newTab(url: destination)
            tab.transitionHint = "typed"
        }
    }

    /// Everything the observation event needs about a visit in this shell.
    func observationContext(for tab: BrowserTab) -> (workspaceID: String?, openDomains: [String]) {
        let workspace = workspaces.first { $0.tabs.contains { $0.id == tab.id } }
        let domains = (workspace?.tabs ?? []).compactMap { $0.url?.host() }
        return (workspace?.id.uuidString, domains)
    }

    nonisolated static func destination(for input: String) -> URL? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.contains(" ") || (!trimmed.contains(".") && !trimmed.contains("localhost")) {
            var components = URLComponents(string: "https://www.google.com/search")!
            components.queryItems = [URLQueryItem(name: "q", value: trimmed)]
            return components.url
        }
        if trimmed.lowercased().hasPrefix("http://") || trimmed.lowercased().hasPrefix("https://") {
            return URL(string: trimmed)
        }
        return URL(string: "https://" + trimmed)
    }

    // MARK: - Persistence (synchronous, PRD §2)

    func persistSession() {
        persistTabs(of: activeWorkspace)
    }

    private func persistTabs(of workspace: Workspace) {
        guard let db else { return }
        try? db.run("DELETE FROM tab_snapshot WHERE workspace_id = ?", [.text(workspace.id.uuidString)])
        for (index, tab) in workspace.tabs.enumerated() {
            try? db.run(
                """
                INSERT INTO tab_snapshot
                    (id, workspace_id, sort, url, title, scroll_y, is_selected, is_pinned, pinned_url,
                     panel_partner_id, panel_is_left, panel_split_ratio)
                VALUES (?,?,?,?,?,?,?,?,?,?,?,?)
                """,
                [
                    .text(tab.id.uuidString),
                    .text(workspace.id.uuidString),
                    .int(Int64(index)),
                    tab.url.map { .text($0.absoluteString) } ?? .null,
                    .text(tab.title),
                    .real(tab.pendingScrollY),
                    .int(workspace.selectedTabID == tab.id ? 1 : 0),
                    .int(tab.isPinned ? 1 : 0),
                    tab.pinnedURL.map { .text($0.absoluteString) } ?? .null,
                    tab.panelPartnerID.map { .text($0.uuidString) } ?? .null,
                    .int(tab.panelIsLeft ? 1 : 0),
                    .real(tab.panelSplitRatio),
                ]
            )
        }
    }

    private func persistWorkspaceRow(_ workspace: Workspace, sort: Int) throws {
        try db.run(
            "INSERT OR REPLACE INTO workspace (id, name, sort, is_everything_else, created_at) VALUES (?,?,?,?,?)",
            [
                .text(workspace.id.uuidString),
                .text(workspace.name),
                .int(Int64(sort)),
                .int(workspace.isEverythingElse ? 1 : 0),
                .real(Date().timeIntervalSince1970),
            ]
        )
    }

    private func persistAllWorkspaceRows() {
        for (index, workspace) in workspaces.enumerated() {
            try? persistWorkspaceRow(workspace, sort: index)
        }
    }

    private func saveAppState() {
        try? db.run(
            "INSERT OR REPLACE INTO app_state (key, value) VALUES ('active_workspace', ?)",
            [.text(activeWorkspaceID.uuidString)]
        )
    }

    /// Best-effort full persistence at quit.
    func persistEverything() {
        persistAllWorkspaceRows()
        for workspace in workspaces {
            persistTabs(of: workspace)
        }
        saveAppState()
    }
}
