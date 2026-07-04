import Foundation
import Observation

/// A first-class context (PRD §4.2). "Everything else" is a real, ordinary
/// workspace — born automatically with the first user workspace, holds
/// unclaimed tabs, hibernates like any other, renameable, undeletable while
/// it is the only other context.
@MainActor
@Observable
final class Workspace: Identifiable {
    let id: UUID
    var name: String
    let isEverythingElse: Bool
    var tabs: [BrowserTab] = []
    var selectedTabID: BrowserTab.ID?

    init(id: UUID = UUID(), name: String, isEverythingElse: Bool = false) {
        self.id = id
        self.name = name
        self.isEverythingElse = isEverythingElse
    }

    var selectedTab: BrowserTab? {
        tabs.first { $0.id == selectedTabID }
    }

    /// Dormant = no live webviews (how the switcher decides to say "resting").
    var isDormant: Bool {
        !tabs.contains { $0.isMaterialized }
    }
}
