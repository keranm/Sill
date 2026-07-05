import SwiftUI
import UniformTypeIdentifiers

/// Drag payload for a rail tab row: just the tab's id, carried as plain text
/// so `BrowserTab` (which owns a WKWebView) never needs `Transferable`/`Codable`.
enum TabDrag {
    static func provider(for tab: BrowserTab) -> NSItemProvider {
        NSItemProvider(object: tab.id.uuidString as NSString)
    }

    /// Resolves the dragged tab against the active workspace once macOS hands
    /// back the item provider's string payload (async by NSItemProvider's own API).
    static func resolve(_ providers: [NSItemProvider], in store: TabStore, then handle: @escaping (BrowserTab) -> Void) {
        guard let provider = providers.first(where: { $0.canLoadObject(ofClass: NSString.self) }) else { return }
        _ = provider.loadObject(ofClass: NSString.self) { reading, _ in
            guard let idString = reading as? String, let id = UUID(uuidString: idString) else { return }
            Task { @MainActor in
                guard let tab = store.tabs.first(where: { $0.id == id }) else { return }
                handle(tab)
            }
        }
    }
}

/// Live drop-position tracking, shared by both the Pinned and Tabs lists:
/// which section and which gap within it the dragged tab would land in,
/// updated continuously as the pointer moves so the dashed insertion
/// indicator can track it.
@MainActor
@Observable
final class TabReorderState {
    private(set) var draggingTabID: BrowserTab.ID?
    private(set) var targetSection: RailSection?
    private(set) var insertionIndex: Int?
    private var latched = false

    /// A fresh drag always unlatches — any previous drop is old news.
    func beginDrag(_ id: BrowserTab.ID) {
        latched = false
        draggingTabID = id
    }

    /// Ignored once `clear()` has latched. Guards a real, observed race: after
    /// `performDrop` fires and clears state, SwiftUI can still deliver one
    /// more trailing `dropUpdated` for the same gesture a beat later — without
    /// this latch that stray update resurrects the indicator with nothing
    /// left afterward to clear it, leaving it stuck on screen permanently.
    ///
    /// `nil` only clears the indicator if `section` still owns it — the
    /// Pinned and Tabs lists sit right next to each other, and one's
    /// dropExited can otherwise land after the other's fresh dropEntered
    /// already claimed the indicator, erasing it from the wrong section.
    func updateInsertion(_ index: Int?, in section: RailSection) {
        guard !latched else { return }
        if let index {
            // dropUpdated fires continuously as the pointer moves; skip the
            // (observable, re-render-triggering) write when nothing's
            // actually changed rather than on every pixel of movement.
            guard targetSection != section || insertionIndex != index else { return }
            targetSection = section
            insertionIndex = index
        } else if targetSection == section {
            targetSection = nil
            insertionIndex = nil
        }
    }

    func clear() {
        latched = true
        draggingTabID = nil
        targetSection = nil
        insertionIndex = nil
    }
}

/// One drop target spanning a whole section's list (Pinned or Tabs).
/// Deliberately *not* one delegate per row: attaching a delegate to each row
/// and asking "is the pointer above or below this row's own frame" creates a
/// feedback loop the moment a placeholder is inserted (the insert shifts
/// every row below it, which changes that row's frame, which can flip the
/// proposed index, which changes what's inserted where — visible as flicker
/// and occasional dropped/rejected drops). Computing the index purely from
/// the drop point's Y offset against a fixed slot height never consults any
/// row's frame, so reflow elsewhere can't feed back into it.
///
/// The same delegate handles both a pure reorder (dragged tab already
/// belongs to `section`) and a cross-section move (Pinned ↔ Tabs) — both go
/// through `TabStore.placeTab`, which pins/unpins to match `section`.
struct TabReorderDropDelegate: DropDelegate {
    let section: RailSection
    let rowSlotHeight: CGFloat
    let tabCount: Int
    let store: TabStore
    let state: TabReorderState

    func dropEntered(info: DropInfo) {
        state.updateInsertion(index(for: info), in: section)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        state.updateInsertion(index(for: info), in: section)
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        state.updateInsertion(nil, in: section)
    }

    func performDrop(info: DropInfo) -> Bool {
        let target = index(for: info)
        // Clear synchronously — the actual move resolves async (NSItemProvider's
        // own API), and if resolution ever fails silently the dashed indicator
        // must not be left stuck on screen.
        state.clear()
        TabDrag.resolve(info.itemProviders(for: [.plainText]), in: store) { tab in
            store.placeTab(tab, inSection: section, atIndex: target)
        }
        return true
    }

    private func index(for info: DropInfo) -> Int {
        guard rowSlotHeight > 0 else { return tabCount }
        let raw = Int((info.location.y / rowSlotHeight).rounded())
        return min(max(raw, 0), tabCount)
    }
}

/// A dashed, row-shaped placeholder shown at the proposed insertion point
/// while dragging (Tabs list) or at the end of the list (Pinned).
struct TabDropIndicator: View {
    var height: CGFloat = 28

    var body: some View {
        RoundedRectangle(cornerRadius: Tokens.radiusControl)
            .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
            .foregroundStyle(Tokens.accent.opacity(0.6))
            .frame(height: height)
    }
}

/// A dashed placeholder the size of one Favorites tile (the grid is 3 wide),
/// appended as the next cell while a tab is dragged over the grid.
struct FavoriteDropIndicatorCell: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 9)
            .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
            .foregroundStyle(Tokens.accent.opacity(0.6))
            .frame(maxWidth: .infinity, minHeight: 40)
    }
}
