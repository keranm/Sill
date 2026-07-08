import SwiftUI
import AppKit

/// The MCP explorer — the API client's sibling for people building with or
/// for the Model Context Protocol: connect to a server (a local command or
/// a remote HTTP endpoint), browse what it exposes (tools, resources,
/// prompts), and invoke any of it with arguments generated from each tool's
/// own JSON schema.
///
/// Lives as an ordinary tab (a `BrowserTab` with the internal `sill://`
/// scheme — see ShellView.stage and TabStore.newMCPClientTab), same as the
/// API client, and deliberately mirrors its structure and styling: sidebar
/// on the left (saved servers, the analog of environments/collections), a
/// browsable capability column, and a detail pane for the selected item.
///
/// Connecting launches a process (stdio) or opens an HTTP session — a real,
/// user-initiated action in the same explicit-exception category as the API
/// client's Send: the feature's entire purpose is talking to the server the
/// user just pointed it at.
struct MCPClientView: View {
    @Bindable var store: TabStore
    let tab: BrowserTab
    /// Same underlying object every time this view is (re)constructed for
    /// the same browser tab — the connection and half-typed arguments live
    /// there, not in view `@State`.
    private let state: MCPTabState

    private static let sidebarWidth: CGFloat = 240
    private static let capabilitiesWidth: CGFloat = 230

    init(store: TabStore, tab: BrowserTab) {
        self._store = Bindable(store)
        self.tab = tab
        self.state = store.mcpClient.tabState(for: tab.id)
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider().overlay(Tokens.hairline)

            VStack(spacing: 0) {
                mainArea
                if !state.logLines.isEmpty {
                    Divider().overlay(Tokens.hairline)
                    MCPLogStrip(lines: state.logLines)
                }
            }
        }
        .background(Tokens.canvas)
    }

    // MARK: Sidebar — the saved server list. The analog of the API client's
    // environments/collections: browsable, editable in place, permanent.

    private var sidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("SERVERS")
                        .font(Tokens.font(10, .medium))
                        .kerning(0.8)
                        .foregroundStyle(Tokens.inkGhost)
                    Spacer()
                    Button {
                        store.mcpClient.addServer()
                    } label: {
                        Image(systemName: "plus.circle")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Tokens.inkGhost)
                    }
                    .buttonStyle(.plain)
                    .help("Add server")
                }

                if store.mcpClient.servers.isEmpty {
                    Text("No servers yet. Add one — a local command like `npx @modelcontextprotocol/server-everything`, or a remote HTTP endpoint.")
                        .font(Tokens.font(11.5))
                        .foregroundStyle(Tokens.inkGhost)
                }

                ForEach(store.mcpClient.servers) { server in
                    MCPServerRow(
                        server: server,
                        phase: state.selectedServerID == server.id ? state.phase : .disconnected,
                        onChange: { store.mcpClient.updateServer($0) },
                        onConnect: { store.mcpClient.connect(state, to: server) },
                        onDisconnect: { store.mcpClient.disconnect(state) },
                        onDelete: {
                            if state.selectedServerID == server.id {
                                store.mcpClient.disconnect(state)
                            }
                            store.mcpClient.removeServer(server)
                        }
                    )
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 14)
        }
        .frame(width: Self.sidebarWidth)
        .background(Tokens.well.opacity(0.4))
    }

    // MARK: Main area

    @ViewBuilder
    private var mainArea: some View {
        switch state.phase {
        case .connected:
            HStack(spacing: 0) {
                capabilitiesColumn
                Divider().overlay(Tokens.hairline)
                detailPane
            }
        case .connecting:
            centeredNote {
                ProgressView().controlSize(.small)
                Text("Connecting…")
                    .font(Tokens.font(12.5))
                    .foregroundStyle(Tokens.inkFaint)
            }
        case .failed(let message):
            centeredNote {
                Text("Couldn't connect")
                    .font(Tokens.font(13, .semibold))
                    .foregroundStyle(Tokens.ink)
                Text(message)
                    .font(Tokens.font(12))
                    .foregroundStyle(Tokens.danger)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
                    .textSelection(.enabled)
            }
        case .disconnected:
            centeredNote {
                Text("MCP Explorer")
                    .font(Tokens.font(15, .semibold))
                    .foregroundStyle(Tokens.ink)
                Text("Add a server in the sidebar and connect to browse its tools, resources, and prompts.")
                    .font(Tokens.font(12.5))
                    .foregroundStyle(Tokens.inkFaint)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
            }
        }
    }

    private func centeredNote<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(spacing: 8) { content() }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Capabilities column — everything the connected server exposes,
    // grouped the way the protocol itself groups it.

    private var capabilitiesColumn: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let info = state.serverInfo {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(info.name)
                            .font(Tokens.font(12.5, .semibold))
                            .foregroundStyle(Tokens.ink)
                        Text("\(info.version.isEmpty ? "" : "v\(info.version) · ")protocol \(info.protocolVersion)")
                            .font(Tokens.font(10.5))
                            .foregroundStyle(Tokens.inkGhost)
                    }
                }

                if !state.tools.isEmpty {
                    capabilitySection("TOOLS (\(state.tools.count))") {
                        ForEach(state.tools) { tool in
                            capabilityRow(title: tool.name, subtitle: tool.description, isSelected: state.selection == .tool(tool.name)) {
                                select(.tool(tool.name))
                            }
                        }
                    }
                }

                if !state.resources.isEmpty {
                    capabilitySection("RESOURCES (\(state.resources.count))") {
                        ForEach(state.resources) { resource in
                            capabilityRow(title: resource.name ?? resource.uri, subtitle: resource.uri, isSelected: state.selection == .resource(resource.uri)) {
                                select(.resource(resource.uri))
                            }
                        }
                    }
                }

                if !state.prompts.isEmpty {
                    capabilitySection("PROMPTS (\(state.prompts.count))") {
                        ForEach(state.prompts) { prompt in
                            capabilityRow(title: prompt.name, subtitle: prompt.description, isSelected: state.selection == .prompt(prompt.name)) {
                                select(.prompt(prompt.name))
                            }
                        }
                    }
                }

                if state.tools.isEmpty, state.resources.isEmpty, state.prompts.isEmpty {
                    Text("The server connected but exposes no tools, resources, or prompts.")
                        .font(Tokens.font(11.5))
                        .foregroundStyle(Tokens.inkGhost)
                }
            }
            .padding(12)
        }
        .frame(width: Self.capabilitiesWidth)
    }

    private func select(_ selection: MCPSelection) {
        guard state.selection != selection else { return }
        state.selection = selection
        state.clearResults()
    }

    private func capabilitySection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(Tokens.font(10, .medium))
                .kerning(0.8)
                .foregroundStyle(Tokens.inkGhost)
            content()
        }
    }

    private func capabilityRow(title: String, subtitle: String?, isSelected: Bool, onSelect: @escaping () -> Void) -> some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(Tokens.font(12, isSelected ? .medium : .regular))
                    .foregroundStyle(Tokens.ink)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(Tokens.font(10.5))
                        .foregroundStyle(Tokens.inkGhost)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: Tokens.radiusControl).fill(isSelected ? Tokens.accentWash : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: Detail pane

    @ViewBuilder
    private var detailPane: some View {
        switch state.selection {
        case .tool(let name):
            if let tool = state.tools.first(where: { $0.name == name }) {
                MCPToolDetailView(state: state, tool: tool)
                    .id(name)
            }
        case .resource(let uri):
            if let resource = state.resources.first(where: { $0.uri == uri }) {
                MCPResourceDetailView(state: state, resource: resource)
                    .id(uri)
            }
        case .prompt(let name):
            if let prompt = state.prompts.first(where: { $0.name == name }) {
                MCPPromptDetailView(state: state, prompt: prompt)
                    .id(name)
            }
        case nil:
            centeredNote {
                Text("Select a tool, resource, or prompt to inspect and invoke it.")
                    .font(Tokens.font(12.5))
                    .foregroundStyle(Tokens.inkGhost)
            }
        }
    }
}

// MARK: - Server row

/// One saved server in the sidebar — status dot, editable name, disclosure
/// into its transport fields, connect/disconnect. Same in-place editing
/// register as the API client's EnvironmentRow.
private struct MCPServerRow: View {
    let server: MCPServerConfig
    let phase: MCPConnectionPhase
    let onChange: (MCPServerConfig) -> Void
    let onConnect: () -> Void
    let onDisconnect: () -> Void
    let onDelete: () -> Void

    @State private var expanded = false

    private var isConnectedHere: Bool {
        if case .connected = phase { return true }
        return false
    }

    private var statusColor: Color {
        switch phase {
        case .connected: return Tokens.success
        case .connecting: return Tokens.warning
        case .failed: return Tokens.danger
        case .disconnected: return Tokens.inkGhost.opacity(0.4)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Button {
                    expanded.toggle()
                } label: {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(Tokens.inkGhost)
                        .frame(width: 10)
                }
                .buttonStyle(.plain)

                Circle()
                    .fill(statusColor)
                    .frame(width: 7, height: 7)

                TextField("Name", text: Binding(
                    get: { server.name },
                    set: { var updated = server; updated.name = $0; onChange(updated) }
                ))
                .textFieldStyle(.plain)
                .font(Tokens.font(12, .medium))

                Spacer(minLength: 0)

                Button(action: onDelete) {
                    Image(systemName: "trash")
                        .foregroundStyle(Tokens.inkGhost)
                }
                .buttonStyle(.plain)
            }

            if expanded {
                editor
                    .padding(.leading, 16)
            }

            Button {
                isConnectedHere || phase == .connecting ? onDisconnect() : onConnect()
            } label: {
                if phase == .connecting {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.mini)
                        Text("Cancel")
                            .font(Tokens.font(11.5, .medium))
                    }
                } else {
                    Text(isConnectedHere ? "Disconnect" : "Connect")
                        .font(Tokens.font(11.5, .medium))
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .padding(.leading, 16)

            if case .failed(let message) = phase {
                Text(message)
                    .font(Tokens.font(10.5))
                    .foregroundStyle(Tokens.danger)
                    .lineLimit(3)
                    .padding(.leading, 16)
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: Tokens.radiusControl).fill(isConnectedHere ? Tokens.accentWash : Tokens.well.opacity(0.5)))
    }

    @ViewBuilder
    private var editor: some View {
        VStack(alignment: .leading, spacing: 6) {
            MCPSegmentPicker(
                options: MCPServerConfig.Transport.allCases.map { ($0.rawValue, $0.label) },
                selection: Binding(
                    get: { server.transport.rawValue },
                    set: { var updated = server; updated.transport = MCPServerConfig.Transport(rawValue: $0) ?? .stdio; onChange(updated) }
                )
            )

            switch server.transport {
            case .stdio:
                fieldLabel("Command")
                editorField("npx @modelcontextprotocol/server-everything", text: Binding(
                    get: { server.command },
                    set: { var updated = server; updated.command = $0; onChange(updated) }
                ))
                fieldLabel("Environment variables")
                MCPKeyValueEditor(
                    keyPlaceholder: "NAME",
                    valuePlaceholder: "value",
                    values: Binding(
                        get: { server.environment },
                        set: { var updated = server; updated.environment = $0; onChange(updated) }
                    )
                )
            case .http:
                fieldLabel("URL")
                editorField("https://example.com/mcp", text: Binding(
                    get: { server.urlString },
                    set: { var updated = server; updated.urlString = $0; onChange(updated) }
                ))
                fieldLabel("Headers")
                MCPKeyValueEditor(
                    keyPlaceholder: "Authorization",
                    valuePlaceholder: "Bearer …",
                    values: Binding(
                        get: { server.headers },
                        set: { var updated = server; updated.headers = $0; onChange(updated) }
                    )
                )
            }
        }
    }

    private func fieldLabel(_ text: String) -> some View {
        Text(text)
            .font(Tokens.font(10))
            .foregroundStyle(Tokens.inkGhost)
    }

    private func editorField(_ placeholder: String, text: Binding<String>) -> some View {
        TextField(placeholder, text: text)
            .textFieldStyle(.plain)
            .font(.system(size: 11, design: .monospaced))
            .padding(5)
            .background(RoundedRectangle(cornerRadius: 5).fill(Tokens.well))
    }
}

/// A segmented picker in the app's own accent rather than the system-blue
/// NSSegmentedControl (whose selection colour ignores SwiftUI `.tint` on
/// macOS) — the selected segment matches Call Tool's teal, per the token
/// layer's rule that accent is the only saturated colour in these panes.
private struct MCPSegmentPicker: View {
    let options: [(tag: String, label: String)]
    @Binding var selection: String

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.tag) { option in
                let isSelected = selection == option.tag
                Button {
                    selection = option.tag
                } label: {
                    Text(option.label)
                        .font(Tokens.font(11, isSelected ? .medium : .regular))
                        .foregroundStyle(isSelected ? Color.white : Tokens.inkFaint)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(RoundedRectangle(cornerRadius: 5).fill(isSelected ? Tokens.accent : Color.clear))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: Tokens.radiusControl).fill(Tokens.well))
        .fixedSize()
    }
}

/// A small dictionary editor (env vars, HTTP headers) — rows of key/value
/// fields plus a trailing add button. Operates on a plain dictionary
/// binding; row order is presentation-only.
private struct MCPKeyValueEditor: View {
    let keyPlaceholder: String
    let valuePlaceholder: String
    @Binding var values: [String: String]

    @State private var rows: [HeaderRow]

    init(keyPlaceholder: String, valuePlaceholder: String, values: Binding<[String: String]>) {
        self.keyPlaceholder = keyPlaceholder
        self.valuePlaceholder = valuePlaceholder
        self._values = values
        let existing = values.wrappedValue.sorted { $0.key < $1.key }.map { HeaderRow(key: $0.key, value: $0.value) }
        self._rows = State(initialValue: existing.isEmpty ? [HeaderRow()] : existing)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach($rows) { $row in
                HStack(spacing: 4) {
                    TextField(keyPlaceholder, text: $row.key)
                        .textFieldStyle(.plain)
                        .font(.system(size: 11, design: .monospaced))
                        .padding(5)
                        .background(RoundedRectangle(cornerRadius: 5).fill(Tokens.well))
                        .onChange(of: row.key) { commit() }
                    TextField(valuePlaceholder, text: $row.value)
                        .textFieldStyle(.plain)
                        .font(.system(size: 11, design: .monospaced))
                        .padding(5)
                        .background(RoundedRectangle(cornerRadius: 5).fill(Tokens.well))
                        .onChange(of: row.value) { commit() }
                }
            }
            Button {
                rows.append(HeaderRow())
            } label: {
                Image(systemName: "plus.circle")
                    .foregroundStyle(Tokens.inkGhost)
            }
            .buttonStyle(.plain)
        }
    }

    private func commit() {
        values = Dictionary(uniqueKeysWithValues: rows.filter { !$0.key.isEmpty }.map { ($0.key, $0.value) })
    }
}

// MARK: - Tool detail

/// One field of a tool's argument form, lifted out of its JSON schema.
private struct MCPSchemaField: Identifiable {
    var id: String { name }
    let name: String
    let type: String
    let description: String?
    let required: Bool
    let enumValues: [String]?

    static func fields(from schema: [String: Any]?) -> [MCPSchemaField] {
        guard let properties = schema?["properties"] as? [String: Any] else { return [] }
        let required = Set(schema?["required"] as? [String] ?? [])
        return properties
            .map { name, raw -> MCPSchemaField in
                let property = raw as? [String: Any] ?? [:]
                return MCPSchemaField(
                    name: name,
                    type: property["type"] as? String ?? "string",
                    description: property["description"] as? String,
                    required: required.contains(name),
                    enumValues: (property["enum"] as? [Any])?.map { "\($0)" }
                )
            }
            // JSONSerialization loses the schema's declared order, so pick a
            // stable, sensible one: required fields first, then alphabetical.
            .sorted { ($0.required ? 0 : 1, $0.name) < ($1.required ? 0 : 1, $1.name) }
    }
}

private struct MCPToolDetailView: View {
    let state: MCPTabState
    let tool: MCPTool

    @State private var rawJSONMode = false
    @State private var argsExpanded = true

    private var fields: [MCPSchemaField] {
        MCPSchemaField.fields(from: tool.inputSchema)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                MCPDetailHeader(kind: "TOOL", title: tool.name, description: tool.description)

                if !fields.isEmpty || rawJSONMode {
                    MCPSectionDisclosure(title: "Arguments", expanded: $argsExpanded) {
                        VStack(alignment: .leading, spacing: 8) {
                            if rawJSONMode {
                                rawJSONEditor
                            } else {
                                ForEach(fields) { field in
                                    argumentField(field)
                                }
                            }
                            Button(rawJSONMode ? "Edit as form" : "Edit as JSON") {
                                toggleRawMode()
                            }
                            .buttonStyle(.plain)
                            .font(Tokens.font(11))
                            .foregroundStyle(Tokens.accent)
                        }
                    }
                }

                HStack(spacing: 8) {
                    Button(action: call) {
                        if state.isInvoking {
                            ProgressView().controlSize(.small)
                        } else {
                            Text("Call Tool")
                                .font(Tokens.font(12.5, .medium))
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Tokens.accent)
                    .disabled(state.isInvoking)
                }

                if let error = state.invokeError {
                    Text(error)
                        .font(Tokens.font(12))
                        .foregroundStyle(Tokens.danger)
                        .textSelection(.enabled)
                }

                if let result = state.toolResult {
                    Divider().overlay(Tokens.hairline)
                    MCPToolResultView(result: result)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func draftBinding(_ field: String) -> Binding<String> {
        Binding(
            get: { state.argumentDrafts[tool.name]?[field] ?? "" },
            set: { state.argumentDrafts[tool.name, default: [:]][field] = $0 }
        )
    }

    @ViewBuilder
    private func argumentField(_ field: MCPSchemaField) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Text(field.name)
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(Tokens.ink)
                if field.required {
                    Text("required")
                        .font(Tokens.font(9.5))
                        .foregroundStyle(Tokens.warning)
                }
                Text(field.type)
                    .font(Tokens.font(9.5))
                    .foregroundStyle(Tokens.inkGhost)
            }
            if let description = field.description, !description.isEmpty {
                Text(description)
                    .font(Tokens.font(10.5))
                    .foregroundStyle(Tokens.inkFaint)
            }

            if field.type == "boolean" {
                MCPSegmentPicker(
                    options: [("", "—"), ("true", "true"), ("false", "false")],
                    selection: draftBinding(field.name)
                )
            } else if let enumValues = field.enumValues, !enumValues.isEmpty {
                Picker("", selection: draftBinding(field.name)) {
                    Text("—").tag("")
                    ForEach(enumValues, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden()
                .frame(maxWidth: 240)
            } else if field.type == "object" || field.type == "array" {
                TextEditor(text: draftBinding(field.name))
                    .font(.system(size: 11.5, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 48, maxHeight: 120)
                    .padding(4)
                    .background(RoundedRectangle(cornerRadius: Tokens.radiusControl).fill(Tokens.well))
            } else {
                TextField(field.type == "string" ? "" : field.type, text: draftBinding(field.name))
                    .textFieldStyle(.plain)
                    .font(.system(size: 11.5, design: .monospaced))
                    .padding(6)
                    .background(RoundedRectangle(cornerRadius: Tokens.radiusControl).fill(Tokens.well))
            }
        }
    }

    private var rawJSONEditor: some View {
        TextEditor(text: Binding(
            get: { state.rawJSONDrafts[tool.name] ?? "{\n\n}" },
            set: { state.rawJSONDrafts[tool.name] = $0 }
        ))
        .font(.system(size: 11.5, design: .monospaced))
        .scrollContentBackground(.hidden)
        .frame(minHeight: 100, maxHeight: 240)
        .padding(6)
        .background(RoundedRectangle(cornerRadius: Tokens.radiusControl).fill(Tokens.well))
    }

    /// Switching to JSON mode carries the form's current values along so
    /// the two editors are views of the same draft, not rivals.
    private func toggleRawMode() {
        if !rawJSONMode {
            if let arguments = try? formArguments(),
               let data = try? JSONSerialization.data(withJSONObject: arguments, options: [.prettyPrinted, .sortedKeys]),
               let text = String(data: data, encoding: .utf8) {
                state.rawJSONDrafts[tool.name] = text
            }
        }
        rawJSONMode.toggle()
    }

    private func formArguments() throws -> [String: Any] {
        var arguments: [String: Any] = [:]
        for field in fields {
            let text = (state.argumentDrafts[tool.name]?[field.name] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            switch field.type {
            case "boolean":
                arguments[field.name] = text == "true"
            case "integer":
                guard let value = Int(text) else { throw MCPError(message: "\(field.name) must be an integer.") }
                arguments[field.name] = value
            case "number":
                guard let value = Double(text) else { throw MCPError(message: "\(field.name) must be a number.") }
                arguments[field.name] = value
            case "object", "array":
                guard let data = text.data(using: .utf8), let value = try? JSONSerialization.jsonObject(with: data) else {
                    throw MCPError(message: "\(field.name) must be valid JSON.")
                }
                arguments[field.name] = value
            default:
                arguments[field.name] = text
            }
        }
        return arguments
    }

    private func call() {
        guard let connection = state.connection else { return }
        let arguments: [String: Any]
        do {
            if rawJSONMode {
                let text = state.rawJSONDrafts[tool.name] ?? "{}"
                guard let data = text.data(using: .utf8),
                      let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    throw MCPError(message: "Arguments must be a JSON object.")
                }
                arguments = parsed
            } else {
                arguments = try formArguments()
            }
        } catch {
            state.invokeError = error.localizedDescription
            return
        }

        state.invokeError = nil
        state.toolResult = nil
        state.isInvoking = true
        let state = state
        Task {
            do {
                let result = try await connection.callTool(name: tool.name, arguments: arguments)
                state.toolResult = result
            } catch {
                state.invokeError = error.localizedDescription
            }
            state.isInvoking = false
        }
    }
}

private struct MCPToolResultView: View {
    let result: MCPToolResult

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("Result")
                    .font(Tokens.font(13, .semibold))
                    .foregroundStyle(Tokens.ink)
                if result.isError {
                    Text("error")
                        .font(Tokens.font(10.5, .semibold))
                        .foregroundStyle(Tokens.danger)
                }
            }

            ForEach(result.content) { item in
                MCPContentItemView(item: item, errorTinted: result.isError)
            }

            if let structured = result.structuredContent {
                Text("Structured content")
                    .font(Tokens.font(11.5, .medium))
                    .foregroundStyle(Tokens.inkFaint)
                JSONTreeView(value: structured)
            }
        }
    }
}

// MARK: - Resource detail

private struct MCPResourceDetailView: View {
    let state: MCPTabState
    let resource: MCPResource

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                MCPDetailHeader(kind: "RESOURCE", title: resource.name ?? resource.uri, description: resource.description)

                VStack(alignment: .leading, spacing: 2) {
                    Text(resource.uri)
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(Tokens.ink)
                        .textSelection(.enabled)
                    if let mimeType = resource.mimeType {
                        Text(mimeType)
                            .font(Tokens.font(10.5))
                            .foregroundStyle(Tokens.inkGhost)
                    }
                }

                Button(action: read) {
                    if state.isInvoking {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Read Resource")
                            .font(Tokens.font(12.5, .medium))
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(Tokens.accent)
                .disabled(state.isInvoking)

                if let error = state.invokeError {
                    Text(error)
                        .font(Tokens.font(12))
                        .foregroundStyle(Tokens.danger)
                        .textSelection(.enabled)
                }

                if let contents = state.resourceContents {
                    Divider().overlay(Tokens.hairline)
                    ForEach(contents) { item in
                        MCPContentItemView(item: item, errorTinted: false)
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func read() {
        guard let connection = state.connection else { return }
        state.invokeError = nil
        state.resourceContents = nil
        state.isInvoking = true
        let state = state
        Task {
            do {
                state.resourceContents = try await connection.readResource(uri: resource.uri)
            } catch {
                state.invokeError = error.localizedDescription
            }
            state.isInvoking = false
        }
    }
}

// MARK: - Prompt detail

private struct MCPPromptDetailView: View {
    let state: MCPTabState
    let prompt: MCPPrompt

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                MCPDetailHeader(kind: "PROMPT", title: prompt.name, description: prompt.description)

                if !prompt.arguments.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(prompt.arguments) { argument in
                            VStack(alignment: .leading, spacing: 3) {
                                HStack(spacing: 4) {
                                    Text(argument.name)
                                        .font(.system(size: 11.5, design: .monospaced))
                                        .foregroundStyle(Tokens.ink)
                                    if argument.required {
                                        Text("required")
                                            .font(Tokens.font(9.5))
                                            .foregroundStyle(Tokens.warning)
                                    }
                                }
                                if let description = argument.description, !description.isEmpty {
                                    Text(description)
                                        .font(Tokens.font(10.5))
                                        .foregroundStyle(Tokens.inkFaint)
                                }
                                TextField("", text: Binding(
                                    get: { state.argumentDrafts[prompt.name]?[argument.name] ?? "" },
                                    set: { state.argumentDrafts[prompt.name, default: [:]][argument.name] = $0 }
                                ))
                                .textFieldStyle(.plain)
                                .font(.system(size: 11.5, design: .monospaced))
                                .padding(6)
                                .background(RoundedRectangle(cornerRadius: Tokens.radiusControl).fill(Tokens.well))
                            }
                        }
                    }
                }

                Button(action: get) {
                    if state.isInvoking {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Get Prompt")
                            .font(Tokens.font(12.5, .medium))
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(Tokens.accent)
                .disabled(state.isInvoking)

                if let error = state.invokeError {
                    Text(error)
                        .font(Tokens.font(12))
                        .foregroundStyle(Tokens.danger)
                        .textSelection(.enabled)
                }

                if let result = state.promptResult {
                    Divider().overlay(Tokens.hairline)
                    if let description = result.description, !description.isEmpty {
                        Text(description)
                            .font(Tokens.font(12))
                            .foregroundStyle(Tokens.inkFaint)
                    }
                    ForEach(result.messages) { message in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(message.role.uppercased())
                                .font(Tokens.font(10, .medium))
                                .kerning(0.8)
                                .foregroundStyle(Tokens.inkGhost)
                            MCPContentItemView(item: message.content, errorTinted: false)
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: Tokens.radiusControl).fill(Tokens.well.opacity(0.6)))
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func get() {
        guard let connection = state.connection else { return }
        var arguments: [String: String] = [:]
        for argument in prompt.arguments {
            let text = state.argumentDrafts[prompt.name]?[argument.name] ?? ""
            if !text.isEmpty { arguments[argument.name] = text }
        }
        state.invokeError = nil
        state.promptResult = nil
        state.isInvoking = true
        let state = state
        Task {
            do {
                state.promptResult = try await connection.getPrompt(name: prompt.name, arguments: arguments)
            } catch {
                state.invokeError = error.localizedDescription
            }
            state.isInvoking = false
        }
    }
}

// MARK: - Shared detail pieces

private struct MCPDetailHeader: View {
    let kind: String
    let title: String
    let description: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(kind)
                .font(Tokens.font(10, .medium))
                .kerning(0.8)
                .foregroundStyle(Tokens.inkGhost)
            Text(title)
                .font(.system(size: 14, weight: .semibold, design: .monospaced))
                .foregroundStyle(Tokens.ink)
                .textSelection(.enabled)
            if let description, !description.isEmpty {
                Text(description)
                    .font(Tokens.font(12))
                    .foregroundStyle(Tokens.inkFaint)
                    .textSelection(.enabled)
            }
        }
    }
}

/// Renders one MCP content block — text (as a JSON tree when it parses as
/// JSON, since tool results are so often stringified JSON), images, and
/// resource links/embeds.
private struct MCPContentItemView: View {
    let item: MCPContentItem
    let errorTinted: Bool

    var body: some View {
        switch item {
        case .text(let text):
            if let data = text.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data),
               json is [String: Any] || json is [Any] {
                JSONTreeView(value: json)
            } else {
                Text(text)
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(errorTinted ? Tokens.danger : Tokens.ink)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        case .image(let data, let mimeType):
            if let image = NSImage(data: data) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: 480, maxHeight: 360, alignment: .leading)
                    .clipShape(RoundedRectangle(cornerRadius: Tokens.radiusControl))
            } else {
                Text("\(mimeType.isEmpty ? "media" : mimeType) (\(data.count) bytes)")
                    .font(Tokens.font(11.5))
                    .foregroundStyle(Tokens.inkGhost)
            }
        case .resourceLink(let uri, let name):
            HStack(spacing: 4) {
                Image(systemName: "link")
                    .font(.system(size: 9))
                    .foregroundStyle(Tokens.inkGhost)
                Text(name ?? uri)
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(Tokens.ink)
                    .textSelection(.enabled)
            }
        case .embeddedResource(let uri, let mimeType, let text, let blob):
            VStack(alignment: .leading, spacing: 4) {
                if let uri {
                    Text(uri)
                        .font(Tokens.font(10.5))
                        .foregroundStyle(Tokens.inkGhost)
                        .textSelection(.enabled)
                }
                if let text {
                    if let data = text.data(using: .utf8),
                       let json = try? JSONSerialization.jsonObject(with: data),
                       json is [String: Any] || json is [Any] {
                        JSONTreeView(value: json)
                    } else {
                        Text(text)
                            .font(.system(size: 11.5, design: .monospaced))
                            .foregroundStyle(Tokens.ink)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                } else if let blob {
                    if let image = NSImage(data: blob), mimeType?.hasPrefix("image/") == true {
                        Image(nsImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(maxWidth: 480, maxHeight: 360, alignment: .leading)
                            .clipShape(RoundedRectangle(cornerRadius: Tokens.radiusControl))
                    } else {
                        Text("\(mimeType ?? "binary") (\(blob.count) bytes)")
                            .font(Tokens.font(11.5))
                            .foregroundStyle(Tokens.inkGhost)
                    }
                }
            }
        case .other(let raw):
            JSONTreeView(value: raw)
        }
    }
}

/// The same whole-row-clickable disclosure the API client uses (its
/// SectionDisclosure is file-private there; duplicated rather than exposed,
/// matching how the two tools stay siblings, not entangled).
private struct MCPSectionDisclosure<Content: View>: View {
    let title: String
    @Binding var expanded: Bool
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                expanded.toggle()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Tokens.inkGhost)
                        .frame(width: 10)
                    Text(title)
                        .font(Tokens.font(12.5, .medium))
                        .foregroundStyle(Tokens.ink)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                content()
                    .padding(.top, 6)
                    .padding(.leading, 16)
            }
        }
    }
}

/// The server's own voice — stdio stderr, logging notifications, lifecycle
/// lines — pinned under the main area. What someone debugging their own
/// server is actually here for, half the time.
private struct MCPLogStrip: View {
    let lines: [String]

    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                expanded.toggle()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(Tokens.inkGhost)
                    Text("Server log (\(lines.count))")
                        .font(Tokens.font(11, .medium))
                        .foregroundStyle(Tokens.inkFaint)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 1) {
                            ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                                Text(line)
                                    .font(.system(size: 10.5, design: .monospaced))
                                    .foregroundStyle(Tokens.inkFaint)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .id(index)
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.bottom, 8)
                    }
                    .frame(height: 140)
                    .onAppear { proxy.scrollTo(lines.count - 1, anchor: .bottom) }
                    .onChange(of: lines.count) { proxy.scrollTo(lines.count - 1, anchor: .bottom) }
                }
            }
        }
        .background(Tokens.well.opacity(0.4))
    }
}
