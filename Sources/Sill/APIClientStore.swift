import Foundation
import Observation

/// A past request, replayable from the history list.
struct APIHistoryEntry: Identifiable {
    let id: UUID
    let timestamp: Date
    var method: String
    var url: String
    var headers: [String: String]
    var body: String
}

/// A named set of `{key}` substitution variables (developer-tools.md #3:
/// "named environments so a token captured while logged into an app in a
/// workspace can be reused deliberately, never silently").
struct APIEnvironment: Identifiable {
    let id: UUID
    var name: String
    var variables: [String: String]
}

struct HeaderRow: Identifiable, Equatable {
    let id = UUID()
    var key = ""
    var value = ""
}

struct APIResponse {
    let status: Int
    let duration: TimeInterval
    let headers: [String: String]
    let bodyData: Data
    let parsedJSON: Any?
}

/// What was actually sent over the wire — every `{variable}` and computed
/// expression already resolved to its real value. Shown alongside the
/// response so a signature/token substitution can be checked by eye against
/// what the server saw, not just against what's still typed in the (still
/// template-shaped) editor above.
struct APIResolvedRequest {
    let method: String
    let url: String
    let headers: [(key: String, value: String)]
    let body: String
}

/// One API client tab's live, in-progress state — owned externally (by
/// `APIClientStore`, keyed by tab id) rather than by `APIClientView`'s own
/// `@State`, since switching away to another tab and back tears down and
/// recreates the view (same as any other tab); without an externally-owned
/// home for this, a half-written request would vanish the moment you looked
/// at a different tab. `method`/`urlText`/`headerRows`/`bodyText`/
/// `selectedEnvironmentID` are debounced to disk by `APIClientStore.
/// scheduleDraftPersist` (triggered from `APIClientView`'s `.onChange`
/// hooks) and restored on next launch — testing the same endpoint across
/// multiple days shouldn't mean retyping the same headers every time.
/// `isSending`/`response`/`errorMessage`/`lastRequest`/`loadedTemplate` stay
/// purely in-memory: there's nothing to restore about an in-flight request
/// or a past response once the app's quit.
@MainActor
@Observable
final class APIClientDraftState {
    var method = "GET"
    var urlText = ""
    var headerRows: [HeaderRow] = [HeaderRow()]
    var bodyText = ""
    var selectedEnvironmentID: UUID?
    var isSending = false
    var lastRequest: APIResolvedRequest?
    var response: APIResponse?
    /// The raw, un-substituted template (`{locationId}` and all) behind the
    /// operation currently loaded — kept so the next operation you click can
    /// diff `urlText` against it and recover whatever you actually typed in
    /// place of each `{name}`, rather than wiping it back to the raw
    /// placeholder. Nil for history entries and manually-typed URLs, which
    /// have no template to diff against.
    var loadedTemplate: (baseURL: String?, path: String)?
    var errorMessage: String?
}

/// One request tab in an API client browser tab's tab strip — Postman-style,
/// so testing several endpoints (different headers/URL/body each) doesn't
/// mean overwriting the same draft over and over. `title` is user-editable
/// (double-click to rename) but starts as a plain placeholder.
struct APIRequestTab: Identifiable, Equatable {
    let id: UUID
    var title: String
}

/// The tab strip's own live state for one API client browser tab — which
/// request tabs exist, in what order, and which is selected. Kept separate
/// from any one `APIClientDraftState` since it outlives all of them (closing
/// every request tab but one still leaves the strip itself in place).
@MainActor
@Observable
final class APIRequestTabsState {
    var tabs: [APIRequestTab]
    var selectedID: UUID?

    init(tabs: [APIRequestTab], selectedID: UUID?) {
        self.tabs = tabs
        self.selectedID = selectedID
    }
}

/// Backs the API client (lite) — request history (capped, most-recent-first),
/// named environments, imported collections, and each API client tab's live
/// draft state. Shares Sill's one SQLite file rather than opening a second
/// database, consistent with the rest of the app.
@MainActor
@Observable
final class APIClientStore {
    private(set) var history: [APIHistoryEntry] = []
    private(set) var environments: [APIEnvironment] = []
    @ObservationIgnored private var draftStates: [UUID: APIClientDraftState] = [:]
    @ObservationIgnored private var requestTabsStates: [UUID: APIRequestTabsState] = [:]
    private(set) var collections: [APICollection] = []

    @ObservationIgnored private let db: Database
    @ObservationIgnored private var persistEnvironmentsTask: Task<Void, Never>?
    @ObservationIgnored private var persistDraftTasks: [UUID: Task<Void, Never>] = [:]
    private static let historyCap = 50
    private static let environmentPersistDebounce = Duration.milliseconds(500)

    init(db: Database) {
        self.db = db
        createSchema()
        load()
    }

    private func createSchema() {
        try? db.execute("""
            CREATE TABLE IF NOT EXISTS api_request_history (
                id TEXT PRIMARY KEY,
                ts REAL NOT NULL,
                method TEXT NOT NULL,
                url TEXT NOT NULL,
                headers TEXT NOT NULL DEFAULT '{}',
                body TEXT NOT NULL DEFAULT ''
            );
            CREATE TABLE IF NOT EXISTS api_environment (
                id TEXT PRIMARY KEY,
                sort INTEGER NOT NULL,
                name TEXT NOT NULL,
                variables TEXT NOT NULL DEFAULT '{}'
            );
            CREATE TABLE IF NOT EXISTS api_collection (
                id TEXT PRIMARY KEY,
                sort INTEGER NOT NULL,
                data TEXT NOT NULL
            );
            CREATE TABLE IF NOT EXISTS api_draft (
                tab_id TEXT PRIMARY KEY,
                method TEXT NOT NULL DEFAULT 'GET',
                url TEXT NOT NULL DEFAULT '',
                headers TEXT NOT NULL DEFAULT '[]',
                body TEXT NOT NULL DEFAULT '',
                environment_id TEXT
            );
            CREATE TABLE IF NOT EXISTS api_request_tab (
                id TEXT PRIMARY KEY,
                browser_tab_id TEXT NOT NULL,
                sort INTEGER NOT NULL,
                title TEXT NOT NULL
            );
            CREATE TABLE IF NOT EXISTS api_request_tab_selection (
                browser_tab_id TEXT PRIMARY KEY,
                selected_id TEXT NOT NULL
            );
            """)
    }

    private func load() {
        history = (try? db.query("SELECT id, ts, method, url, headers, body FROM api_request_history ORDER BY ts DESC LIMIT \(Self.historyCap)"))?
            .compactMap { row -> APIHistoryEntry? in
                guard let idText = row.text("id"), let id = UUID(uuidString: idText),
                      let method = row.text("method"), let url = row.text("url") else { return nil }
                return APIHistoryEntry(
                    id: id,
                    timestamp: Date(timeIntervalSince1970: row.real("ts") ?? 0),
                    method: method,
                    url: url,
                    headers: Self.decodeDict(row.text("headers")),
                    body: row.text("body") ?? ""
                )
            } ?? []

        environments = (try? db.query("SELECT id, name, variables FROM api_environment ORDER BY sort"))?
            .compactMap { row -> APIEnvironment? in
                guard let idText = row.text("id"), let id = UUID(uuidString: idText),
                      let name = row.text("name") else { return nil }
                return APIEnvironment(id: id, name: name, variables: Self.decodeDict(row.text("variables")))
            } ?? []

        collections = (try? db.query("SELECT data FROM api_collection ORDER BY sort"))?
            .compactMap { row -> APICollection? in
                guard let data = row.text("data")?.data(using: .utf8) else { return nil }
                return try? JSONDecoder().decode(APICollection.self, from: data)
            } ?? []
    }

    func recordHistory(method: String, url: String, headers: [String: String], body: String) {
        let id = UUID()
        try? db.run(
            "INSERT INTO api_request_history (id, ts, method, url, headers, body) VALUES (?,?,?,?,?,?)",
            [.text(id.uuidString), .real(Date().timeIntervalSince1970), .text(method), .text(url), .text(Self.encodeDict(headers)), .text(body)]
        )
        // Trim beyond the cap rather than growing the table forever.
        try? db.run(
            """
            DELETE FROM api_request_history WHERE id NOT IN (
                SELECT id FROM api_request_history ORDER BY ts DESC LIMIT \(Self.historyCap)
            )
            """
        )
        load()
    }

    @discardableResult
    func addEnvironment(name: String) -> APIEnvironment {
        let environment = APIEnvironment(id: UUID(), name: name, variables: [:])
        environments.append(environment)
        persistEnvironmentsTask?.cancel()
        persistEnvironments()
        return environment
    }

    /// Called on every keystroke while editing an environment's name or
    /// variables, so the SQLite write is debounced — `environments` (the
    /// `@Observable` state) is the source of truth in between, and only the
    /// last write in a burst of edits actually hits disk.
    func updateEnvironment(_ environment: APIEnvironment) {
        guard let index = environments.firstIndex(where: { $0.id == environment.id }) else { return }
        environments[index] = environment
        persistEnvironmentsTask?.cancel()
        persistEnvironmentsTask = Task { [weak self] in
            try? await Task.sleep(for: Self.environmentPersistDebounce)
            guard !Task.isCancelled else { return }
            self?.persistEnvironments()
        }
    }

    func removeEnvironment(_ environment: APIEnvironment) {
        environments.removeAll { $0.id == environment.id }
        persistEnvironmentsTask?.cancel()
        persistEnvironments()
    }

    private func persistEnvironments() {
        try? db.run("DELETE FROM api_environment")
        for (index, environment) in environments.enumerated() {
            try? db.run(
                "INSERT INTO api_environment (id, sort, name, variables) VALUES (?,?,?,?)",
                [.text(environment.id.uuidString), .int(Int64(index)), .text(environment.name), .text(Self.encodeDict(environment.variables))]
            )
        }
    }

    /// "Setup the headers ready for the user to put in the auth tokens" —
    /// when the spec declared an auth scheme, seed a named Environment for
    /// its placeholder variable (empty value) so filling in the token is
    /// the *only* manual step left, and every operation loaded from this
    /// collection auto-selects it.
    func importCollection(_ collection: APICollection) {
        var collection = collection
        if let placeholder = collection.authPlaceholder {
            let environment = addEnvironment(name: "\(collection.name) auth")
            updateEnvironment(APIEnvironment(id: environment.id, name: environment.name, variables: [placeholder.envVariableName: ""]))
            collection.environmentID = environment.id
        }
        collections.append(collection)
        persistCollections()
    }

    func removeCollection(_ collection: APICollection) {
        collections.removeAll { $0.id == collection.id }
        persistCollections()
    }

    /// Creates the draft on first access — restored from whatever was last
    /// typed into this tab if it was ever persisted (see `scheduleDraftPersist`),
    /// or blank for a genuinely new tab. The owner's own complaint drove
    /// this: re-entering the same headers every session, testing the same
    /// API across multiple days, was exactly what "session-only by design"
    /// used to force.
    func draftState(for tabID: UUID) -> APIClientDraftState {
        if let existing = draftStates[tabID] { return existing }
        let state = loadDraft(for: tabID) ?? APIClientDraftState()
        draftStates[tabID] = state
        return state
    }

    func removeDraftState(for tabID: UUID) {
        draftStates.removeValue(forKey: tabID)
        persistDraftTasks[tabID]?.cancel()
        persistDraftTasks.removeValue(forKey: tabID)
        try? db.run("DELETE FROM api_draft WHERE tab_id = ?", [.text(tabID.uuidString)])
    }

    // MARK: Request tabs — the tab strip across the top of one API client
    // browser tab, so testing several endpoints doesn't mean overwriting the
    // same headers/URL over and over.

    /// Creates the tab strip's state on first access. A browser tab that's
    /// never had a tab strip before (i.e. every one that existed before this
    /// feature shipped) seeds exactly one request tab whose id equals the
    /// *browser* tab's own id — not a fresh random UUID — so whatever was
    /// already persisted under that id via the old single-draft-per-tab
    /// scheme (`draftState(for: browserTabID)`) is picked up as-is instead of
    /// looking wiped the first time this runs.
    func requestTabsState(for browserTabID: UUID) -> APIRequestTabsState {
        if let existing = requestTabsStates[browserTabID] { return existing }
        let state = loadRequestTabs(for: browserTabID)
        requestTabsStates[browserTabID] = state
        return state
    }

    @discardableResult
    func addRequestTab(for browserTabID: UUID) -> UUID {
        let state = requestTabsState(for: browserTabID)
        let newTab = APIRequestTab(id: UUID(), title: "Request \(state.tabs.count + 1)")
        state.tabs.append(newTab)
        state.selectedID = newTab.id
        persistRequestTabs(state.tabs, for: browserTabID)
        persistSelection(newTab.id, for: browserTabID)
        return newTab.id
    }

    func selectRequestTab(_ id: UUID, for browserTabID: UUID) {
        let state = requestTabsState(for: browserTabID)
        guard state.selectedID != id else { return }
        state.selectedID = id
        persistSelection(id, for: browserTabID)
    }

    func renameRequestTab(_ id: UUID, title: String, for browserTabID: UUID) {
        let state = requestTabsState(for: browserTabID)
        guard let index = state.tabs.firstIndex(where: { $0.id == id }) else { return }
        state.tabs[index].title = title
        persistRequestTabs(state.tabs, for: browserTabID)
    }

    /// Always leaves at least one request tab — same reasoning as never
    /// letting the last browser tab close: an empty tab strip has nothing
    /// for `body` to display.
    func closeRequestTab(_ id: UUID, for browserTabID: UUID) {
        let state = requestTabsState(for: browserTabID)
        guard state.tabs.count > 1, let closingIndex = state.tabs.firstIndex(where: { $0.id == id }) else { return }
        state.tabs.remove(at: closingIndex)
        if state.selectedID == id {
            let fallbackIndex = min(closingIndex, state.tabs.count - 1)
            state.selectedID = state.tabs[fallbackIndex].id
            persistSelection(state.selectedID!, for: browserTabID)
        }
        persistRequestTabs(state.tabs, for: browserTabID)
        removeDraftState(for: id)
    }

    /// Called when the *browser* tab itself closes — tears down every
    /// request tab's draft, not just a single one, since there can now be
    /// several.
    func removeAllRequestTabs(for browserTabID: UUID) {
        let state = requestTabsStates[browserTabID] ?? loadRequestTabs(for: browserTabID)
        for requestTab in state.tabs {
            removeDraftState(for: requestTab.id)
        }
        requestTabsStates.removeValue(forKey: browserTabID)
        try? db.run("DELETE FROM api_request_tab WHERE browser_tab_id = ?", [.text(browserTabID.uuidString)])
        try? db.run("DELETE FROM api_request_tab_selection WHERE browser_tab_id = ?", [.text(browserTabID.uuidString)])
    }

    private func loadRequestTabs(for browserTabID: UUID) -> APIRequestTabsState {
        var tabs: [APIRequestTab] = (try? db.query(
            "SELECT id, title FROM api_request_tab WHERE browser_tab_id = ? ORDER BY sort",
            [.text(browserTabID.uuidString)]
        ))?.compactMap { row in
            guard let idText = row.text("id"), let id = UUID(uuidString: idText), let title = row.text("title") else { return nil }
            return APIRequestTab(id: id, title: title)
        } ?? []

        if tabs.isEmpty {
            let seeded = APIRequestTab(id: browserTabID, title: "Request 1")
            tabs = [seeded]
            persistRequestTabs(tabs, for: browserTabID)
        }

        let selectedID = (try? db.query(
            "SELECT selected_id FROM api_request_tab_selection WHERE browser_tab_id = ?",
            [.text(browserTabID.uuidString)]
        ))?.first?.text("selected_id").flatMap(UUID.init(uuidString:))
        let validSelectedID = selectedID.flatMap { id in tabs.contains { $0.id == id } ? id : nil }
        return APIRequestTabsState(tabs: tabs, selectedID: validSelectedID ?? tabs.first?.id)
    }

    private func persistRequestTabs(_ tabs: [APIRequestTab], for browserTabID: UUID) {
        try? db.run("DELETE FROM api_request_tab WHERE browser_tab_id = ?", [.text(browserTabID.uuidString)])
        for (index, requestTab) in tabs.enumerated() {
            try? db.run(
                "INSERT INTO api_request_tab (id, browser_tab_id, sort, title) VALUES (?,?,?,?)",
                [.text(requestTab.id.uuidString), .text(browserTabID.uuidString), .int(Int64(index)), .text(requestTab.title)]
            )
        }
    }

    private func persistSelection(_ id: UUID, for browserTabID: UUID) {
        try? db.run(
            """
            INSERT INTO api_request_tab_selection (browser_tab_id, selected_id) VALUES (?,?)
            ON CONFLICT(browser_tab_id) DO UPDATE SET selected_id = excluded.selected_id
            """,
            [.text(browserTabID.uuidString), .text(id.uuidString)]
        )
    }

    private func loadDraft(for tabID: UUID) -> APIClientDraftState? {
        guard let row = (try? db.query(
            "SELECT method, url, headers, body, environment_id FROM api_draft WHERE tab_id = ?",
            [.text(tabID.uuidString)]
        ))?.first else { return nil }

        let state = APIClientDraftState()
        state.method = row.text("method") ?? "GET"
        state.urlText = row.text("url") ?? ""
        let headerRows = Self.decodeHeaderRows(row.text("headers"))
        state.headerRows = headerRows.isEmpty ? [HeaderRow()] : headerRows
        state.bodyText = row.text("body") ?? ""
        state.selectedEnvironmentID = row.text("environment_id").flatMap(UUID.init(uuidString:))
        return state
    }

    /// Debounced the same way environment edits are — every keystroke in the
    /// URL/header/body fields would otherwise hit disk directly. `draft`
    /// (not just `tabID`) is captured so the write reflects whatever's
    /// current when the debounce fires, not a stale snapshot from when it
    /// was scheduled.
    func scheduleDraftPersist(tabID: UUID, draft: APIClientDraftState) {
        persistDraftTasks[tabID]?.cancel()
        persistDraftTasks[tabID] = Task { [weak self] in
            try? await Task.sleep(for: Self.environmentPersistDebounce)
            guard !Task.isCancelled else { return }
            self?.persistDraft(tabID: tabID, draft: draft)
        }
    }

    private func persistDraft(tabID: UUID, draft: APIClientDraftState) {
        try? db.run(
            """
            INSERT INTO api_draft (tab_id, method, url, headers, body, environment_id) VALUES (?,?,?,?,?,?)
            ON CONFLICT(tab_id) DO UPDATE SET
                method = excluded.method, url = excluded.url, headers = excluded.headers,
                body = excluded.body, environment_id = excluded.environment_id
            """,
            [
                .text(tabID.uuidString), .text(draft.method), .text(draft.urlText),
                .text(Self.encodeHeaderRows(draft.headerRows)), .text(draft.bodyText),
                draft.selectedEnvironmentID.map { Database.Value.text($0.uuidString) } ?? .null,
            ]
        )
    }

    private func persistCollections() {
        try? db.run("DELETE FROM api_collection")
        for (index, collection) in collections.enumerated() {
            guard let data = try? JSONEncoder().encode(collection), let text = String(data: data, encoding: .utf8) else { continue }
            try? db.run(
                "INSERT INTO api_collection (id, sort, data) VALUES (?,?,?)",
                [.text(collection.id.uuidString), .int(Int64(index)), .text(text)]
            )
        }
    }

    private static func encodeDict(_ dict: [String: String]) -> String {
        (try? String(data: JSONSerialization.data(withJSONObject: dict), encoding: .utf8)) ?? "{}"
    }

    private static func decodeDict(_ text: String?) -> [String: String] {
        guard let text, let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: String] else { return [:] }
        return object
    }

    /// Ordered, not a dict — unlike history/environment headers, a draft's
    /// header rows include the blank trailing row you're mid-typing into and
    /// can (briefly, while editing) hold a duplicate key. A dict would
    /// silently drop both.
    private struct PersistedHeader: Codable {
        var key: String
        var value: String
    }

    private static func encodeHeaderRows(_ rows: [HeaderRow]) -> String {
        let persisted = rows.map { PersistedHeader(key: $0.key, value: $0.value) }
        guard let data = try? JSONEncoder().encode(persisted), let text = String(data: data, encoding: .utf8) else { return "[]" }
        return text
    }

    private static func decodeHeaderRows(_ text: String?) -> [HeaderRow] {
        guard let text, let data = text.data(using: .utf8),
              let persisted = try? JSONDecoder().decode([PersistedHeader].self, from: data) else { return [] }
        return persisted.map { HeaderRow(key: $0.key, value: $0.value) }
    }
}
