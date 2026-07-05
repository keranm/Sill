import Foundation

/// Favorites (PRD-adjacent, owner-requested): "Pinned Tabs that are
/// accessible in every Space" — a small, global list of top sites reachable
/// from any workspace, shown above the workspace switcher.
struct Favorite: Identifiable, Equatable {
    let id: UUID
    var url: URL
    var title: String

    static let maxCount = 15
}
