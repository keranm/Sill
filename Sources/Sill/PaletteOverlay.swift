import SwiftUI
import AppKit

/// The command palette (D2e): ⌘K, conventional interaction, calm appearance.
/// Groups exactly as drawn — actions, workspaces, applications, history (plus
/// the flat bookmark list §4.4 promised the palette), web-search fallback.
/// ⌘↵ opens in a new tab. No learning behaviour in the PoC.
///
/// ⌘L opens the same surface in go-to mode: current URL pre-filled, selected
/// (§4.1) — twenty years of muscle memory, one field.
struct PaletteOverlay: View {
    enum Mode {
        case command, goTo
    }

    @Bindable var store: TabStore
    let mode: Mode
    @Binding var isPresented: Bool

    @State private var query = ""
    @State private var selectedIndex = 0

    struct Item: Identifiable {
        enum Kind {
            case run(() -> Void)
            case navigate(String)
            case switchWorkspace(Workspace.ID)
        }

        let id: String
        let group: String
        let title: String
        let hint: String?
        let glyph: String?
        let kind: Kind
        var boldRange: Range<String.Index>?
    }

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.opacity(0.08)
                .ignoresSafeArea()
                .onTapGesture { isPresented = false }

            VStack(spacing: 0) {
                PaletteField(
                    text: $query,
                    placeholder: mode == .goTo ? "Search, go to…" : "Search, go to, or do…",
                    onSubmit: { newTab in perform(newTab: newTab) },
                    onCancel: { isPresented = false },
                    onMove: { delta in
                        let count = items.count
                        guard count > 0 else { return }
                        selectedIndex = (selectedIndex + delta + count) % count
                    }
                )
                .padding(.horizontal, 14)
                .padding(.vertical, 11)

                if !items.isEmpty {
                    Divider().overlay(Tokens.hairline)
                    resultsList
                    Divider().overlay(Tokens.hairline)
                    footer
                }
            }
            .frame(width: 520)
            .background(
                RoundedRectangle(cornerRadius: Tokens.radiusStage)
                    .fill(Tokens.canvas)
                    .shadow(color: .black.opacity(0.15), radius: 24, y: 9)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Tokens.radiusStage)
                    .strokeBorder(Tokens.hairline, lineWidth: 1)
            )
            .padding(.top, 84)
        }
        .onAppear {
            if mode == .goTo {
                query = store.selectedTab?.url?.absoluteString ?? ""
            }
        }
        .onChange(of: query) {
            selectedIndex = 0
        }
    }

    // MARK: Results

    private var resultsList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    let grouped = Dictionary(grouping: Array(items.enumerated()), by: { $0.element.group })
                    ForEach(groupOrder.filter { grouped[$0] != nil }, id: \.self) { group in
                        Text(group)
                            .font(Tokens.font(9.5, .medium))
                            .kerning(0.8)
                            .foregroundStyle(Tokens.inkGhost)
                            .padding(.horizontal, 14)
                            .padding(.top, 8)
                            .padding(.bottom, 3)
                        ForEach(grouped[group]!, id: \.element.id) { index, item in
                            row(item, isSelected: index == selectedIndex)
                                .id(index)
                                .onTapGesture {
                                    selectedIndex = index
                                    perform(newTab: false)
                                }
                        }
                    }
                }
                .padding(.bottom, 6)
            }
            .frame(maxHeight: 320)
            .onChange(of: selectedIndex) {
                proxy.scrollTo(selectedIndex)
            }
        }
    }

    private func row(_ item: Item, isSelected: Bool) -> some View {
        HStack(spacing: 8) {
            if let glyph = item.glyph {
                Text(glyph)
                    .font(Tokens.font(9.5, .semibold))
                    .foregroundStyle(Tokens.accent)
                    .frame(width: 16, height: 16)
                    .background(RoundedRectangle(cornerRadius: 4).fill(Tokens.accent.opacity(0.1)))
            }
            highlightedTitle(item)
                .lineLimit(1)
            Spacer()
            if let hint = item.hint {
                Text(hint)
                    .font(Tokens.font(11))
                    .foregroundStyle(Tokens.inkGhost)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5.5)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? Tokens.accentWash : .clear)
        )
        .padding(.horizontal, 6)
        .contentShape(Rectangle())
    }

    private func highlightedTitle(_ item: Item) -> Text {
        let title = item.title
        guard !query.isEmpty,
              let range = title.range(of: query, options: [.caseInsensitive]) else {
            return Text(title).font(Tokens.font(12.5)).foregroundStyle(Tokens.ink)
        }
        return Text(title[title.startIndex..<range.lowerBound]).font(Tokens.font(12.5)).foregroundColor(Tokens.ink.opacity(0.75))
            + Text(title[range]).font(Tokens.font(12.5, .semibold)).foregroundColor(Tokens.ink)
            + Text(title[range.upperBound...]).font(Tokens.font(12.5)).foregroundColor(Tokens.ink.opacity(0.75))
    }

    private var footer: some View {
        HStack(spacing: 14) {
            Text("↑↓ move")
            Text("↵ open")
            Text("⌘↵ new tab")
            Spacer()
            Text("esc")
        }
        .font(Tokens.font(10.5))
        .foregroundStyle(Tokens.inkGhost)
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
    }

    // MARK: Item building (no learning behaviour — plain matching only)

    private let groupOrder = ["GO TO", "ACTIONS", "WORKSPACES", "APPLICATIONS", "HISTORY", "BOOKMARKS", "SEARCH"]

    private var items: [Item] {
        var built: [Item] = []
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        let lowered = trimmed.lowercased()

        // Go-to: anything URL-shaped leads.
        if !trimmed.isEmpty, trimmed.contains("."), !trimmed.contains(" ") {
            built.append(Item(
                id: "goto", group: "GO TO", title: trimmed,
                hint: "open", glyph: "→",
                kind: .navigate(trimmed)
            ))
        }

        let actions: [(String, String?, () -> Void)] = [
            ("New tab", "⌘T", { store.newTab(); NotificationCenter.default.post(name: .focusHomeField, object: nil) }),
            ("New workspace…", "⌘⇧N", { NotificationCenter.default.post(name: .newWorkspace, object: nil) }),
            ("Open Learning page", "⌘⇧L", { NotificationCenter.default.post(name: .openLearning, object: nil) }),
            ("Import browsing history…", nil, { NotificationCenter.default.post(name: .openImport, object: nil) }),
        ]
        for (title, hint, run) in actions where lowered.isEmpty || title.lowercased().contains(lowered) {
            built.append(Item(id: "action-\(title)", group: "ACTIONS", title: title, hint: hint, glyph: "+", kind: .run(run)))
        }

        for workspace in store.workspaces where store.hasUserWorkspaces || workspace.id == store.activeWorkspaceID {
            guard lowered.isEmpty || workspace.name.lowercased().contains(lowered) else { continue }
            let isCurrent = workspace.id == store.activeWorkspaceID
            built.append(Item(
                id: "ws-\(workspace.id)", group: "WORKSPACES", title: workspace.name,
                hint: isCurrent ? "current" : "switch ↵", glyph: "•",
                kind: .switchWorkspace(workspace.id)
            ))
        }

        for app in store.patterns.confirmedApplications {
            let name = DisplayNames.displayName(for: app.domains[0])
            guard lowered.isEmpty || name.lowercased().contains(lowered) else { continue }
            let destination = store.observations.mostVisitedURL(forDomain: app.domains[0])?.absoluteString
                ?? "https://\(app.domains[0])/"
            built.append(Item(
                id: "app-\(app.domains[0])", group: "APPLICATIONS", title: name,
                hint: nil, glyph: String(name.prefix(1)),
                kind: .navigate(destination)
            ))
        }

        if lowered.count >= 2 {
            built.append(contentsOf: historyItems(matching: lowered))
            built.append(contentsOf: bookmarkItems(matching: lowered))
        }

        if !trimmed.isEmpty {
            built.append(Item(
                id: "search", group: "SEARCH",
                title: "Search the web for \u{201C}\(trimmed)\u{201D}",
                hint: nil, glyph: "?",
                kind: .navigate(trimmed)
            ))
        }

        // Empty command palette: actions and places, ready (D2e).
        if trimmed.isEmpty {
            built = Array(built.prefix(9))
        }
        return built
    }

    private func historyItems(matching lowered: String) -> [Item] {
        let escaped = lowered.replacingOccurrences(of: "%", with: "").replacingOccurrences(of: "_", with: "")
        let rows = (try? store.database.query("""
            SELECT title, domain, path, scheme, max(ts) AS ts FROM event
            WHERE kind = 'visit' AND (lower(title) LIKE ? OR domain LIKE ?)
            GROUP BY domain, title ORDER BY ts DESC LIMIT 5
            """, [.text("%\(escaped)%"), .text("%\(escaped)%")])) ?? []
        return rows.compactMap { row in
            guard let domain = row.text("domain"), let ts = row.real("ts") else { return nil }
            let title = row.text("title").flatMap { $0.isEmpty ? nil : $0 } ?? domain
            let scheme = row.text("scheme") ?? "https"
            let path = row.text("path").flatMap { $0.isEmpty ? nil : $0 } ?? "/"
            return Item(
                id: "hist-\(domain)-\(title)", group: "HISTORY", title: title,
                hint: relativePast(ts), glyph: String(DisplayNames.displayName(for: domain).prefix(1)),
                kind: .navigate("\(scheme)://\(domain)\(path)")
            )
        }
    }

    private func bookmarkItems(matching lowered: String) -> [Item] {
        let escaped = lowered.replacingOccurrences(of: "%", with: "").replacingOccurrences(of: "_", with: "")
        let rows = (try? store.database.query("""
            SELECT url, title FROM bookmark
            WHERE lower(title) LIKE ? OR lower(url) LIKE ? LIMIT 4
            """, [.text("%\(escaped)%"), .text("%\(escaped)%")])) ?? []
        return rows.compactMap { row in
            guard let url = row.text("url") else { return nil }
            let title = row.text("title").flatMap { $0.isEmpty ? nil : $0 } ?? url
            return Item(
                id: "bm-\(url)", group: "BOOKMARKS", title: title,
                hint: nil, glyph: "☆",
                kind: .navigate(url)
            )
        }
    }

    /// D2e shows "last week", "June" — rounded, never exact.
    private func relativePast(_ ts: TimeInterval) -> String {
        let delta = Date().timeIntervalSince1970 - ts
        switch delta {
        case ..<86400: return "today"
        case ..<172_800: return "yesterday"
        case ..<604_800: return "this week"
        case ..<1_209_600: return "last week"
        default:
            let formatter = DateFormatter()
            formatter.dateFormat = "MMMM"
            return formatter.string(from: Date(timeIntervalSince1970: ts))
        }
    }

    // MARK: Perform

    private func perform(newTab: Bool) {
        guard items.indices.contains(selectedIndex) else {
            // Bare text with no results: treat as go-to/search.
            if !query.isEmpty { navigate(query, newTab: newTab) }
            isPresented = false
            return
        }
        switch items[selectedIndex].kind {
        case .run(let action):
            isPresented = false
            action()
        case .navigate(let destination):
            navigate(destination, newTab: newTab)
            isPresented = false
        case .switchWorkspace(let id):
            isPresented = false
            Task { await store.switchWorkspace(to: id) }
        }
    }

    private func navigate(_ input: String, newTab: Bool) {
        if newTab || store.selectedTab == nil {
            store.openInNewTab(input)
        } else if let tab = store.selectedTab {
            store.navigate(input, in: tab)
        }
    }
}

/// AppKit-backed field: guaranteed focus + select-all (the ⌘L contract),
/// arrow keys steer the list, ⌘↵ reports as a new-tab submit.
private struct PaletteField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let onSubmit: (_ newTab: Bool) -> Void
    let onCancel: () -> Void
    let onMove: (Int) -> Void

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = NSFont(name: Tokens.fontFamily, size: 14) ?? .systemFont(ofSize: 14)
        field.textColor = NSColor(Tokens.ink)
        field.placeholderString = placeholder
        field.delegate = context.coordinator
        field.stringValue = text
        DispatchQueue.main.async {
            field.window?.makeFirstResponder(field)
            field.currentEditor()?.selectAll(nil)
        }
        return field
    }

    func updateNSView(_ nsView: NSTextField, context: Context) {
        if nsView.stringValue != text {
            nsView.stringValue = text
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        let parent: PaletteField
        init(_ parent: PaletteField) { self.parent = parent }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
                let commandHeld = NSApp.currentEvent?.modifierFlags.contains(.command) ?? false
                parent.onSubmit(commandHeld)
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                parent.onCancel()
                return true
            case #selector(NSResponder.moveUp(_:)):
                parent.onMove(-1)
                return true
            case #selector(NSResponder.moveDown(_:)):
                parent.onMove(1)
                return true
            default:
                return false
            }
        }
    }
}
