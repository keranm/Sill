import AppKit
import WebKit
import Observation

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

    /// "Research, as you left it — 12 tabs" (D2a restore transition).
    private(set) var restoreBanner: String?

    /// Glance (Arc's "Peek"): a lightweight overlay shown when a link inside
    /// a Pinned/Favorited tab points outside its home domain. Non-nil shows
    /// the overlay in ShellView; reachable here (not view-local @State) so
    /// the global Cmd-W command can dismiss it instead of closing a tab.
    var glanceURL: URL?

    @ObservationIgnored private var db: Database!
    @ObservationIgnored private lazy var webKitDelegate = WebKitDelegate(store: self)
    @ObservationIgnored private var bannerTask: Task<Void, Never>?
    @ObservationIgnored private let contentBlocker = ContentBlocker()
    private(set) var observations: ObservationStore!
    private(set) var patterns: PatternStore!

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
                "SELECT id, url, title, scroll_y, is_selected, is_pinned, pinned_url FROM tab_snapshot WHERE workspace_id = ? ORDER BY sort",
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
    /// isn't also listed here (no duplicate row).
    var pinnedTabs: [BrowserTab] { activeWorkspace.tabs.filter { $0.isPinned && !isFavoriteBacked($0) } }
    var unpinnedTabs: [BrowserTab] { activeWorkspace.tabs.filter { !$0.isPinned } }

    private func isFavoriteBacked(_ tab: BrowserTab) -> Bool {
        guard let domain = tab.pinnedHomeDomain else { return false }
        return favorites.contains { DisplayNames.observationDomain(for: $0.url.host() ?? "") == domain }
    }

    var selectedTabID: BrowserTab.ID? {
        get { activeWorkspace.selectedTabID }
        set {
            activeWorkspace.selectedTabID = newValue
            if let tab = activeWorkspace.selectedTab, !tab.isMaterialized {
                materialize(tab)
            }
            persistSession()
        }
    }

    var selectedTab: BrowserTab? { activeWorkspace.selectedTab }

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
            workspace.selectedTabID = tab.id
        }
        persistSession()
        observations.recordTabEvent(kind: "tab_open", workspaceID: workspace.id.uuidString)
        return tab
    }

    func closeTab(_ tab: BrowserTab) {
        guard let workspace = workspaces.first(where: { $0.tabs.contains { $0.id == tab.id } }),
              let index = workspace.tabs.firstIndex(where: { $0.id == tab.id }) else { return }
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
        return nil
    }

    /// Reorders the unpinned list only (the rail renders pinned tabs in their
    /// own, separately-ordered section) — pinned tabs keep their existing
    /// slots in the underlying array; source/destination are indices into
    /// `unpinnedTabs`, not the full array.
    func moveTabs(from source: IndexSet, to destination: Int) {
        var reordered = unpinnedTabs
        reordered.move(fromOffsets: source, toOffset: destination)
        var next = reordered.makeIterator()
        activeWorkspace.tabs = activeWorkspace.tabs.map { $0.isPinned ? $0 : next.next()! }
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

    func removeFavorite(_ favorite: Favorite) {
        favorites.removeAll { $0.id == favorite.id }
        persistFavorites()
    }

    /// Favorites act like a Dock icon: focus the tab already anchored to that
    /// domain in this workspace if there is one, otherwise open it fresh —
    /// pinned, so outbound links open in Quick Look rather than replacing it.
    func openFavorite(_ favorite: Favorite) {
        let domain = DisplayNames.observationDomain(for: favorite.url.host() ?? favorite.url.absoluteString)
        if let existing = activeWorkspace.tabs.first(where: { $0.pinnedHomeDomain == domain }) {
            selectedTabID = existing.id
            return
        }
        let tab = BrowserTab(url: favorite.url, title: favorite.title) { [weak self] in
            self?.persistSession()
        }
        activeWorkspace.tabs.append(tab)
        materialize(tab)
        tab.pin()
        selectedTabID = tab.id
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
                    (id, workspace_id, sort, url, title, scroll_y, is_selected, is_pinned, pinned_url)
                VALUES (?,?,?,?,?,?,?,?,?)
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
