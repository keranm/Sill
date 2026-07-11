import SwiftUI

/// The icons-only rail (Arc/Edge-style collapse): every Favorite, pinned tab
/// and tab as a bare glyph in one column, so the stage gets the width back
/// without losing one-click access to anything. Hovering anywhere on the
/// strip for a beat slides the full rail out over the stage (ShellView owns
/// that flyout); clicking an icon goes straight there without expanding —
/// the Edge trick the collapse is modelled on.
struct CollapsedRailView: View {
    @Bindable var store: TabStore

    var body: some View {
        VStack(spacing: 0) {
            // The traffic lights float over this strip (fullSizeContentView),
            // same 35pt clearance as the full rail.
            workspaceDot
                .padding(.top, 39)

            if !store.favorites.isEmpty {
                iconColumn(spacing: 4) {
                    ForEach(store.favorites) { favorite in
                        favoriteIcon(favorite)
                    }
                }
                .padding(.top, 14)
            }

            if !store.pinnedTabs.isEmpty {
                iconColumn(spacing: 2) {
                    ForEach(store.pinnedTabs) { tab in
                        tabIcon(tab)
                    }
                }
                .padding(.top, 12)

                Divider()
                    .overlay(Tokens.hairline)
                    .padding(.horizontal, 18)
                    .padding(.top, 10)
            }

            ScrollView(showsIndicators: false) {
                LazyVStack(spacing: 2) {
                    ForEach(store.unpinnedTabs) { tab in
                        tabIcon(tab)
                    }

                    Button {
                        store.focusRequestedTabID = store.newTab().id
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Tokens.inkGhost)
                            .frame(width: 36, height: 30)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("New tab")
                }
                .padding(.top, 10)
            }

            Spacer(minLength: 0)
        }
        .frame(width: Tokens.railCollapsedWidth)
        .frame(maxHeight: .infinity)
        .background(Tokens.canvas)
        .contentShape(Rectangle())
        // Same Finder-drop behaviour as the full rail.
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            store.handleDroppedFileProviders(providers)
        }
    }

    private func iconColumn<Content: View>(spacing: CGFloat, @ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: spacing) { content() }
    }

    private var workspaceDot: some View {
        Circle()
            .fill(Tokens.accent)
            .frame(width: 6, height: 6)
            .frame(width: 36, height: 14)
            .help(store.railTitle)
    }

    private func favoriteIcon(_ favorite: Favorite) -> some View {
        let isSelected = store.selectedFavoriteID == favorite.id
        return Button {
            store.openFavorite(favorite)
        } label: {
            GlyphView(url: favorite.url, size: 26, cornerRadius: 6)
                .frame(width: 36, height: 34)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(isSelected ? Tokens.stage : .clear)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(isSelected ? Tokens.hairline : .clear, lineWidth: 1)
                )
                .overlay(alignment: .topTrailing) {
                    // Same heads-up badge as the full rail, sized to fit.
                    if let count = store.headsUp.badgeCount(for: favorite) {
                        HeadsUpBadge(count: count, compact: true)
                            .offset(x: 1, y: -1)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(favorite.title.isEmpty ? (favorite.url.host() ?? "") : favorite.title)
    }

    private func tabIcon(_ tab: BrowserTab) -> some View {
        let isSelected = tab.id == store.selectedTabID
        return Button {
            store.selectedTabID = tab.id
        } label: {
            GlyphView(url: tab.url, size: 18, cornerRadius: 4.5)
                .frame(width: 36, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: Tokens.radiusControl)
                        .fill(isSelected ? Tokens.stage : .clear)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Tokens.radiusControl)
                        .strokeBorder(isSelected ? Tokens.hairline : .clear, lineWidth: 1)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(tab.title.isEmpty ? (tab.url?.host() ?? "New tab") : tab.title)
        .contextMenu {
            if tab.isPinned {
                Button("Unpin Tab") { store.unpin(tab) }
            } else {
                Button("Close Tab") { store.closeTab(tab) }
            }
        }
    }
}
