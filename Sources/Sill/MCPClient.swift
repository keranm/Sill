import Foundation

/// developer-tools.md's API client gets a sibling: the MCP explorer. This
/// file is the protocol layer only — JSON-RPC 2.0 over the two transports
/// the MCP spec defines (stdio for locally-launched servers, streamable
/// HTTP for remote ones), the initialize handshake, and the six list/invoke
/// methods the explorer surfaces (tools/resources/prompts, list + call/
/// read/get). No UI, no persistence — those live in MCPClientStore/
/// MCPClientView, same split as the API client.
///
/// Deliberately built on `JSONSerialization` dictionaries rather than
/// Codable models: tool input schemas and result payloads are open-ended
/// JSON by design (that's the whole point of exploring an unknown server),
/// and `JSONTreeView` — the response renderer this feeds — already takes
/// `Any`.

struct MCPError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

// MARK: - Models

struct MCPTool: Identifiable {
    var id: String { name }
    let name: String
    let description: String?
    /// The raw JSON schema for the tool's arguments — rendered as a form
    /// by the view layer, kept raw here.
    let inputSchema: [String: Any]?
}

struct MCPResource: Identifiable {
    var id: String { uri }
    let uri: String
    let name: String?
    let description: String?
    let mimeType: String?
}

struct MCPPromptArgument: Identifiable {
    var id: String { name }
    let name: String
    let description: String?
    let required: Bool
}

struct MCPPrompt: Identifiable {
    var id: String { name }
    let name: String
    let description: String?
    let arguments: [MCPPromptArgument]
}

/// One item of a tool result / resource read / prompt message — the
/// content-block union the MCP spec shares across all three.
enum MCPContentItem: Identifiable {
    case text(String)
    case image(data: Data, mimeType: String)
    case resourceLink(uri: String, name: String?)
    case embeddedResource(uri: String?, mimeType: String?, text: String?, blob: Data?)
    case other([String: Any])

    var id: UUID { UUID() }

    static func parse(_ raw: [String: Any]) -> MCPContentItem {
        switch raw["type"] as? String {
        case "text":
            return .text(raw["text"] as? String ?? "")
        case "image", "audio":
            let data = (raw["data"] as? String).flatMap { Data(base64Encoded: $0) } ?? Data()
            return .image(data: data, mimeType: raw["mimeType"] as? String ?? "")
        case "resource_link":
            return .resourceLink(uri: raw["uri"] as? String ?? "", name: raw["name"] as? String)
        case "resource":
            let resource = raw["resource"] as? [String: Any] ?? [:]
            return .embeddedResource(
                uri: resource["uri"] as? String,
                mimeType: resource["mimeType"] as? String,
                text: resource["text"] as? String,
                blob: (resource["blob"] as? String).flatMap { Data(base64Encoded: $0) }
            )
        default:
            return .other(raw)
        }
    }
}

struct MCPToolResult {
    let content: [MCPContentItem]
    let isError: Bool
    /// tools with an outputSchema also return machine-readable structured
    /// content — worth a JSON tree of its own when present.
    let structuredContent: Any?
}

struct MCPPromptMessage: Identifiable {
    let id = UUID()
    let role: String
    let content: MCPContentItem
}

struct MCPPromptResult {
    let description: String?
    let messages: [MCPPromptMessage]
}

struct MCPServerInfo {
    let name: String
    let version: String
    let protocolVersion: String
    let instructions: String?
    let hasTools: Bool
    let hasResources: Bool
    let hasPrompts: Bool
}

// MARK: - Transport

/// One JSON-RPC message pipe. `request` returns the response whose id
/// matches (or throws); `notify` is fire-and-forget. Implementations own
/// their own concurrency — both get called from the main actor and resume
/// their continuations from background readers.
protocol MCPTransport: AnyObject {
    func request(_ method: String, params: [String: Any]?, timeout: TimeInterval) async throws -> [String: Any]
    func notify(_ method: String, params: [String: Any]?) throws
    func close()
    /// Streams server chatter the explorer shows in its log pane — stdio
    /// stderr lines, `notifications/message` logging, lifecycle events.
    var onLog: ((String) -> Void)? { get set }
}

// MARK: - stdio transport

/// Launches the server command through a login shell (`zsh -l -c`) so
/// `npx`/`uvx`/anything on the user's interactive PATH resolves exactly as
/// it does in their terminal — the command box should behave like the
/// terminal it's replacing, not like a bare `Process` with launchd's PATH.
final class MCPStdioTransport: MCPTransport {
    var onLog: ((String) -> Void)?

    private let process = Process()
    private let stdinPipe = Pipe()
    private let stdoutPipe = Pipe()
    private let stderrPipe = Pipe()

    private let lock = NSLock()
    private var pending: [Int: CheckedContinuation<[String: Any], Error>] = [:]
    private var nextID = 1
    private var stdoutBuffer = Data()
    private var closed = false

    init(command: String, environment: [String: String]) throws {
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-l", "-c", command]
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, custom in custom }
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            self?.consumeStdout(handle.availableData)
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            guard let text = String(data: handle.availableData, encoding: .utf8), !text.isEmpty else { return }
            for line in text.split(separator: "\n") {
                self?.onLog?(String(line))
            }
        }
        process.terminationHandler = { [weak self] process in
            let reason = Self.exitDescription(process.terminationStatus)
            self?.onLog?("server process exited: \(reason)")
            self?.failAllPending(MCPError(message: "The server process exited — \(reason)"))
        }

        try process.run()
    }

    func request(_ method: String, params: [String: Any]?, timeout: TimeInterval) async throws -> [String: Any] {
        let id: Int = {
            lock.lock()
            defer { lock.unlock() }
            let id = nextID
            nextID += 1
            return id
        }()

        var message: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": method]
        if let params { message["params"] = params }

        return try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            pending[id] = continuation
            lock.unlock()

            do {
                try write(message)
            } catch {
                takePending(id: id)?.resume(throwing: error)
                return
            }

            Task { [weak self] in
                try? await Task.sleep(for: .seconds(timeout))
                self?.takePending(id: id)?.resume(throwing: MCPError(message: "The server didn't respond to \(method) within \(Int(timeout))s."))
            }
        }
    }

    func notify(_ method: String, params: [String: Any]?) throws {
        var message: [String: Any] = ["jsonrpc": "2.0", "method": method]
        if let params { message["params"] = params }
        try write(message)
    }

    func close() {
        lock.lock()
        closed = true
        lock.unlock()
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil
        failAllPending(MCPError(message: "Disconnected."))
        if process.isRunning { process.terminate() }
    }

    private func write(_ message: [String: Any]) throws {
        lock.lock()
        let closed = self.closed
        lock.unlock()
        guard !closed, process.isRunning else { throw MCPError(message: "The server process isn't running.") }
        var data = try JSONSerialization.data(withJSONObject: message)
        data.append(0x0A)
        try stdinPipe.fileHandleForWriting.write(contentsOf: data)
    }

    /// stdout is newline-delimited JSON-RPC; anything unparseable (a server
    /// that prints a banner to stdout by mistake) goes to the log rather
    /// than silently vanishing — that misbehavior is exactly what someone
    /// debugging their own server needs to see.
    private func consumeStdout(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.lock()
        stdoutBuffer.append(data)
        var lines: [Data] = []
        while let newline = stdoutBuffer.firstIndex(of: 0x0A) {
            lines.append(stdoutBuffer.subdata(in: stdoutBuffer.startIndex..<newline))
            stdoutBuffer.removeSubrange(stdoutBuffer.startIndex...newline)
        }
        lock.unlock()

        for line in lines where !line.isEmpty {
            if let message = try? JSONSerialization.jsonObject(with: line) as? [String: Any] {
                dispatch(message)
            } else if let text = String(data: line, encoding: .utf8) {
                onLog?("stdout (not JSON-RPC): \(text)")
            }
        }
    }

    private func dispatch(_ message: [String: Any]) {
        if let id = message["id"] as? Int, message["result"] != nil || message["error"] != nil {
            takePending(id: id)?.resume(returning: message)
        } else if let method = message["method"] as? String {
            if let id = message["id"] {
                // A server→client request (sampling, roots, elicitation) —
                // this client declares no such capabilities, so refuse it
                // politely rather than leaving the server hanging.
                try? write(["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "Method not supported by this client"]])
            } else if method == "notifications/message",
                      let params = message["params"] as? [String: Any] {
                let level = params["level"] as? String ?? "info"
                let text = (params["data"] as? String) ?? String(describing: params["data"] ?? "")
                onLog?("[\(level)] \(text)")
            }
        }
    }

    /// The shell's two conventional exit codes for "never even started" get
    /// spelled out — a raw "status 127" reads as a server crash when the
    /// actual problem is a typo'd command.
    private static func exitDescription(_ status: Int32) -> String {
        switch status {
        case 127:
            return "command not found (status 127). Check the command is spelled right and on your PATH — the full command line goes here, e.g. `npx -y @modelcontextprotocol/server-everything`."
        case 126:
            return "command found but not executable (status 126)."
        default:
            return "status \(status)."
        }
    }

    private func takePending(id: Int) -> CheckedContinuation<[String: Any], Error>? {
        lock.lock()
        defer { lock.unlock() }
        return pending.removeValue(forKey: id)
    }

    private func failAllPending(_ error: Error) {
        lock.lock()
        let continuations = pending.values
        pending.removeAll()
        lock.unlock()
        for continuation in continuations {
            continuation.resume(throwing: error)
        }
    }
}

// MARK: - Streamable HTTP transport

/// The spec's streamable HTTP transport, request-response subset: every
/// call is a POST that answers with either plain JSON or a short-lived SSE
/// stream carrying the response. The standing GET listening stream (for
/// unsolicited server→client traffic) is deliberately not opened — an
/// explorer only ever asks and waits.
final class MCPHTTPTransport: MCPTransport {
    var onLog: ((String) -> Void)?

    private let url: URL
    private let headers: [String: String]
    private var sessionID: String?
    /// Set after initialize negotiates; echoed on every subsequent request
    /// per spec.
    var protocolVersion: String?

    private let lock = NSLock()
    private var nextID = 1

    init(url: URL, headers: [String: String]) {
        self.url = url
        self.headers = headers
    }

    func request(_ method: String, params: [String: Any]?, timeout: TimeInterval) async throws -> [String: Any] {
        let id: Int = {
            lock.lock()
            defer { lock.unlock() }
            let id = nextID
            nextID += 1
            return id
        }()

        var message: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": method]
        if let params { message["params"] = params }

        let (data, response) = try await URLSession.shared.data(for: makeRequest(message, timeout: timeout))
        guard let http = response as? HTTPURLResponse else { throw MCPError(message: "Not an HTTP response.") }
        if let newSessionID = http.value(forHTTPHeaderField: "Mcp-Session-Id") {
            sessionID = newSessionID
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw MCPError(message: "HTTP \(http.statusCode) from server\(body.isEmpty ? "" : ": \(body.prefix(300))")")
        }

        let contentType = http.value(forHTTPHeaderField: "Content-Type") ?? ""
        if contentType.contains("text/event-stream") {
            if let match = Self.responseFromSSE(data, id: id) { return match }
            throw MCPError(message: "The server's event stream ended without answering \(method).")
        }
        guard let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MCPError(message: "The server's response wasn't JSON.")
        }
        return message
    }

    func notify(_ method: String, params: [String: Any]?) throws {
        var message: [String: Any] = ["jsonrpc": "2.0", "method": method]
        if let params { message["params"] = params }
        let request = makeRequest(message, timeout: 15)
        Task {
            _ = try? await URLSession.shared.data(for: request)
        }
    }

    func close() {
        // Politely end the session if the server issued one; best-effort.
        guard let sessionID else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id")
        Task {
            _ = try? await URLSession.shared.data(for: request)
        }
    }

    private func makeRequest(_ message: [String: Any], timeout: TimeInterval) -> URLRequest {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.httpBody = try? JSONSerialization.data(withJSONObject: message)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        if let sessionID { request.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id") }
        if let protocolVersion { request.setValue(protocolVersion, forHTTPHeaderField: "MCP-Protocol-Version") }
        for (key, value) in headers where !key.isEmpty {
            request.setValue(value, forHTTPHeaderField: key)
        }
        return request
    }

    /// Scans a completed SSE body for the event whose JSON-RPC id matches.
    /// `URLSession.data` only returns once the stream closes, which for the
    /// request-response pattern is exactly when the response has been sent.
    private static func responseFromSSE(_ data: Data, id: Int) -> [String: Any]? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        for rawEvent in text.components(separatedBy: "\n\n") {
            let dataPayload = rawEvent
                .split(separator: "\n")
                .filter { $0.hasPrefix("data:") }
                .map { $0.dropFirst(5).trimmingCharacters(in: .whitespaces) }
                .joined(separator: "\n")
            guard !dataPayload.isEmpty,
                  let payloadData = dataPayload.data(using: .utf8),
                  let message = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any] else { continue }
            if message["id"] as? Int == id, message["result"] != nil || message["error"] != nil {
                return message
            }
        }
        return nil
    }
}

// MARK: - Connection

/// One live, initialized session against one MCP server — the handshake,
/// then typed wrappers over the six explorer methods. Created connected;
/// `close()` tears the transport down.
@MainActor
final class MCPConnection {
    private let transport: MCPTransport
    private(set) var serverInfo: MCPServerInfo?

    /// The newest spec revision this client speaks; servers negotiate down
    /// from here if they're older.
    private static let preferredProtocolVersion = "2025-06-18"
    private static let listTimeout: TimeInterval = 30
    /// Tool calls get the long leash — a tool that shells out or hits a slow
    /// API legitimately takes a while, and the user has a visible spinner
    /// plus disconnect to bail out.
    private static let callTimeout: TimeInterval = 300

    init(transport: MCPTransport) {
        self.transport = transport
    }

    var onLog: ((String) -> Void)? {
        get { transport.onLog }
        set { transport.onLog = newValue }
    }

    func initialize() async throws -> MCPServerInfo {
        let result = try await requestResult("initialize", params: [
            "protocolVersion": Self.preferredProtocolVersion,
            "capabilities": [:] as [String: Any],
            "clientInfo": ["name": "Sill", "version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"],
        ], timeout: 20)

        let capabilities = result["capabilities"] as? [String: Any] ?? [:]
        let rawServerInfo = result["serverInfo"] as? [String: Any] ?? [:]
        let negotiated = result["protocolVersion"] as? String ?? Self.preferredProtocolVersion
        (transport as? MCPHTTPTransport)?.protocolVersion = negotiated

        try transport.notify("notifications/initialized", params: nil)

        let info = MCPServerInfo(
            name: rawServerInfo["name"] as? String ?? "Unnamed server",
            version: rawServerInfo["version"] as? String ?? "",
            protocolVersion: negotiated,
            instructions: result["instructions"] as? String,
            hasTools: capabilities["tools"] != nil,
            hasResources: capabilities["resources"] != nil,
            hasPrompts: capabilities["prompts"] != nil
        )
        serverInfo = info
        return info
    }

    func listTools() async throws -> [MCPTool] {
        try await paginate("tools/list", key: "tools").map { raw in
            MCPTool(
                name: raw["name"] as? String ?? "",
                description: raw["description"] as? String,
                inputSchema: raw["inputSchema"] as? [String: Any]
            )
        }
    }

    func callTool(name: String, arguments: [String: Any]) async throws -> MCPToolResult {
        let result = try await requestResult("tools/call", params: ["name": name, "arguments": arguments], timeout: Self.callTimeout)
        let content = (result["content"] as? [[String: Any]] ?? []).map(MCPContentItem.parse)
        return MCPToolResult(
            content: content,
            isError: result["isError"] as? Bool ?? false,
            structuredContent: result["structuredContent"]
        )
    }

    func listResources() async throws -> [MCPResource] {
        try await paginate("resources/list", key: "resources").map { raw in
            MCPResource(
                uri: raw["uri"] as? String ?? "",
                name: raw["name"] as? String,
                description: raw["description"] as? String,
                mimeType: raw["mimeType"] as? String
            )
        }
    }

    func readResource(uri: String) async throws -> [MCPContentItem] {
        let result = try await requestResult("resources/read", params: ["uri": uri], timeout: Self.listTimeout)
        return (result["contents"] as? [[String: Any]] ?? []).map { raw in
            MCPContentItem.embeddedResource(
                uri: raw["uri"] as? String,
                mimeType: raw["mimeType"] as? String,
                text: raw["text"] as? String,
                blob: (raw["blob"] as? String).flatMap { Data(base64Encoded: $0) }
            )
        }
    }

    func listPrompts() async throws -> [MCPPrompt] {
        try await paginate("prompts/list", key: "prompts").map { raw in
            MCPPrompt(
                name: raw["name"] as? String ?? "",
                description: raw["description"] as? String,
                arguments: (raw["arguments"] as? [[String: Any]] ?? []).map { arg in
                    MCPPromptArgument(
                        name: arg["name"] as? String ?? "",
                        description: arg["description"] as? String,
                        required: arg["required"] as? Bool ?? false
                    )
                }
            )
        }
    }

    func getPrompt(name: String, arguments: [String: String]) async throws -> MCPPromptResult {
        let result = try await requestResult("prompts/get", params: ["name": name, "arguments": arguments], timeout: Self.listTimeout)
        let messages = (result["messages"] as? [[String: Any]] ?? []).map { raw in
            MCPPromptMessage(
                role: raw["role"] as? String ?? "",
                content: MCPContentItem.parse(raw["content"] as? [String: Any] ?? [:])
            )
        }
        return MCPPromptResult(description: result["description"] as? String, messages: messages)
    }

    func close() {
        transport.close()
    }

    /// Cursor-paginated list, capped defensively — a server that hands back
    /// the same cursor forever shouldn't spin the explorer.
    private func paginate(_ method: String, key: String) async throws -> [[String: Any]] {
        var items: [[String: Any]] = []
        var cursor: String?
        for _ in 0..<50 {
            let params: [String: Any]? = cursor.map { ["cursor": $0] }
            let result = try await requestResult(method, params: params, timeout: Self.listTimeout)
            items.append(contentsOf: result[key] as? [[String: Any]] ?? [])
            guard let next = result["nextCursor"] as? String, !next.isEmpty else { return items }
            cursor = next
        }
        return items
    }

    private func requestResult(_ method: String, params: [String: Any]?, timeout: TimeInterval) async throws -> [String: Any] {
        let response = try await transport.request(method, params: params, timeout: timeout)
        if let error = response["error"] as? [String: Any] {
            let code = error["code"] as? Int ?? 0
            let message = error["message"] as? String ?? "Unknown server error"
            throw MCPError(message: "\(message) (code \(code))")
        }
        return response["result"] as? [String: Any] ?? [:]
    }
}
