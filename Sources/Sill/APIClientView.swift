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
///
/// This outer view owns the sidebar (Environments/Collections, shared across
/// every request tab) and the request-tab strip; the actual method/URL/
/// headers/body/response editor for whichever request tab is selected lives
/// in the child `APIRequestEditorView`, reconstructed fresh (`.id(...)`)
/// every time the selection changes — same reasoning `APIClientDraftState`'s
/// own doc comment gives for why draft state lives outside the view at all.
struct APIClientView: View {
    @Bindable var store: TabStore
    let tab: BrowserTab
    /// Fetched once, in `init`, from `APIClientStore`'s per-tab cache — the
    /// same underlying object comes back every time this view is
    /// (re)constructed for the same browser tab.
    private let requestTabs: APIRequestTabsState

    @State private var historyShown = false
    @State private var importErrorMessage: String?
    @State private var importCollectionShown = false
    @State private var importURLText = ""

    private static let sidebarWidth: CGFloat = 240

    init(store: TabStore, tab: BrowserTab) {
        self._store = Bindable(store)
        self.tab = tab
        self.requestTabs = store.apiClient.requestTabsState(for: tab.id)
    }

    private var currentRequestTabID: UUID {
        requestTabs.selectedID ?? tab.id
    }

    /// Whichever request tab is currently selected — plain (not `@Bindable`)
    /// since the outer view only ever needs one-shot reads/writes here
    /// (sidebar selection, loading a history entry or collection operation
    /// into it), never a `Binding` handed to a text field. The actual
    /// `@Bindable` live editor lives in `APIRequestEditorView`.
    private var currentDraft: APIClientDraftState {
        store.apiClient.draftState(for: currentRequestTabID)
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider().overlay(Tokens.hairline)

            VStack(spacing: 0) {
                requestTabStrip
                Divider().overlay(Tokens.hairline)
                APIRequestEditorView(store: store, requestTabID: currentRequestTabID)
                    .id(currentRequestTabID)
            }
        }
        .background(Tokens.canvas)
    }

    // MARK: Sidebar — Environments and Collections live here permanently
    // (owner's ask: "sit more in the interface", browsable rather than
    // buried behind a toolbar popover). History stays a popover since
    // there's nothing to browse — it's a flat recency list.

    private var sidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                environmentsSidebarSection
                Divider().overlay(Tokens.hairline).padding(.vertical, 10)
                collectionsSidebarSection
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 14)
        }
        .frame(width: Self.sidebarWidth)
        .background(Tokens.well.opacity(0.4))
        .sheet(isPresented: $importCollectionShown) {
            importURLSheet
        }
    }

    private static func sidebarHeader(_ title: String) -> some View {
        Text(title)
            .font(Tokens.font(10, .medium))
            .kerning(0.8)
            .foregroundStyle(Tokens.inkGhost)
    }

    // MARK: Request tab strip — Postman-style tabs across the top so testing
    // several endpoints doesn't mean overwriting the same draft over and
    // over. The old per-tab "environment name" label used to sit here too,
    // but the sidebar's own selected-environment radio dot already says the
    // same thing more clearly, so it's gone rather than duplicated.

    private var requestTabStrip: some View {
        HStack(spacing: 4) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(requestTabs.tabs) { requestTab in
                        RequestTabPill(
                            title: requestTab.title,
                            isSelected: requestTabs.selectedID == requestTab.id,
                            onSelect: { store.apiClient.selectRequestTab(requestTab.id, for: tab.id) },
                            onRename: { store.apiClient.renameRequestTab(requestTab.id, title: $0, for: tab.id) },
                            onClose: requestTabs.tabs.count > 1 ? { store.apiClient.closeRequestTab(requestTab.id, for: tab.id) } : nil
                        )
                    }
                    Button {
                        store.apiClient.addRequestTab(for: tab.id)
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Tokens.inkGhost)
                            .padding(6)
                    }
                    .buttonStyle(.plain)
                    .help("New request tab")
                }
            }

            Spacer(minLength: 8)

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
        let draft = currentDraft
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
    // Collection file, browsed by URL structure (segment by segment, like the
    // path itself) rather than a flat list, one operation loaded at a time.
    // Not a permanent bulk dump into history — importing a large API's
    // hundreds of operations only ever populates this browsable tree, never
    // history. Lives permanently in the sidebar now rather than behind a
    // toolbar popover, so browsing a large API's shape is a scroll, not a
    // click-to-reveal.

    private var collectionsSidebarSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Self.sidebarHeader("COLLECTIONS")
                Spacer()
                Menu {
                    Button("Import File…") { importCollectionFromFile() }
                    Button("Import URL…") { importCollectionShown = true }
                } label: {
                    Image(systemName: "plus.circle")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Tokens.inkGhost)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }

            if let importErrorMessage {
                Text(importErrorMessage)
                    .font(Tokens.font(11))
                    .foregroundStyle(Tokens.danger)
            }

            if store.apiClient.collections.isEmpty {
                Text("No collections imported yet.")
                    .font(Tokens.font(11.5))
                    .foregroundStyle(Tokens.inkGhost)
            }

            ForEach(store.apiClient.collections) { collection in
                collectionSection(collection)
            }
        }
    }

    private func collectionSection(_ collection: APICollection) -> some View {
        CollectionSectionView(
            collection: collection,
            onSelect: { operation in load(operation, in: collection) },
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
        let draft = currentDraft
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

    private var environmentsSidebarSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Self.sidebarHeader("ENVIRONMENT")
                Spacer()
                Button {
                    let environment = store.apiClient.addEnvironment(name: "New environment")
                    currentDraft.selectedEnvironmentID = environment.id
                } label: {
                    Image(systemName: "plus.circle")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Tokens.inkGhost)
                }
                .buttonStyle(.plain)
            }

            Button {
                currentDraft.selectedEnvironmentID = nil
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: currentDraft.selectedEnvironmentID == nil ? "largecircle.fill.circle" : "circle")
                        .font(.system(size: 10))
                        .foregroundStyle(currentDraft.selectedEnvironmentID == nil ? Tokens.accent : Tokens.inkGhost)
                    Text("No environment")
                        .font(Tokens.font(12))
                        .foregroundStyle(Tokens.ink)
                }
            }
            .buttonStyle(.plain)

            ForEach(store.apiClient.environments) { environment in
                EnvironmentRow(
                    environment: environment,
                    isSelected: currentDraft.selectedEnvironmentID == environment.id,
                    onSelect: { currentDraft.selectedEnvironmentID = environment.id },
                    onChange: { store.apiClient.updateEnvironment($0) },
                    onDelete: {
                        if currentDraft.selectedEnvironmentID == environment.id { currentDraft.selectedEnvironmentID = nil }
                        store.apiClient.removeEnvironment(environment)
                    }
                )
            }
        }
    }
}

/// One clickable pill in the request-tab strip — click to select, double-click
/// the title to rename in place, `×` to close (hidden entirely when this is
/// the last request tab, since the strip can never go empty).
private struct RequestTabPill: View {
    let title: String
    let isSelected: Bool
    let onSelect: () -> Void
    let onRename: (String) -> Void
    let onClose: (() -> Void)?

    @State private var isRenaming = false
    @State private var draftTitle = ""
    @FocusState private var renameFocused: Bool

    var body: some View {
        HStack(spacing: 5) {
            if isRenaming {
                TextField("", text: $draftTitle)
                    .textFieldStyle(.plain)
                    .font(Tokens.font(11.5, .medium))
                    .focused($renameFocused)
                    .frame(minWidth: 60)
                    .onSubmit(commit)
                    .onChange(of: renameFocused) { if !renameFocused { commit() } }
                    .onAppear { renameFocused = true }
            } else {
                Text(title)
                    .font(Tokens.font(11.5, isSelected ? .medium : .regular))
                    .foregroundStyle(isSelected ? Tokens.ink : Tokens.inkFaint)
                    .lineLimit(1)
                    .onTapGesture(count: 2, perform: startRenaming)
                    .onTapGesture(count: 1, perform: onSelect)
            }

            if let onClose {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(Tokens.inkGhost)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 6).fill(isSelected ? Tokens.canvas : Color.clear))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(isSelected ? Tokens.hairline : .clear, lineWidth: 1))
    }

    private func startRenaming() {
        draftTitle = title
        isRenaming = true
    }

    private func commit() {
        let trimmed = draftTitle.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty { onRename(trimmed) }
        isRenaming = false
    }
}

/// The live editor for one request tab: method/URL/headers/body, the
/// resolved-request readout, and the response viewer. Split out of
/// `APIClientView` so switching between request tabs — each with its own
/// independent `APIClientDraftState` — is exactly like switching between
/// ordinary browser tabs: the outer view forces a fresh instance of this one
/// (`.id(requestTabID)`) rather than trying to mutate one shared set of
/// `@State` in place.
private struct APIRequestEditorView: View {
    @Bindable var store: TabStore
    let requestTabID: UUID
    @Bindable private var draft: APIClientDraftState

    // Plain @State bools, not DisclosureGroup's own isExpanded — on macOS,
    // DisclosureGroup only toggles when its tiny triangle is clicked
    // precisely, not the label text next to it, which reads as "nothing
    // happens when I click this." SectionDisclosure below makes the whole
    // row a real Button instead.
    @State private var headersExpanded = true
    @State private var bodyExpanded = true
    @State private var responseHeadersExpanded = false
    @State private var requestHeadersExpanded = true
    @State private var requestBodyExpanded = false

    private static let methods = ["GET", "POST", "PUT", "PATCH", "DELETE", "HEAD", "OPTIONS"]

    init(store: TabStore, requestTabID: UUID) {
        self._store = Bindable(store)
        self.requestTabID = requestTabID
        self._draft = Bindable(store.apiClient.draftState(for: requestTabID))
    }

    var body: some View {
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

                if let lastRequest = draft.lastRequest {
                    Divider().overlay(Tokens.hairline)
                    requestView(lastRequest)
                }

                if let response = draft.response {
                    Divider().overlay(Tokens.hairline)
                    responseView(response)
                }
            }
            .padding(16)
        }
        // Debounced persistence — a WIP request (method/URL/headers/body,
        // whichever environment was active) survives quit/relaunch, same as
        // named Environments and imported Collections already did. Nothing
        // to save the first time a blank tab's fields haven't been touched.
        .onChange(of: draft.method) { schedulePersist() }
        .onChange(of: draft.urlText) { schedulePersist() }
        .onChange(of: draft.headerRows) { schedulePersist() }
        .onChange(of: draft.bodyText) { schedulePersist() }
        .onChange(of: draft.selectedEnvironmentID) { schedulePersist() }
    }

    private func schedulePersist() {
        store.apiClient.scheduleDraftPersist(tabID: requestTabID, draft: draft)
    }

    private var selectedEnvironment: APIEnvironment? {
        store.apiClient.environments.first { $0.id == draft.selectedEnvironmentID }
    }

    /// Drives the inline `{variable}` colour coding — red/green/accent per
    /// `APIVariableTokenKind` — against whichever environment is currently
    /// active, so a typo like `{root_url}` when the environment actually
    /// holds `root_uri` reads as wrong before you ever hit Send.
    private func classify(_ name: String) -> APIVariableTokenKind {
        if APIVariableResolver.builtinNames.contains(name) { return .builtin }
        if selectedEnvironment?.variables[name] != nil { return .known }
        return .unknown
    }

    // MARK: Request

    private var requestLine: some View {
        HStack(spacing: 8) {
            Picker("", selection: $draft.method) {
                ForEach(Self.methods, id: \.self) { Text($0) }
            }
            .labelsHidden()
            .frame(width: 100)

            HighlightingTextField(placeholder: "https://api.example.com/…", text: $draft.urlText, fontSize: 12.5, classify: classify, onSubmit: send)
                .padding(.horizontal, 9)
                .padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: Tokens.radiusControl).fill(Tokens.well))

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
                        SuggestingTextField(placeholder: "Key", text: $row.key, suggestions: APIHeaderSuggestions.names, classify: classify)
                            .padding(6)
                            .background(RoundedRectangle(cornerRadius: 5).fill(Tokens.well))
                        SuggestingTextField(placeholder: "Value", text: $row.value, suggestions: APIHeaderSuggestions.values(for: row.key), classify: classify)
                            .padding(6)
                            .background(RoundedRectangle(cornerRadius: 5).fill(Tokens.well))
                        Button {
                            // `row.id` must be read into a plain value
                            // *before* the mutating call below — reading it
                            // through the `$row` binding from inside
                            // `removeAll`'s closure would re-enter
                            // `draft.headerRows` while it's already under
                            // exclusive write access, which is a runtime
                            // trap (Debug builds enforce this; Release
                            // builds silently tolerate the same bug).
                            let id = row.id
                            draft.headerRows.removeAll { $0.id == id }
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
            HighlightingTextEditor(text: $draft.bodyText, fontSize: 12, classify: classify)
                .frame(minHeight: 100, maxHeight: 220)
                .padding(6)
                .background(RoundedRectangle(cornerRadius: Tokens.radiusControl).fill(Tokens.well))
        }
    }

    // MARK: Request — what was actually sent, every {variable} and computed
    // expression already resolved to its real value, so a signature/token
    // substitution can be checked by eye against the still-template-shaped
    // editor above rather than guessed at.

    @ViewBuilder
    private func requestView(_ request: APIResolvedRequest) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("Request")
                    .font(Tokens.font(13, .semibold))
                    .foregroundStyle(Tokens.ink)
                Text(request.method)
                    .font(Tokens.font(10.5, .semibold))
                    .foregroundStyle(Tokens.inkFaint)
            }
            Text(request.url)
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundStyle(Tokens.ink)
                .textSelection(.enabled)

            if !request.headers.isEmpty {
                SectionDisclosure(title: "Request headers", expanded: $requestHeadersExpanded) {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(request.headers, id: \.key) { header in
                            HStack(alignment: .top, spacing: 4) {
                                Text("\(header.key):").foregroundStyle(Tokens.inkFaint)
                                Text(header.value).foregroundStyle(Tokens.ink)
                            }
                            .font(.system(size: 11, design: .monospaced))
                            .textSelection(.enabled)
                        }
                    }
                }
            }

            if !request.body.isEmpty {
                SectionDisclosure(title: "Request body", expanded: $requestBodyExpanded) {
                    Text(request.body)
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(Tokens.ink)
                        .textSelection(.enabled)
                }
            }
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

    // MARK: Sending

    private func substitute(_ text: String, extra: [String: String] = [:]) -> String {
        APIVariableResolver.substitute(text, environment: selectedEnvironment, extra: extra)
    }

    private func send() {
        // One frozen instant for the whole request: {$timestamp}/{$guid}/etc.
        // referenced in both a `timestamp` header AND a `signature` header
        // (exactly the FoxESS-style recipe this tool exists for) must
        // resolve to the *same* value in both places, or the signature the
        // server recomputes will never match what was actually sent.
        let dynamics = APIVariableResolver.frozenDynamicValues()

        // Resolved in two passes: first the URL alone (plain/computed
        // variables only), so {$path} — the path+query FoxESS-style
        // signature recipes reference — has something real to extract from
        // before the second pass resolves URL, headers, and body together.
        let (resolvedPath, resolvedQuery) = APIVariableResolver.resolvedPathAndQuery(fromSubstitutedURL: draft.urlText, environment: selectedEnvironment, extra: dynamics)
        let extra = dynamics.merging(["$path": resolvedPath, "$query": resolvedQuery]) { _, new in new }
        let resolvedURLText = substitute(draft.urlText, extra: extra)
        guard let url = URL(string: resolvedURLText) else {
            draft.errorMessage = "Not a valid URL."
            return
        }
        draft.errorMessage = nil
        draft.response = nil
        draft.isSending = true

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = draft.method
        let rawHeaderRows = draft.headerRows.filter { !$0.key.isEmpty }
        var sentHeaderPairs: [(key: String, value: String)] = []
        for row in rawHeaderRows {
            let key = substitute(row.key, extra: extra)
            let value = substitute(row.value, extra: extra)
            urlRequest.setValue(value, forHTTPHeaderField: key)
            sentHeaderPairs.append((key, value))
        }
        let resolvedBody = substitute(draft.bodyText, extra: extra)
        if !draft.bodyText.isEmpty, draft.method != "GET", draft.method != "HEAD" {
            urlRequest.httpBody = resolvedBody.data(using: .utf8)
        }

        // Captured before the network call even starts (not just on
        // success) — "what did we actually send" is exactly as useful to
        // see when the request fails or times out.
        draft.lastRequest = APIResolvedRequest(method: draft.method, url: resolvedURLText, headers: sentHeaderPairs, body: resolvedBody)

        let historyHeaders = Dictionary(uniqueKeysWithValues: rawHeaderRows.map { ($0.key, $0.value) })
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
    let isSelected: Bool
    let onSelect: () -> Void
    let onChange: (APIEnvironment) -> Void
    let onDelete: () -> Void

    @State private var name: String
    @State private var rows: [HeaderRow]
    @State private var expanded: Bool

    init(environment: APIEnvironment, isSelected: Bool, onSelect: @escaping () -> Void, onChange: @escaping (APIEnvironment) -> Void, onDelete: @escaping () -> Void) {
        self.environment = environment
        self.isSelected = isSelected
        self.onSelect = onSelect
        self.onChange = onChange
        self.onDelete = onDelete
        _name = State(initialValue: environment.name)
        let variableRows = environment.variables.map { HeaderRow(key: $0.key, value: $0.value) }
        _rows = State(initialValue: variableRows.isEmpty ? [HeaderRow()] : variableRows)
        // The active environment's variables are worth seeing at a glance;
        // others start collapsed so a long environment list doesn't turn the
        // sidebar into a wall of key/value rows.
        _expanded = State(initialValue: isSelected)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
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

                Button(action: onSelect) {
                    HStack(spacing: 6) {
                        Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                            .font(.system(size: 10))
                            .foregroundStyle(isSelected ? Tokens.accent : Tokens.inkGhost)
                        TextField("Name", text: $name)
                            .textFieldStyle(.plain)
                            .font(Tokens.font(12, .medium))
                            .onChange(of: name) { commit() }
                    }
                }
                .buttonStyle(.plain)

                Spacer()
                Button {
                    onDelete()
                } label: {
                    Image(systemName: "trash")
                        .foregroundStyle(Tokens.inkGhost)
                }
                .buttonStyle(.plain)
            }

            if expanded {
                VStack(alignment: .leading, spacing: 4) {
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
                .padding(.leading, 16)
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: Tokens.radiusControl).fill(isSelected ? Tokens.accentWash : Tokens.well.opacity(0.5)))
    }

    private func commit() {
        let variables = Dictionary(uniqueKeysWithValues: rows.filter { !$0.key.isEmpty }.map { ($0.key, $0.value) })
        onChange(APIEnvironment(id: environment.id, name: name, variables: variables))
    }
}

/// The header names and values seen often enough to be worth suggesting
/// rather than retyping — Postman's own "usual suspects" list, not an
/// exhaustive registry of every HTTP header that exists.
enum APIHeaderSuggestions {
    static let names = [
        "Content-Type", "Authorization", "Accept", "Accept-Language",
        "Accept-Encoding", "Cache-Control", "User-Agent", "X-Requested-With",
        "X-API-Key", "Cookie", "Origin", "Referer",
    ]

    /// Keyed by header *name* — `Authorization`'s usual values (bearer/basic
    /// schemes) have nothing to do with `Content-Type`'s (MIME types), so
    /// suggestions for the value field only make sense once the key is
    /// known.
    static func values(for headerName: String) -> [String] {
        switch headerName.trimmingCharacters(in: .whitespaces).lowercased() {
        case "content-type", "accept":
            return [
                "application/json", "application/xml", "application/x-www-form-urlencoded",
                "multipart/form-data", "text/plain", "text/html", "*/*",
            ]
        case "authorization":
            return ["Bearer ", "Basic "]
        case "accept-language":
            return ["en-US", "en", "en-US,en;q=0.9"]
        case "accept-encoding":
            return ["gzip, deflate, br", "identity"]
        case "cache-control":
            return ["no-cache", "no-store", "max-age=0"]
        case "x-requested-with":
            return ["XMLHttpRequest"]
        default:
            return []
        }
    }
}

/// A plain `TextField` that offers a click-to-fill dropdown of common values
/// (header names like `Content-Type`, or values scoped to whichever header
/// name is currently in the sibling key field) — narrows as you type,
/// shows the full list on focus when the field is still empty so the
/// "usual values" are browsable, not just completable.
private struct SuggestingTextField: View {
    let placeholder: String
    @Binding var text: String
    let suggestions: [String]
    var classify: (String) -> APIVariableTokenKind = { _ in .unknown }

    @State private var focused = false

    private var filtered: [String] {
        guard !suggestions.isEmpty else { return [] }
        guard !text.isEmpty else { return suggestions }
        return suggestions.filter {
            $0.localizedCaseInsensitiveContains(text) && $0.caseInsensitiveCompare(text) != .orderedSame
        }
    }

    var body: some View {
        HighlightingTextField(placeholder: placeholder, text: $text, fontSize: 12, classify: classify, onFocusChange: { focused = $0 })
            .popover(isPresented: Binding(
                get: { focused && !filtered.isEmpty },
                set: { if !$0 { focused = false } }
            ), arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(filtered.prefix(8), id: \.self) { suggestion in
                        Button {
                            text = suggestion
                            focused = false
                        } label: {
                            Text(suggestion)
                                .font(Tokens.font(11.5))
                                .foregroundStyle(Tokens.ink)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 4)
                .frame(minWidth: 180)
                .background(Tokens.canvas)
            }
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
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Self.pathTree(collection.operations)) { node in
                        PathTreeRow(node: node, onSelect: onSelect)
                    }
                }
                .padding(.top, 4)
                .padding(.leading, 10)
            }
        }
        .padding(.horizontal, 10)
        .padding(.top, 8)
    }

    /// Groups operations by URL path segment ("browse through the URL
    /// structure", the owner's own words) rather than the spec's declared
    /// tag — a folder per path segment, drillable, closer to how Postman's
    /// own collection tree reads than a flat tag-grouped list.
    private static func pathTree(_ operations: [APIOperation]) -> [PathTreeNode] {
        var roots: [PathTreeNode] = []
        let ordered = operations.sorted { $0.path != $1.path ? $0.path < $1.path : $0.method < $1.method }
        for operation in ordered {
            insert(operation, segments: segments(of: operation.path), into: &roots)
        }
        return roots
    }

    /// Postman operations carry a full URL (scheme, host, and all); OpenAPI
    /// ones carry a bare relative path. Either way, only the part after the
    /// host is worth browsing as a tree — the host is shared by every
    /// operation in the collection and would just repeat as a redundant top
    /// level.
    private static func segments(of path: String) -> [String] {
        var relevant = path
        if let schemeRange = path.range(of: "://") {
            let afterScheme = path[schemeRange.upperBound...]
            relevant = afterScheme.firstIndex(of: "/").map { String(afterScheme[$0...]) } ?? "/"
        }
        relevant = relevant.split(separator: "?", maxSplits: 1).first.map(String.init) ?? relevant
        return relevant.split(separator: "/").map(String.init)
    }

    private static func insert(_ operation: APIOperation, segments: [String], into nodes: inout [PathTreeNode]) {
        guard let first = segments.first else { return }
        let rest = Array(segments.dropFirst())
        if let index = nodes.firstIndex(where: { $0.name == first }) {
            if rest.isEmpty {
                nodes[index].operations.append(operation)
            } else {
                insert(operation, segments: rest, into: &nodes[index].children)
            }
        } else {
            var node = PathTreeNode(name: first)
            if rest.isEmpty {
                node.operations.append(operation)
            } else {
                insert(operation, segments: rest, into: &node.children)
            }
            nodes.append(node)
        }
    }
}

/// One URL path segment in a collection's browsable tree — may carry
/// operations that terminate exactly here (`node.operations`), deeper
/// children, or both (e.g. `GET /devices` alongside `GET /devices/{id}`).
private struct PathTreeNode: Identifiable {
    let id = UUID()
    let name: String
    var children: [PathTreeNode] = []
    var operations: [APIOperation] = []
}

private struct PathTreeRow: View {
    let node: PathTreeNode
    let onSelect: (APIOperation) -> Void

    @State private var expanded = false

    /// A single operation with no deeper path beneath it collapses straight
    /// into one clickable row — no pointless disclosure step to open a
    /// folder that only ever contained the one thing.
    private var singleLeafOperation: APIOperation? {
        node.children.isEmpty && node.operations.count == 1 ? node.operations.first : nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                if let operation = singleLeafOperation {
                    onSelect(operation)
                } else {
                    expanded.toggle()
                }
            } label: {
                HStack(spacing: 6) {
                    if let operation = singleLeafOperation {
                        Text(operation.method)
                            .font(Tokens.font(9.5, .semibold))
                            .foregroundStyle(Tokens.inkFaint)
                            .frame(width: 38, alignment: .leading)
                    } else {
                        Image(systemName: expanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(Tokens.inkGhost)
                            .frame(width: 10)
                    }
                    Text(node.name)
                        .font(Tokens.font(12))
                        .foregroundStyle(Tokens.ink)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 3)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded, singleLeafOperation == nil {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(node.operations) { operation in
                        Button {
                            onSelect(operation)
                        } label: {
                            HStack(spacing: 8) {
                                Text(operation.method)
                                    .font(Tokens.font(9.5, .semibold))
                                    .foregroundStyle(Tokens.inkFaint)
                                    .frame(width: 38, alignment: .leading)
                                Text(operation.summary?.isEmpty == false ? operation.summary! : "(this path)")
                                    .font(Tokens.font(12))
                                    .foregroundStyle(Tokens.ink)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            .padding(.vertical, 3)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    ForEach(node.children) { child in
                        PathTreeRow(node: child, onSelect: onSelect)
                    }
                }
                .padding(.leading, 14)
            }
        }
    }
}
