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

/// A named set of `{{key}}` substitution variables (developer-tools.md #3:
/// "named environments so a token captured while logged into an app in a
/// workspace can be reused deliberately, never silently").
struct APIEnvironment: Identifiable {
    let id: UUID
    var name: String
    var variables: [String: String]
}

struct HeaderRow: Identifiable {
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

/// One API client tab's live, in-progress state — owned externally (by
/// `APIClientStore`, keyed by tab id) rather than by `APIClientView`'s own
/// `@State`, since switching away to another tab and back tears down and
/// recreates the view (same as any other tab); without an externally-owned
/// home for this, a half-written request would vanish the moment you looked
/// at a different tab. Session-only by design — draft edits don't survive
/// quit/relaunch, same as unsubmitted form fields on an ordinary page don't.
@MainActor
@Observable
final class APIClientDraftState {
    var method = "GET"
    var urlText = ""
    var headerRows: [HeaderRow] = [HeaderRow()]
    var bodyText = ""
    var selectedEnvironmentID: UUID?
    var isSending = false
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
    private(set) var collections: [APICollection] = []

    @ObservationIgnored private let db: Database
    @ObservationIgnored private var persistEnvironmentsTask: Task<Void, Never>?
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

    /// Creates the draft on first access, so a freshly-opened API client tab
    /// starts blank without needing a separate "create" step.
    func draftState(for tabID: UUID) -> APIClientDraftState {
        if let existing = draftStates[tabID] { return existing }
        let state = APIClientDraftState()
        draftStates[tabID] = state
        return state
    }

    func removeDraftState(for tabID: UUID) {
        draftStates.removeValue(forKey: tabID)
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
}
