import SwiftUI
import AppKit

/// Panel view (owner's naming for Arc's Split View): two tabs side by side
/// on one stage. `leftTab` owns `panelSplitRatio` — the only one consulted
/// for layout; `rightTab` fills whatever's left.
struct PanelSplitView: View {
    @Bindable var store: TabStore
    let leftTab: BrowserTab
    let rightTab: BrowserTab

    /// Live value while the divider is actively being dragged; committed to
    /// `leftTab.panelSplitRatio` (and persisted) only on release, so resizing
    /// doesn't spam persistSession() every pixel of drag.
    @State private var liveRatio: CGFloat?
    @State private var dividerHovering = false

    private static let minRatio: CGFloat = 0.25
    private static let maxRatio: CGFloat = 0.75

    var body: some View {
        GeometryReader { geo in
            let ratio = min(max(liveRatio ?? leftTab.panelSplitRatio, Self.minRatio), Self.maxRatio)
            HStack(spacing: 0) {
                side(leftTab)
                    .frame(width: (geo.size.width * ratio).rounded())
                divider(totalWidth: geo.size.width)
                side(rightTab)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    @ViewBuilder
    private func side(_ tab: BrowserTab) -> some View {
        if let webView = tab.webView, tab.url != nil {
            WebViewContainer(webView: webView)
                .id(tab.id)
        } else {
            HomeView(store: store, tab: tab)
        }
    }

    /// A real 9pt-wide layout gutter, not a 1pt line with an overlay that
    /// extends past its own frame — the two WKWebViews sit right at the
    /// edge of their HStack slots, and their native AppKit views win hit-
    /// testing over any SwiftUI content that only visually (not layout-
    /// wise) overlaps them, so a thin line with a wider invisible overlay
    /// never actually receives the drag. Same family of issue as Glance's
    /// cursor-rect bleed-through, fixed the same way: give it its own space.
    private func divider(totalWidth: CGFloat) -> some View {
        let active = dividerHovering || liveRatio != nil
        return ZStack {
            Rectangle()
                .fill(active ? Tokens.accent : Tokens.hairline)
                .frame(width: active ? 3 : 1)
        }
        .frame(width: 9)
        .contentShape(Rectangle())
        .animation(.easeOut(duration: 0.1), value: active)
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    let proposed = leftTab.panelSplitRatio + value.translation.width / totalWidth
                    liveRatio = min(max(proposed, Self.minRatio), Self.maxRatio)
                }
                .onEnded { _ in
                    if let liveRatio {
                        leftTab.panelSplitRatio = liveRatio
                        store.persistSession()
                    }
                    liveRatio = nil
                }
        )
        .onHover { inside in
            dividerHovering = inside
            if inside {
                NSCursor.resizeLeftRight.push()
            } else {
                NSCursor.pop()
            }
        }
    }
}

/// Location-aware drop target for forming a Panel: unlike the simple
/// isTargeted-only closure form of `.onDrop`, a `DropDelegate` hands back
/// where in the stage the drop actually landed, so the dragged-in tab lands
/// on whichever half you dropped it on rather than a fixed side.
struct PanelDropDelegate: DropDelegate {
    let stageWidth: CGFloat
    let store: TabStore
    let isTargeted: Binding<Bool>

    func dropEntered(info: DropInfo) {
        isTargeted.wrappedValue = true
    }

    func dropExited(info: DropInfo) {
        isTargeted.wrappedValue = false
    }

    func performDrop(info: DropInfo) -> Bool {
        isTargeted.wrappedValue = false
        let droppedOnLeft = info.location.x < stageWidth / 2
        // Clear synchronously, matching TabReorderDropDelegate — if
        // TabDrag.resolve's async lookup ever fails to find the tab (closed
        // mid-drag, say), the dimmed source row / drag state must not be
        // left stuck waiting on a completion handler that never runs.
        store.dragState.clear()
        TabDrag.resolve(info.itemProviders(for: [.plainText]), in: store) { dragged in
            store.formPanel(with: dragged, draggedOnLeft: droppedOnLeft)
        }
        return true
    }
}
