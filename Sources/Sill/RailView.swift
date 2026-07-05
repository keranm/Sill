import SwiftUI

extension Notification.Name {
    static let newWorkspace = Notification.Name("sill.newWorkspace")
}

/// The left rail, per D2a v2: workspace switcher → "Search or go to…" →
/// (Applications, only once any are confirmed — M5) → vertical tabs →
/// dormant workspaces and Downloads at the foot, as faint facts.
struct RailView: View {
    @Bindable var store: TabStore

    @Environment(\.openWindow) private var openWindow
    @State private var fieldText = ""
    @State private var switcherShown = false
    @State private var namingNew = false
    @State private var downloadsShown = false
    @FocusState private var fieldFocused: Bool

    @State private var favoritesTargeted = false
    @State private var measuredRowHeight: CGFloat = 28
    @State private var mouseUpMonitor: Any?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            workspaceHeader
                .padding(.horizontal, 10)
                .padding(.top, 35)

            goToField
                .padding(.horizontal, 10)
                .padding(.top, 10)

            // Shown while empty during a drag too, so there's a target to
            // drop the very first pinned/favorite tab onto.
            let isDraggingTab = store.dragState.draggingTabID != nil

            if !store.favorites.isEmpty || isDraggingTab {
                favoritesGrid
                    .padding(.horizontal, 10)
                    .padding(.top, 12)
            }

            if !store.pinnedTabs.isEmpty || isDraggingTab {
                pinnedTabList
                    .padding(.horizontal, 10)
                    .padding(.top, 12)

                Divider()
                    .overlay(Tokens.hairline)
                    .padding(.horizontal, 14)
                    .padding(.top, 10)
            }

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
        .onReceive(NotificationCenter.default.publisher(for: .newWorkspace)) { _ in
            namingNew = true
            switcherShown = true
        }
        // Safety net: a drag can end by releasing the mouse somewhere no
        // onDrop ever fires (blank canvas, outside the rail, dropped
        // rejected elsewhere) — without this, the drag state could stay
        // stuck and leave an empty Pinned/Favorites section or a dimmed
        // row on screen indefinitely. Any mouse-up is a safe place to
        // clear it: a real drop already cleared it itself by the time
        // this fires, so this is a no-op in the common case.
        .onAppear {
            if let mouseUpMonitor {
                NSEvent.removeMonitor(mouseUpMonitor)
            }
            mouseUpMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseUp) { event in
                store.dragState.clear()
                return event
            }
        }
        .onDisappear {
            if let mouseUpMonitor {
                NSEvent.removeMonitor(mouseUpMonitor)
            }
        }
    }

    // MARK: Favorites — "Pinned Tabs accessible in every Space" (owner-
    // requested). 3 per row, up to Favorite.maxCount, icon-only.

    private var favoritesGrid: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 6) {
            ForEach(store.favorites) { favorite in
                let openTab = store.tabs.first { $0.pinnedHomeDomain == DisplayNames.observationDomain(for: favorite.url.host() ?? "") }
                let isSelected = openTab != nil && openTab?.id == store.selectedTabID

                Button {
                    store.openFavorite(favorite)
                } label: {
                    GlyphView(url: favorite.url, size: 30, cornerRadius: 7)
                        .padding(.vertical, 5)
                        .frame(maxWidth: .infinity, minHeight: 40)
                        .background(
                            RoundedRectangle(cornerRadius: 9)
                                .fill(isSelected ? Tokens.stage : .clear)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 9)
                                .strokeBorder(isSelected ? Tokens.hairline : .clear, lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
                .help(favorite.title.isEmpty ? (favorite.url.host() ?? "") : favorite.title)
                .contextMenu {
                    if let openTab, openTab.url != favorite.url {
                        Button("Reset Tab") { store.resetPinnedTab(openTab) }
                    }
                    Button("Remove from Favorites", role: .destructive) {
                        store.removeFavorite(favorite)
                    }
                }
            }

            if favoritesTargeted {
                FavoriteDropIndicatorCell()
            }
        }
        .onDrop(of: [.plainText], isTargeted: $favoritesTargeted) { providers in
            TabDrag.resolve(providers, in: store) { tab in
                defer { store.dragState.clear() }
                guard let url = tab.url else { return }
                store.addFavorite(title: tab.title, url: url, sourceTab: tab)
            }
            return true
        }
    }

    // MARK: Workspace switcher (D2a: one action to change context)

    private var workspaceHeader: some View {
        HStack(spacing: 2) {
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

            Button {
                namingNew = true
                switcherShown = true
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Tokens.inkGhost)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("New workspace…")
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

    // MARK: Pinned tabs — stick around, never auto-archive (owner-requested,
    // Arc-inspired). Reorderable like Tabs; dragging one down into Tabs
    // unpins it, dragging it up into Favorites favorites it.

    private var pinnedTabList: some View {
        let pinned = store.pinnedTabs
        return VStack(spacing: 1) {
            ForEach(Array(pinned.enumerated()), id: \.element.id) { index, tab in
                if store.dragState.targetSection == .pinned && store.dragState.insertionIndex == index {
                    TabDropIndicator(height: measuredRowHeight)
                }

                if let partner = store.panelPartner(of: tab) {
                    PanelTabRow(
                        leftTab: tab,
                        rightTab: partner,
                        isSelected: tab.id == store.selectedTabID,
                        select: { store.selectedTabID = tab.id },
                        close: { store.closeTab(tab) },
                        separate: { store.separatePanel(tab) }
                    )
                } else {
                    TabRow(
                        tab: tab,
                        isSelected: tab.id == store.selectedTabID,
                        select: { store.selectedTabID = tab.id },
                        close: {},
                        peek: { openWindow(value: QuickLookRequest(initialURLString: tab.url?.absoluteString)) },
                        pin: nil,
                        unpin: { store.unpin(tab) },
                        resetToPinned: tab.pinnedURL != nil && tab.url != tab.pinnedURL
                            ? { store.resetPinnedTab(tab) }
                            : nil,
                        addFavorite: {
                            guard let url = tab.url else { return }
                            store.addFavorite(title: tab.title, url: url, sourceTab: tab)
                        }
                    )
                    .opacity(store.dragState.draggingTabID == tab.id ? 0.4 : 1)
                    // Also measures row height here, not just in the Tabs
                    // list — a workspace where every tab is pinned would
                    // otherwise never update `measuredRowHeight` past its
                    // 28pt default, throwing off the Pinned reorder math.
                    .background(
                        GeometryReader { proxy in
                            Color.clear.onAppear { measuredRowHeight = proxy.size.height }
                        }
                    )
                    .onDrag {
                        store.dragState.beginDrag(tab.id)
                        return TabDrag.provider(for: tab)
                    }
                }
            }

            if store.dragState.targetSection == .pinned && store.dragState.insertionIndex == pinned.count {
                TabDropIndicator(height: measuredRowHeight)
            }
        }
        .contentShape(Rectangle())
        .onDrop(
            of: [.plainText],
            delegate: TabReorderDropDelegate(
                section: .pinned,
                rowSlotHeight: measuredRowHeight + 1,
                tabCount: pinned.count,
                store: store,
                state: store.dragState
            )
        )
    }

    // MARK: Tabs — drag a row to reorder; the dashed line tracks where it'd
    // land. One drop delegate on the whole list (not one per row) computes
    // the target purely from the drop point's Y position divided by a
    // measured row height — a row's own frame is never consulted, so a row
    // shifting because the indicator appeared above it can't feed back into
    // where the indicator is computed to be (that feedback loop is what
    // caused the flicker: per-row delegates reading each row's post-reflow
    // frame).

    private var tabList: some View {
        let unpinned = store.unpinnedTabs
        return ScrollView {
            LazyVStack(spacing: 1) {
                ForEach(Array(unpinned.enumerated()), id: \.element.id) { index, tab in
                    if store.dragState.targetSection == .unpinned && store.dragState.insertionIndex == index {
                        TabDropIndicator(height: measuredRowHeight)
                    }

                    if let partner = store.panelPartner(of: tab) {
                        PanelTabRow(
                            leftTab: tab,
                            rightTab: partner,
                            isSelected: tab.id == store.selectedTabID,
                            select: { store.selectedTabID = tab.id },
                            close: { store.closeTab(tab) },
                            separate: { store.separatePanel(tab) }
                        )
                    } else {
                        TabRow(
                            tab: tab,
                            isSelected: tab.id == store.selectedTabID,
                            select: { store.selectedTabID = tab.id },
                            close: { store.closeTab(tab) },
                            peek: { openWindow(value: QuickLookRequest(initialURLString: tab.url?.absoluteString)) },
                            pin: { store.pin(tab) },
                            unpin: nil,
                            resetToPinned: nil,
                            addFavorite: {
                                guard let url = tab.url else { return }
                                store.addFavorite(title: tab.title, url: url, sourceTab: tab)
                            }
                        )
                        .opacity(store.dragState.draggingTabID == tab.id ? 0.4 : 1)
                        .background(
                            GeometryReader { proxy in
                                Color.clear.onAppear { measuredRowHeight = proxy.size.height }
                            }
                        )
                        .onDrag {
                            store.dragState.beginDrag(tab.id)
                            return TabDrag.provider(for: tab)
                        }
                    }
                }

                if store.dragState.targetSection == .unpinned && store.dragState.insertionIndex == unpinned.count {
                    TabDropIndicator(height: measuredRowHeight)
                }

                Button {
                    store.newTab()
                    NotificationCenter.default.post(name: .focusHomeField, object: nil)
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
            }
            .padding(.horizontal, 6)
            .contentShape(Rectangle())
            .onDrop(
                of: [.plainText],
                delegate: TabReorderDropDelegate(
                    section: .unpinned,
                    rowSlotHeight: measuredRowHeight + 1,
                    tabCount: unpinned.count,
                    store: store,
                    state: store.dragState
                )
            )
        }
        .id(store.activeWorkspaceID)
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

// MARK: - Panel row (Panel view: two tabs sharing the stage, one merged row)

/// Not draggable in v1 — a Panel is formed only by dropping a tab onto the
/// stage, and undone only via "Separate Panels" here.
private struct PanelTabRow: View {
    let leftTab: BrowserTab
    let rightTab: BrowserTab
    let isSelected: Bool
    let select: () -> Void
    let close: () -> Void
    let separate: () -> Void

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            side(leftTab)
            Rectangle()
                .fill(Tokens.hairline)
                .frame(width: 1, height: 14)
            side(rightTab)

            if hovering {
                Button(action: close) {
                    Image(systemName: "xmark")
                        .font(.system(size: 7.5, weight: .bold))
                        .foregroundStyle(Tokens.inkGhost)
                }
                .buttonStyle(.plain)
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
        .onTapGesture { select() }
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Separate Panels") { separate() }
            Button("Close Panel", role: .destructive) { close() }
        }
    }

    private func side(_ tab: BrowserTab) -> some View {
        HStack(spacing: 5) {
            GlyphView(url: tab.url)
            Text(tab.title)
                .font(Tokens.font(12.5))
                .foregroundStyle(tab.isMaterialized ? Tokens.ink : Tokens.inkFaint)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Tab row

private struct TabRow: View {
    let tab: BrowserTab
    let isSelected: Bool
    let select: () -> Void
    let close: () -> Void
    let peek: () -> Void
    let pin: (() -> Void)?
    let unpin: (() -> Void)?
    let resetToPinned: (() -> Void)?
    let addFavorite: (() -> Void)?

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
            if hovering, !tab.isPinned {
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
        .onTapGesture {
            if NSEvent.modifierFlags.contains([.command, .option]) {
                peek()
            } else {
                select()
            }
        }
        .onHover { hovering = $0 }
        .contextMenu {
            if let pin {
                Button("Pin Tab") { pin() }
                    .disabled(tab.url == nil)
            }
            if let resetToPinned {
                Button("Reset Tab") { resetToPinned() }
            }
            if let unpin {
                Button("Unpin Tab") { unpin() }
            }
            if let addFavorite {
                Button("Add to Favorites") { addFavorite() }
                    .disabled(tab.url == nil)
            }
            if unpin == nil {
                Button("Close Tab") { close() }
            }
        }
    }

    private var glyph: some View {
        GlyphView(url: tab.url)
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
