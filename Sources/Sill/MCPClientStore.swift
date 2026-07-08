import Foundation
import Observation

/// One saved MCP server the explorer can connect to — either a local
/// command Sill launches itself (stdio) or a remote streamable-HTTP
/// endpoint. Persisted whole as one JSON blob per row, same shape as
/// `api_collection`.
struct MCPServerConfig: Identifiable, Codable, Equatable {
    enum Transport: String, Codable, CaseIterable, Identifiable {
        case stdio
        case http

        var id: String { rawValue }
        var label: String {
            switch self {
            case .stdio: return "Command"
            case .http: return "HTTP"
            }
        }
    }

    let id: UUID
    var name: String
    var transport: Transport
    /// stdio: the full command line, run through a login shell (`npx
    /// @modelcontextprotocol/server-everything` works exactly as typed in
    /// a terminal).
    var command: String = ""
    /// stdio: extra environment variables layered over the inherited ones —
    /// API keys, mostly.
    var environment: [String: String] = [:]
    /// http: the endpoint URL.
    var urlString: String = ""
    /// http: extra request headers — `Authorization`, mostly.
    var headers: [String: String] = [:]
}

/// What the explorer knows about one tab's current connection.
enum MCPConnectionPhase: Equatable {
    case disconnected
    case connecting
    case connected
    case failed(String)
}

/// Which capability is open in the detail pane.
enum MCPSelection: Equatable {
    case tool(String)
    case resource(String)
    case prompt(String)
}

/// One MCP explorer tab's live state — owned externally (by
/// `MCPClientStore`, keyed by browser tab id) for the same reason
/// `APIClientDraftState` is: switching away to another tab and back tears
/// down and recreates the view, and a live connection or half-typed
/// arguments must survive that. Nothing here persists to disk — a
/// connection is a running process or an HTTP session, and neither
/// meaningfully outlives the app.
@MainActor
@Observable
final class MCPTabState {
    var selectedServerID: UUID?
    var phase: MCPConnectionPhase = .disconnected
    var serverInfo: MCPServerInfo?
    var tools: [MCPTool] = []
    var resources: [MCPResource] = []
    var prompts: [MCPPrompt] = []
    var selection: MCPSelection?
    /// Typed argument drafts, keyed by tool/prompt name then field name —
    /// kept across selection changes so flipping between two tools doesn't
    /// wipe what was half-entered into either.
    var argumentDrafts: [String: [String: String]] = [:]
    /// Per-tool raw-JSON override text, for arguments too structured for
    /// the generated form.
    var rawJSONDrafts: [String: String] = [:]
    var logLines: [String] = []

    // The current invocation, purely in-memory — cleared whenever the
    // selection changes.
    var isInvoking = false
    var toolResult: MCPToolResult?
    var resourceContents: [MCPContentItem]?
    var promptResult: MCPPromptResult?
    var invokeError: String?

    func clearResults() {
        isInvoking = false
        toolResult = nil
        resourceContents = nil
        promptResult = nil
        invokeError = nil
    }

    @ObservationIgnored var connection: MCPConnection?

    func appendLog(_ line: String) {
        logLines.append(line)
        // Keep the log a window, not an archive.
        if logLines.count > 500 {
            logLines.removeFirst(logLines.count - 500)
        }
    }
}

/// Backs the MCP explorer — the saved server list (shared SQLite file, like
/// everything else) plus each explorer tab's live state. The API client
/// split, mirrored: protocol in MCPClient.swift, UI in MCPClientView.swift.
@MainActor
@Observable
final class MCPClientStore {
    private(set) var servers: [MCPServerConfig] = []
    @ObservationIgnored private var tabStates: [UUID: MCPTabState] = [:]

    @ObservationIgnored private let db: Database
    @ObservationIgnored private var persistServersTask: Task<Void, Never>?
    private static let persistDebounce = Duration.milliseconds(500)

    init(db: Database) {
        self.db = db
        createSchema()
        load()
    }

    private func createSchema() {
        try? db.execute("""
            CREATE TABLE IF NOT EXISTS mcp_server (
                id TEXT PRIMARY KEY,
                sort INTEGER NOT NULL,
                data TEXT NOT NULL
            );
            """)
    }

    private func load() {
        servers = (try? db.query("SELECT data FROM mcp_server ORDER BY sort"))?
            .compactMap { row -> MCPServerConfig? in
                guard let data = row.text("data")?.data(using: .utf8) else { return nil }
                return try? JSONDecoder().decode(MCPServerConfig.self, from: data)
            } ?? []
    }

    // MARK: Servers

    @discardableResult
    func addServer() -> MCPServerConfig {
        let server = MCPServerConfig(id: UUID(), name: "New server", transport: .stdio)
        servers.append(server)
        persistServersTask?.cancel()
        persistServers()
        return server
    }

    /// Called on every keystroke while editing a server's fields, so the
    /// SQLite write is debounced — `servers` (the `@Observable` state) is
    /// the source of truth in between, same pattern as API environments.
    func updateServer(_ server: MCPServerConfig) {
        guard let index = servers.firstIndex(where: { $0.id == server.id }) else { return }
        servers[index] = server
        persistServersTask?.cancel()
        persistServersTask = Task { [weak self] in
            try? await Task.sleep(for: Self.persistDebounce)
            guard !Task.isCancelled else { return }
            self?.persistServers()
        }
    }

    func removeServer(_ server: MCPServerConfig) {
        servers.removeAll { $0.id == server.id }
        // Any tab connected to this server keeps its live connection until
        // it disconnects — deleting the bookmark shouldn't yank a session
        // out from under an in-flight tool call — but its selection is
        // cleared so the sidebar doesn't point at a ghost.
        for state in tabStates.values where state.selectedServerID == server.id {
            state.selectedServerID = nil
        }
        persistServersTask?.cancel()
        persistServers()
    }

    private func persistServers() {
        try? db.run("DELETE FROM mcp_server")
        for (index, server) in servers.enumerated() {
            guard let data = try? JSONEncoder().encode(server), let text = String(data: data, encoding: .utf8) else { continue }
            try? db.run(
                "INSERT INTO mcp_server (id, sort, data) VALUES (?,?,?)",
                [.text(server.id.uuidString), .int(Int64(index)), .text(text)]
            )
        }
    }

    // MARK: Tab state

    func tabState(for browserTabID: UUID) -> MCPTabState {
        if let existing = tabStates[browserTabID] { return existing }
        let state = MCPTabState()
        tabStates[browserTabID] = state
        return state
    }

    /// Called when the browser tab closes — tears down the live connection
    /// (terminating the stdio server process, if that's the transport) along
    /// with the state.
    func removeTabState(for browserTabID: UUID) {
        tabStates[browserTabID]?.connection?.close()
        tabStates.removeValue(forKey: browserTabID)
    }

    // MARK: Connecting

    func connect(_ state: MCPTabState, to server: MCPServerConfig) {
        disconnect(state)
        state.selectedServerID = server.id
        state.phase = .connecting
        state.logLines = []

        let transport: MCPTransport
        do {
            transport = try makeTransport(for: server)
        } catch {
            state.phase = .failed(error.localizedDescription)
            return
        }

        let connection = MCPConnection(transport: transport)
        connection.onLog = { [weak state] line in
            Task { @MainActor in
                state?.appendLog(line)
            }
        }
        state.connection = connection

        Task {
            do {
                let info = try await connection.initialize()
                // The user may have hit disconnect (or connected elsewhere)
                // while the handshake was in flight.
                guard state.connection === connection else { return }
                state.serverInfo = info
                state.phase = .connected
                state.appendLog("connected: \(info.name) \(info.version) (protocol \(info.protocolVersion))")

                async let tools = info.hasTools ? connection.listTools() : []
                async let resources = info.hasResources ? connection.listResources() : []
                async let prompts = info.hasPrompts ? connection.listPrompts() : []
                let loaded = try await (tools: tools, resources: resources, prompts: prompts)
                guard state.connection === connection else { return }
                state.tools = loaded.tools
                state.resources = loaded.resources
                state.prompts = loaded.prompts
            } catch {
                guard state.connection === connection else { return }
                connection.close()
                state.connection = nil
                state.phase = .failed(error.localizedDescription)
            }
        }
    }

    func disconnect(_ state: MCPTabState) {
        state.connection?.close()
        state.connection = nil
        state.phase = .disconnected
        state.serverInfo = nil
        state.tools = []
        state.resources = []
        state.prompts = []
        state.selection = nil
    }

    private func makeTransport(for server: MCPServerConfig) throws -> MCPTransport {
        switch server.transport {
        case .stdio:
            let command = server.command.trimmingCharacters(in: .whitespaces)
            guard !command.isEmpty else { throw MCPError(message: "Enter the server command first.") }
            return try MCPStdioTransport(command: command, environment: server.environment)
        case .http:
            guard let url = URL(string: server.urlString.trimmingCharacters(in: .whitespaces)),
                  url.scheme == "http" || url.scheme == "https" else {
                throw MCPError(message: "Enter a valid http(s) server URL first.")
            }
            return MCPHTTPTransport(url: url, headers: server.headers)
        }
    }
}
