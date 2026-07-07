import SwiftUI

/// developer-tools.md #3 — API client (lite): method/URL/headers/body,
/// response viewer, history, named environments, and collections imported
/// from OpenAPI/Swagger or Postman Collection files — Postman's core loop,
/// deliberately still without scripting or team features.
///
/// Lives as an ordinary tab (a `BrowserTab` with the internal `sill://`
/// scheme — see ShellView.stage and TabStore.newAPIClientTab), not a
/// detached window, so it reorders/pins/closes through exactly the same
/// machinery as any other tab. Deliberately does not participate in Panel
/// view — `formPanel` rejects `sill://` tabs on either side.
///
/// Sending a request is a real, user-initiated network call from Sill's own
/// code — an explicit exception to PRD §3.2, same category as Sparkle's
/// update check and favicon fetching. Unlike those two, this one needs no
/// justification beyond its own existence: the entire feature's purpose is
/// firing a request the user just constructed, the same as clicking a link.
struct APIClientView: View {
    @Bindable var store: TabStore
    let tab: BrowserTab
    /// Fetched once, in `init`, from `APIClientStore`'s per-tab cache — the
    /// same underlying object comes back every time this view is
    /// (re)constructed for the same tab, so a half-written request survives
    /// switching away and back even though the View struct itself doesn't.
    @Bindable private var draft: APIClientDraftState

    @State private var historyShown = false
    @State private var environmentsShown = false
    @State private var collectionsShown = false
    @State private var importErrorMessage: String?
    @State private var importCollectionShown = false
    @State private var importURLText = ""
    // Plain @State bools, not DisclosureGroup's own isExpanded — on macOS,
    // DisclosureGroup only toggles when its tiny triangle is clicked
    // precisely, not the label text next to it, which reads as "nothing
    // happens when I click this." SectionDisclosure below makes the whole
    // row a real Button instead.
    @State private var headersExpanded = true
    @State private var bodyExpanded = true
    @State private var responseHeadersExpanded = false

    private static let methods = ["GET", "POST", "PUT", "PATCH", "DELETE", "HEAD", "OPTIONS"]

    init(store: TabStore, tab: BrowserTab) {
        self._store = Bindable(store)
        self.tab = tab
        self._draft = Bindable(store.apiClient.draftState(for: tab.id))
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider().overlay(Tokens.hairline)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    requestLine
                    headersEditor
                    bodyEditor

                    if let errorMessage = draft.errorMessage {
                        Text(errorMessage)
                            .font(Tokens.font(12))
                            .foregroundStyle(Tokens.danger)
                    }

                    if let response = draft.response {
                        Divider().overlay(Tokens.hairline)
                        responseView(response)
                    }
                }
                .padding(16)
            }
        }
        .background(Tokens.canvas)
    }

    private var selectedEnvironment: APIEnvironment? {
        store.apiClient.environments.first { $0.id == draft.selectedEnvironmentID }
    }

    // MARK: Toolbar

    private var toolbar: some View {
        HStack(spacing: 8) {
            Menu {
                Button("No environment") { draft.selectedEnvironmentID = nil }
                if !store.apiClient.environments.isEmpty {
                    Divider()
                    ForEach(store.apiClient.environments) { environment in
                        Button(environment.name) { draft.selectedEnvironmentID = environment.id }
                    }
                }
                Divider()
                Button("Manage Environments…") { environmentsShown = true }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "shippingbox")
                    Text(selectedEnvironment?.name ?? "No environment")
                }
                .font(Tokens.font(11.5))
                .foregroundStyle(Tokens.inkFaint)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            Spacer()

            Button {
                collectionsShown = true
            } label: {
                Image(systemName: "folder")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Tokens.inkGhost)
            }
            .buttonStyle(.plain)
            .help("Collections")
            .popover(isPresented: $collectionsShown) {
                collectionsList
            }

            Button {
                historyShown = true
            } label: {
                Image(systemName: "clock")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Tokens.inkGhost)
            }
            .buttonStyle(.plain)
            .help("Request history")
            .popover(isPresented: $historyShown) {
                historyList
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .popover(isPresented: $environmentsShown) {
            environmentsEditor
        }
    }

    // MARK: Request

    private var requestLine: some View {
        HStack(spacing: 8) {
            Picker("", selection: $draft.method) {
                ForEach(Self.methods, id: \.self) { Text($0) }
            }
            .labelsHidden()
            .frame(width: 100)

            TextField("https://api.example.com/…", text: $draft.urlText)
                .textFieldStyle(.plain)
                .font(Tokens.font(12.5))
                .padding(.horizontal, 9)
                .padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: Tokens.radiusControl).fill(Tokens.well))
                .onSubmit(send)

            Button(action: send) {
                if draft.isSending {
                    ProgressView().controlSize(.small)
                } else {
                    Text("Send")
                        .font(Tokens.font(12.5, .medium))
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(Tokens.accent)
            .disabled(draft.urlText.trimmingCharacters(in: .whitespaces).isEmpty || draft.isSending)
        }
    }

    // MARK: Headers

    private var headersEditor: some View {
        SectionDisclosure(title: "Headers", expanded: $headersExpanded) {
            VStack(spacing: 4) {
                ForEach($draft.headerRows) { $row in
                    HStack(spacing: 6) {
                        TextField("Key", text: $row.key)
                            .textFieldStyle(.plain)
                            .font(Tokens.font(12))
                            .padding(6)
                            .background(RoundedRectangle(cornerRadius: 5).fill(Tokens.well))
                        TextField("Value", text: $row.value)
                            .textFieldStyle(.plain)
                            .font(Tokens.font(12))
                            .padding(6)
                            .background(RoundedRectangle(cornerRadius: 5).fill(Tokens.well))
                        Button {
                            draft.headerRows.removeAll { $0.id == row.id }
                        } label: {
                            Image(systemName: "minus.circle")
                                .foregroundStyle(Tokens.inkGhost)
                        }
                        .buttonStyle(.plain)
                    }
                }
                Button {
                    draft.headerRows.append(HeaderRow())
                } label: {
                    Label("Add header", systemImage: "plus")
                        .font(Tokens.font(11.5))
                        .foregroundStyle(Tokens.inkFaint)
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: Body

    private var bodyEditor: some View {
        SectionDisclosure(title: "Body", expanded: $bodyExpanded) {
            TextEditor(text: $draft.bodyText)
                .font(.system(size: 12, design: .monospaced))
                .frame(minHeight: 100, maxHeight: 220)
                .padding(6)
                .background(RoundedRectangle(cornerRadius: Tokens.radiusControl).fill(Tokens.well))
        }
    }

    // MARK: Response

    @ViewBuilder
    private func responseView(_ response: APIResponse) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Text("\(response.status)")
                    .font(Tokens.font(13, .semibold))
                    .foregroundStyle(response.status < 400 ? Tokens.accent : Tokens.danger)
                Text(String(format: "%.0f ms", response.duration * 1000))
                    .font(Tokens.font(11.5))
                    .foregroundStyle(Tokens.inkGhost)
                Text("\(response.bodyData.count) bytes")
                    .font(Tokens.font(11.5))
                    .foregroundStyle(Tokens.inkGhost)
            }

            if !response.headers.isEmpty {
                SectionDisclosure(title: "Response headers", expanded: $responseHeadersExpanded) {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(response.headers.sorted(by: { $0.key < $1.key }), id: \.key) { key, value in
                            HStack(alignment: .top, spacing: 4) {
                                Text("\(key):").foregroundStyle(Tokens.inkFaint)
                                Text(value).foregroundStyle(Tokens.ink)
                            }
                            .font(.system(size: 11, design: .monospaced))
                        }
                    }
                }
            }

            // developer-tools.md #4 reused here: same JSON tree the in-page
            // formatter renders, native, in the response viewer.
            if let json = response.parsedJSON {
                JSONTreeView(value: json)
            } else if let text = String(data: response.bodyData, encoding: .utf8) {
                Text(text)
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(Tokens.ink)
                    .textSelection(.enabled)
            } else {
                Text("Binary response (\(response.bodyData.count) bytes)")
                    .font(Tokens.font(12))
                    .foregroundStyle(Tokens.inkGhost)
            }
        }
    }

    // MARK: History

    private var historyList: some View {
        VStack(alignment: .leading, spacing: 0) {
            if store.apiClient.history.isEmpty {
                Text("No requests yet.")
                    .font(Tokens.font(12.5))
                    .foregroundStyle(Tokens.inkGhost)
                    .padding(14)
            } else {
                ForEach(store.apiClient.history) { entry in
                    Button {
                        load(entry)
                        historyShown = false
                    } label: {
                        HStack(spacing: 8) {
                            Text(entry.method)
                                .font(Tokens.font(10.5, .semibold))
                                .foregroundStyle(Tokens.inkFaint)
                                .frame(width: 44, alignment: .leading)
                            Text(entry.url)
                                .font(Tokens.font(12))
                                .foregroundStyle(Tokens.ink)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .frame(width: 340)
        .background(Tokens.canvas)
    }

    private func load(_ entry: APIHistoryEntry) {
        draft.method = entry.method
        draft.urlText = entry.url
        draft.bodyText = entry.body
        draft.headerRows = entry.headers.map { HeaderRow(key: $0.key, value: $0.value) }
        if draft.headerRows.isEmpty { draft.headerRows = [HeaderRow()] }
        // A past request has no {name}-style template to diff future
        // operation clicks against.
        draft.loadedTemplate = nil
    }

    // MARK: Collections — imported from an OpenAPI/Swagger doc or Postman
    // Collection file, browsed by tag, one operation loaded at a time. Not a
    // permanent bulk dump into history — importing a large API's hundreds of
    // operations only ever populates this browsable list, never history.

    private var collectionsList: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if store.apiClient.collections.isEmpty {
                        Text("No collections imported yet.")
                            .font(Tokens.font(12.5))
                            .foregroundStyle(Tokens.inkGhost)
                            .padding(14)
                    }
                    ForEach(store.apiClient.collections) { collection in
                        collectionSection(collection)
                    }
                }
            }
            .frame(maxHeight: 360)

            Divider().overlay(Tokens.hairline)

            if let importErrorMessage {
                Text(importErrorMessage)
                    .font(Tokens.font(11.5))
                    .foregroundStyle(Tokens.danger)
                    .padding(.horizontal, 10)
                    .padding(.top, 8)
            }

            HStack(spacing: 10) {
                Button("Import File…") { importCollectionFromFile() }
                Button("Import URL…") { importCollectionShown = true }
            }
            .font(Tokens.font(12))
            .padding(10)
        }
        .frame(width: 360)
        .background(Tokens.canvas)
        .sheet(isPresented: $importCollectionShown) {
            importURLSheet
        }
    }

    private func collectionSection(_ collection: APICollection) -> some View {
        CollectionSectionView(
            collection: collection,
            onSelect: { operation in
                load(operation, in: collection)
                collectionsShown = false
            },
            onDelete: { store.apiClient.removeCollection(collection) }
        )
    }

    /// Clicking a different operation used to blindly overwrite the whole
    /// URL, which meant re-substituting shared path parameters (like
    /// `{locationId}`) from scratch on every single click within the same
    /// collection. Now it diffs whatever's currently in the URL field
    /// against the *previous* operation's raw template to recover what you
    /// actually typed for each `{name}` segment, then carries those values
    /// forward into the new template wherever the name matches.
    private func load(_ operation: APIOperation, in collection: APICollection) {
        var rememberedParameters: [String: String] = [:]
        if let previous = draft.loadedTemplate {
            rememberedParameters = Self.pathParameters(actual: draft.urlText, template: previous.path, baseURL: previous.baseURL)
        }
        let substitutedPath = Self.substitute(path: operation.path, using: rememberedParameters)

        draft.method = operation.method
        if let baseURL = collection.baseURL {
            draft.urlText = baseURL.hasSuffix("/") || substitutedPath.hasPrefix("/")
                ? baseURL + substitutedPath
                : baseURL + "/" + substitutedPath
        } else {
            draft.urlText = substitutedPath
        }
        draft.loadedTemplate = (collection.baseURL, operation.path)
        draft.bodyText = operation.body ?? ""
        draft.headerRows = operation.headers.map { HeaderRow(key: $0.key, value: $0.value) }

        // "Setup the headers ready for the user to put in the auth tokens":
        // the placeholder header/query param plus the seeded environment
        // that holds the actual (still-empty) token value.
        if let placeholder = collection.authPlaceholder {
            if placeholder.inQuery {
                let separator = draft.urlText.contains("?") ? "&" : "?"
                draft.urlText += "\(separator)\(placeholder.fieldName)=\(placeholder.placeholderValue)"
            } else {
                draft.headerRows.append(HeaderRow(key: placeholder.fieldName, value: placeholder.placeholderValue))
            }
            draft.selectedEnvironmentID = collection.environmentID
        }

        if draft.headerRows.isEmpty { draft.headerRows = [HeaderRow()] }
    }

    // MARK: Collection import

    private func importCollectionFromFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url, let data = try? Data(contentsOf: url) else { return }
        importCollection(from: data, name: url.deletingPathExtension().lastPathComponent, sourceURL: url)
    }

    private var importURLSheet: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Import from URL")
                .font(Tokens.font(13, .semibold))
            TextField("https://api.example.com/openapi.json", text: $importURLText)
                .textFieldStyle(.roundedBorder)
                .frame(width: 320)
            HStack {
                Spacer()
                Button("Cancel") { importCollectionShown = false }
                Button("Import") {
                    importCollectionShown = false
                    importCollectionFromURL(importURLText)
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
    }

    private func importCollectionFromURL(_ urlString: String) {
        guard let url = URL(string: urlString) else {
            importErrorMessage = "Not a valid URL."
            return
        }
        Task {
            do {
                let (data, response) = try await URLSession.shared.data(from: url)
                // Swagger UI's own conventional catch-all serves its HTML
                // shell for unmatched paths under its docs route (this bit
                // AirGradient's own real spec URL) — a non-JSON content
                // type here means we got that shell back, not the spec.
                if let http = response as? HTTPURLResponse,
                   let contentType = http.value(forHTTPHeaderField: "Content-Type"),
                   !contentType.contains("json") {
                    await MainActor.run { importErrorMessage = "That URL didn't return JSON — check it's the actual spec file, not the docs page." }
                    return
                }
                await MainActor.run {
                    importCollection(from: data, name: url.deletingPathExtension().lastPathComponent, sourceURL: url)
                }
            } catch {
                await MainActor.run { importErrorMessage = error.localizedDescription }
            }
        }
    }

    private func importCollection(from data: Data, name: String, sourceURL: URL? = nil) {
        guard let json = try? JSONSerialization.jsonObject(with: data),
              let collection = APISpecParser.detect(json, name: name, sourceURL: sourceURL) else {
            importErrorMessage = "That doesn't look like an OpenAPI, Swagger, or Postman Collection file."
            return
        }
        importErrorMessage = nil
        store.apiClient.importCollection(collection)
    }

    // MARK: Environments

    private var environmentsEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Environments")
                .font(Tokens.font(13, .semibold))
                .foregroundStyle(Tokens.ink)

            ForEach(store.apiClient.environments) { environment in
                EnvironmentRow(
                    environment: environment,
                    onChange: { store.apiClient.updateEnvironment($0) },
                    onDelete: { store.apiClient.removeEnvironment(environment) }
                )
            }

            Button {
                store.apiClient.addEnvironment(name: "New environment")
            } label: {
                Label("Add environment", systemImage: "plus")
                    .font(Tokens.font(11.5))
                    .foregroundStyle(Tokens.inkFaint)
            }
            .buttonStyle(.plain)
        }
        .padding(14)
        .frame(width: 360)
        .background(Tokens.canvas)
    }

    // MARK: Sending

    private func substitute(_ text: String) -> String {
        guard let environment = selectedEnvironment else { return text }
        var result = text
        for (key, value) in environment.variables {
            result = result.replacingOccurrences(of: "{{\(key)}}", with: value)
        }
        return result
    }

    /// Recovers `{name}` path-parameter values by positionally diffing the
    /// actual (possibly hand-edited) URL against the raw template it came
    /// from. Segment counts have to match, or this is a different-shaped
    /// path entirely and there's nothing sensible to recover.
    private static func pathParameters(actual urlText: String, template rawPath: String, baseURL: String?) -> [String: String] {
        let fullTemplate: String
        if let baseURL {
            fullTemplate = baseURL.hasSuffix("/") || rawPath.hasPrefix("/") ? baseURL + rawPath : baseURL + "/" + rawPath
        } else {
            fullTemplate = rawPath
        }
        let templatePath = fullTemplate.split(separator: "?", maxSplits: 1).first.map(String.init) ?? fullTemplate
        let actualPath = urlText.split(separator: "?", maxSplits: 1).first.map(String.init) ?? urlText
        let templateSegments = templatePath.split(separator: "/")
        let actualSegments = actualPath.split(separator: "/")
        guard templateSegments.count == actualSegments.count else { return [:] }

        var parameters: [String: String] = [:]
        for (templateSegment, actualSegment) in zip(templateSegments, actualSegments) {
            if templateSegment.hasPrefix("{"), templateSegment.hasSuffix("}") {
                parameters[String(templateSegment.dropFirst().dropLast())] = String(actualSegment)
            }
        }
        return parameters
    }

    private static func substitute(path: String, using parameters: [String: String]) -> String {
        guard !parameters.isEmpty else { return path }
        var result = path
        for (name, value) in parameters {
            result = result.replacingOccurrences(of: "{\(name)}", with: value)
        }
        return result
    }

    private func send() {
        guard let url = URL(string: substitute(draft.urlText)) else {
            draft.errorMessage = "Not a valid URL."
            return
        }
        draft.errorMessage = nil
        draft.response = nil
        draft.isSending = true

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = draft.method
        let resolvedHeaders = draft.headerRows.filter { !$0.key.isEmpty }
        for row in resolvedHeaders {
            urlRequest.setValue(substitute(row.value), forHTTPHeaderField: substitute(row.key))
        }
        let resolvedBody = substitute(draft.bodyText)
        if !draft.bodyText.isEmpty, draft.method != "GET", draft.method != "HEAD" {
            urlRequest.httpBody = resolvedBody.data(using: .utf8)
        }

        let historyHeaders = Dictionary(uniqueKeysWithValues: resolvedHeaders.map { ($0.key, $0.value) })
        let sentMethod = draft.method
        let sentURL = draft.urlText
        let sentBody = draft.bodyText
        let apiClient = store.apiClient!
        let draft = draft

        Task {
            let started = Date()
            do {
                let (data, urlResponse) = try await URLSession.shared.data(for: urlRequest)
                let duration = Date().timeIntervalSince(started)
                let http = urlResponse as? HTTPURLResponse
                var responseHeaders: [String: String] = [:]
                for (key, value) in http?.allHeaderFields ?? [:] {
                    if let key = key as? String, let value = value as? String {
                        responseHeaders[key] = value
                    }
                }
                let parsed = try? JSONSerialization.jsonObject(with: data)
                await MainActor.run {
                    draft.response = APIResponse(status: http?.statusCode ?? 0, duration: duration, headers: responseHeaders, bodyData: data, parsedJSON: parsed)
                    draft.isSending = false
                }
                apiClient.recordHistory(method: sentMethod, url: sentURL, headers: historyHeaders, body: sentBody)
            } catch {
                await MainActor.run {
                    draft.errorMessage = error.localizedDescription
                    draft.isSending = false
                }
            }
        }
    }
}

private struct EnvironmentRow: View {
    let environment: APIEnvironment
    let onChange: (APIEnvironment) -> Void
    let onDelete: () -> Void

    @State private var name: String
    @State private var rows: [HeaderRow]

    init(environment: APIEnvironment, onChange: @escaping (APIEnvironment) -> Void, onDelete: @escaping () -> Void) {
        self.environment = environment
        self.onChange = onChange
        self.onDelete = onDelete
        _name = State(initialValue: environment.name)
        let variableRows = environment.variables.map { HeaderRow(key: $0.key, value: $0.value) }
        _rows = State(initialValue: variableRows.isEmpty ? [HeaderRow()] : variableRows)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                TextField("Name", text: $name)
                    .textFieldStyle(.plain)
                    .font(Tokens.font(12.5, .medium))
                    .onChange(of: name) { commit() }
                Spacer()
                Button {
                    onDelete()
                } label: {
                    Image(systemName: "trash")
                        .foregroundStyle(Tokens.inkGhost)
                }
                .buttonStyle(.plain)
            }
            ForEach($rows) { $row in
                HStack(spacing: 6) {
                    TextField("Key", text: $row.key)
                        .textFieldStyle(.plain)
                        .font(Tokens.font(11.5))
                        .padding(5)
                        .background(RoundedRectangle(cornerRadius: 5).fill(Tokens.well))
                        .onChange(of: row.key) { commit() }
                    TextField("Value", text: $row.value)
                        .textFieldStyle(.plain)
                        .font(Tokens.font(11.5))
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
        .padding(8)
        .background(RoundedRectangle(cornerRadius: Tokens.radiusControl).fill(Tokens.well.opacity(0.5)))
    }

    private func commit() {
        let variables = Dictionary(uniqueKeysWithValues: rows.filter { !$0.key.isEmpty }.map { ($0.key, $0.value) })
        onChange(APIEnvironment(id: environment.id, name: name, variables: variables))
    }
}

/// A reliable stand-in for `DisclosureGroup` — on macOS, `DisclosureGroup`
/// only toggles when its small triangle indicator is clicked precisely, not
/// the label text beside it, which reads as "clicking this does nothing."
/// This makes the whole row a real `Button`.
private struct SectionDisclosure<Content: View>: View {
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

/// One imported collection's browsable operation list, grouped by tag.
/// Defaults to expanded — a freshly-imported collection should show its
/// contents immediately, not require an extra click to discover they're there.
private struct CollectionSectionView: View {
    let collection: APICollection
    let onSelect: (APIOperation) -> Void
    let onDelete: () -> Void

    @State private var expanded = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Button {
                    expanded.toggle()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: expanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(Tokens.inkGhost)
                            .frame(width: 10)
                        Text(collection.name)
                            .font(Tokens.font(12.5, .medium))
                            .foregroundStyle(Tokens.ink)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Spacer(minLength: 0)

                Button(action: onDelete) {
                    Image(systemName: "trash")
                        .foregroundStyle(Tokens.inkGhost)
                }
                .buttonStyle(.plain)
            }

            if expanded {
                let grouped = Dictionary(grouping: collection.operations, by: \.tag)
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(grouped.keys.sorted(), id: \.self) { tag in
                        ForEach(grouped[tag] ?? []) { operation in
                            Button {
                                onSelect(operation)
                            } label: {
                                HStack(spacing: 8) {
                                    Text(operation.method)
                                        .font(Tokens.font(10, .semibold))
                                        .foregroundStyle(Tokens.inkFaint)
                                        .frame(width: 42, alignment: .leading)
                                    Text(operation.summary?.isEmpty == false ? operation.summary! : operation.path)
                                        .font(Tokens.font(12))
                                        .foregroundStyle(Tokens.ink)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(.top, 4)
                .padding(.leading, 16)
            }
        }
        .padding(.horizontal, 10)
        .padding(.top, 8)
    }
}
