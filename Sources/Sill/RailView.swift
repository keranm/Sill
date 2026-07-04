import SwiftUI

extension Notification.Name {
    static let focusRailField = Notification.Name("sill.focusRailField")
    static let newWorkspace = Notification.Name("sill.newWorkspace")
}

/// The left rail, per D2a v2: workspace switcher → "Search or go to…" →
/// (Applications, only once any are confirmed — M5) → vertical tabs →
/// dormant workspaces and Downloads at the foot, as faint facts.
struct RailView: View {
    @Bindable var store: TabStore

    @State private var fieldText = ""
    @State private var switcherShown = false
    @State private var namingNew = false
    @State private var downloadsShown = false
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            workspaceHeader
                .padding(.horizontal, 10)
                .padding(.top, 8)

            goToField
                .padding(.horizontal, 10)
                .padding(.top, 10)

            Text("TABS")
                .font(Tokens.font(10, .medium))
                .kerning(0.8)
                .foregroundStyle(Tokens.inkGhost)
                .padding(.horizontal, 14)
                .padding(.top, 18)
                .padding(.bottom, 6)

            tabList

            Spacer(minLength: 0)

            foot
                .padding(.horizontal, 10)
                .padding(.bottom, 10)
        }
        .frame(width: Tokens.railWidth)
        .background(Tokens.canvas)
        .onReceive(NotificationCenter.default.publisher(for: .focusRailField)) { _ in
            fieldFocused = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .newWorkspace)) { _ in
            namingNew = true
            switcherShown = true
        }
    }

    // MARK: Workspace switcher (D2a: one action to change context)

    private var workspaceHeader: some View {
        Button {
            switcherShown.toggle()
        } label: {
            HStack(spacing: 7) {
                Circle()
                    .fill(Tokens.accent)
                    .frame(width: 6, height: 6)
                Text(store.railTitle)
                    .font(Tokens.font(13, .semibold))
                    .foregroundStyle(Tokens.ink)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(Tokens.inkGhost)
                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .popover(isPresented: $switcherShown, arrowEdge: .bottom) {
            WorkspaceSwitcher(store: store, isPresented: $switcherShown, namingNew: $namingNew)
        }
    }

    // MARK: Go-to field

    private var goToField: some View {
        HStack(spacing: 6) {
            TextField("Search or go to…", text: $fieldText)
                .textFieldStyle(.plain)
                .font(Tokens.font(12.5))
                .foregroundStyle(Tokens.ink)
                .focused($fieldFocused)
                .onSubmit {
                    store.openInNewTab(fieldText)
                    fieldText = ""
                    fieldFocused = false
                }
            if !fieldFocused {
                Text("⌘T")
                    .font(Tokens.font(10.5))
                    .foregroundStyle(Tokens.inkGhost)
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: Tokens.radiusControl)
                .fill(Tokens.well)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Tokens.radiusControl)
                .strokeBorder(fieldFocused ? Tokens.accent : .clear, lineWidth: 1.5)
        )
    }

    // MARK: Tabs

    private var tabList: some View {
        List {
            ForEach(store.tabs) { tab in
                TabRow(
                    tab: tab,
                    isSelected: tab.id == store.selectedTabID,
                    select: { store.selectedTabID = tab.id },
                    close: { store.closeTab(tab) }
                )
                .listRowInsets(EdgeInsets(top: 1, leading: 6, bottom: 1, trailing: 6))
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
            }
            .onMove { source, destination in
                store.moveTabs(from: source, to: destination)
            }

            Button {
                store.newTab()
                fieldFocused = true
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "plus")
                        .font(.system(size: 9, weight: .medium))
                    Text("New tab")
                        .font(Tokens.font(12.5))
                    Spacer()
                }
                .foregroundStyle(Tokens.inkGhost)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .listRowInsets(EdgeInsets(top: 1, leading: 6, bottom: 1, trailing: 6))
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .environment(\.defaultMinListRowHeight, 24)
    }

    // MARK: Foot — dormant workspaces are faint facts, never badged

    private var foot: some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(store.dormantWorkspaces) { workspace in
                Button {
                    Task { await store.switchWorkspace(to: workspace.id) }
                } label: {
                    HStack(spacing: 7) {
                        Circle()
                            .fill(Tokens.inkGhost.opacity(0.5))
                            .frame(width: 5, height: 5)
                        Text(workspace.name)
                            .font(Tokens.font(12))
                            .lineLimit(1)
                        Spacer()
                        Text("\(workspace.tabs.count) tabs")
                            .font(Tokens.font(11))
                            .foregroundStyle(Tokens.inkGhost)
                    }
                    .foregroundStyle(Tokens.inkFaint)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            Button {
                downloadsShown.toggle()
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "arrow.down")
                        .font(.system(size: 9, weight: .medium))
                    Text("Downloads")
                        .font(Tokens.font(12))
                    Spacer()
                    if !store.downloads.items.isEmpty {
                        Text("\(store.downloads.items.count)")
                            .font(Tokens.font(11))
                    }
                }
                .foregroundStyle(Tokens.inkFaint)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .popover(isPresented: $downloadsShown, arrowEdge: .top) {
                DownloadsListView(downloads: store.downloads)
            }
        }
    }
}

// MARK: - Workspace switcher popover

private struct WorkspaceSwitcher: View {
    @Bindable var store: TabStore
    @Binding var isPresented: Bool
    @Binding var namingNew: Bool

    @State private var newName = ""
    @State private var renamingID: Workspace.ID?
    @State private var renameText = ""
    @FocusState private var nameFieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(store.workspaces.filter { store.hasUserWorkspaces || $0.id == store.activeWorkspaceID }) { workspace in
                workspaceRow(workspace)
            }

            Divider()
                .overlay(Tokens.hairline)
                .padding(.vertical, 3)

            if namingNew {
                TextField("Name the workspace", text: $newName)
                    .textFieldStyle(.plain)
                    .font(Tokens.font(13))
                    .focused($nameFieldFocused)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Tokens.well))
                    .onAppear { nameFieldFocused = true }
                    .onSubmit {
                        guard !newName.trimmingCharacters(in: .whitespaces).isEmpty else { return }
                        let workspace = store.createWorkspace(named: newName)
                        newName = ""
                        namingNew = false
                        isPresented = false
                        Task { await store.switchWorkspace(to: workspace.id) }
                    }
                    .onExitCommand {
                        namingNew = false
                        newName = ""
                    }
            } else {
                Button {
                    namingNew = true
                } label: {
                    HStack {
                        Text("New workspace…")
                            .font(Tokens.font(13))
                            .foregroundStyle(Tokens.inkFaint)
                        Spacer()
                        Text("⌘⇧N")
                            .font(Tokens.font(11))
                            .foregroundStyle(Tokens.inkGhost)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(6)
        .frame(width: 224)
        .background(Tokens.canvas)
    }

    @ViewBuilder
    private func workspaceRow(_ workspace: Workspace) -> some View {
        let isActive = workspace.id == store.activeWorkspaceID
        if renamingID == workspace.id {
            TextField("Name", text: $renameText)
                .textFieldStyle(.plain)
                .font(Tokens.font(13))
                .focused($nameFieldFocused)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 6).fill(Tokens.well))
                .onSubmit {
                    store.renameWorkspace(workspace, to: renameText)
                    renamingID = nil
                }
                .onExitCommand { renamingID = nil }
        } else {
            Button {
                isPresented = false
                Task { await store.switchWorkspace(to: workspace.id) }
            } label: {
                HStack(spacing: 7) {
                    Circle()
                        .fill(isActive ? Tokens.accent : Tokens.inkGhost.opacity(0.5))
                        .frame(width: 6, height: 6)
                    Text(workspace.name)
                        .font(Tokens.font(13, isActive ? .medium : .regular))
                        .foregroundStyle(isActive ? Tokens.ink : Tokens.inkFaint)
                        .lineLimit(1)
                    Spacer()
                    Text(isActive
                         ? "\(workspace.tabs.count) tabs"
                         : "\(workspace.tabs.count) tabs resting")
                        .font(Tokens.font(11))
                        .foregroundStyle(Tokens.inkGhost)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .contextMenu {
                Button("Rename…") {
                    renameText = workspace.name
                    renamingID = workspace.id
                    nameFieldFocused = true
                }
                if !workspace.isEverythingElse {
                    Button("Delete workspace", role: .destructive) {
                        store.deleteWorkspace(workspace)
                        isPresented = false
                    }
                }
            }
        }
    }
}

// MARK: - Tab row

private struct TabRow: View {
    let tab: BrowserTab
    let isSelected: Bool
    let select: () -> Void
    let close: () -> Void

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 7) {
            glyph
            Text(tab.title)
                .font(Tokens.font(12.5))
                .foregroundStyle(tab.isMaterialized ? Tokens.ink : Tokens.inkFaint)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
            if hovering {
                Button(action: close) {
                    Image(systemName: "xmark")
                        .font(.system(size: 7.5, weight: .bold))
                        .foregroundStyle(Tokens.inkGhost)
                }
                .buttonStyle(.plain)
            } else if tab.isLoading {
                ProgressView()
                    .controlSize(.mini)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: Tokens.radiusControl)
                .fill(isSelected ? Tokens.stage : (hovering ? Tokens.well : .clear))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Tokens.radiusControl)
                .strokeBorder(isSelected ? Tokens.hairline : .clear, lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: select)
        .onHover { hovering = $0 }
    }

    private var glyph: some View {
        Text(tab.glyphLetter)
            .font(Tokens.font(9.5, .semibold))
            .foregroundStyle(glyphColor)
            .frame(width: 15, height: 15)
            .background(
                RoundedRectangle(cornerRadius: 3.5)
                    .fill(glyphColor.opacity(0.12))
            )
    }

    /// Muted, stable per-domain hue — the mocks' letter chips, no favicon fetch.
    private var glyphColor: Color {
        let palette: [Color] = [
            Color(hex: 0x267D7D), Color(hex: 0x7D6226), Color(hex: 0x5B4E8F),
            Color(hex: 0x8F4E62), Color(hex: 0x4E6F8F), Color(hex: 0x5F7D3A),
        ]
        guard let host = tab.url?.host() else { return Tokens.inkFaint }
        let domain = HostDisplay.registrableDomain(of: host)
        var hash = 5381
        for byte in domain.utf8 { hash = (hash &* 33) &+ Int(byte) }
        return palette[abs(hash) % palette.count]
    }
}

// MARK: - Downloads popover

private struct DownloadsListView: View {
    let downloads: DownloadsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if downloads.items.isEmpty {
                Text("Nothing downloaded yet.")
                    .font(Tokens.font(12))
                    .foregroundStyle(Tokens.inkGhost)
                    .padding(12)
            } else {
                ForEach(downloads.items) { item in
                    Button {
                        if let destination = item.destination {
                            NSWorkspace.shared.activateFileViewerSelecting([destination])
                        }
                    } label: {
                        HStack(spacing: 8) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(item.filename)
                                    .font(Tokens.font(12))
                                    .foregroundStyle(Tokens.ink)
                                    .lineLimit(1)
                                if item.state == .running {
                                    ProgressView(value: item.progress)
                                        .controlSize(.small)
                                } else if case .failed(let message) = item.state {
                                    Text(message)
                                        .font(Tokens.font(10.5))
                                        .foregroundStyle(Tokens.danger)
                                        .lineLimit(1)
                                }
                            }
                            Spacer()
                            if item.state == .finished {
                                Image(systemName: "magnifyingglass")
                                    .font(.system(size: 10))
                                    .foregroundStyle(Tokens.inkGhost)
                            }
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .frame(width: 260)
        .background(Tokens.canvas)
    }
}
