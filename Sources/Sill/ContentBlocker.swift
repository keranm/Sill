import WebKit

/// Declarative request blocking via WebKit's content-rule engine — the same
/// mechanism Safari ad blockers use. Rules are data, compiled by WebKit;
/// Sill's own code never touches page content, so the §3 constraints
/// (metadata only, no content scripts) stay intact. Complements the owner's
/// DNS-level blocking; its main target is ad-tech that dodges DNS with
/// randomised domains (Admiral and friends).
///
/// Lists live in Resources/Blocklists/*.json (Safari content-blocker format).
/// Current snapshots: EasyList ad-server domains (July 2026, conversion
/// documented in docs/M3-consent-import.md) and EasyList Cookie List
/// (July 2026, refresh via scripts/convert-cookie-list.py).
///
/// Lists named in `optInLists` are user-gated behind a Settings toggle and
/// ship OFF — hiding cookie-consent prompts is the user's decision to make
/// (GDPR posture), not the browser's. Everything else is always on.
@MainActor
final class ContentBlocker {
    private struct Compiled {
        let name: String
        let list: WKContentRuleList
    }

    /// List name (filename sans .json) → the UserDefaults key gating it.
    private static let optInLists = ["easylist-cookie": "cookieBannerBlocking"]

    private var compiled: [Compiled] = []
    /// Every controller ever attached, weakly — so a Settings toggle flip
    /// can reach webviews that already exist, not just future ones.
    private let controllers = NSHashTable<WKUserContentController>.weakObjects()

    func compile() {
        guard let urls = BundledResources.bundle?.urls(forResourcesWithExtension: "json", subdirectory: "Blocklists"),
              !urls.isEmpty else { return }
        let store = WKContentRuleListStore.default()
        for url in urls {
            let identifier = url.deletingPathExtension().lastPathComponent
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int ?? 0
            let versionedID = "\(identifier)-\(size)"

            store?.lookUpContentRuleList(forIdentifier: versionedID) { [weak self] cached, _ in
                if let cached {
                    Task { @MainActor in self?.adopt(name: identifier, list: cached) }
                    return
                }
                guard let json = try? String(contentsOf: url, encoding: .utf8) else { return }
                store?.compileContentRuleList(forIdentifier: versionedID, encodedContentRuleList: json) { compiled, error in
                    if let compiled {
                        Task { @MainActor in self?.adopt(name: identifier, list: compiled) }
                    } else if let error {
                        NSLog("Sill content blocker: compile failed for \(identifier): \(error)")
                    }
                }
            }
        }
    }

    private func adopt(name: String, list: WKContentRuleList) {
        compiled.append(Compiled(name: name, list: list))
        guard isEnabled(name) else { return }
        for controller in controllers.allObjects {
            controller.add(list)
        }
    }

    private func isEnabled(_ name: String) -> Bool {
        guard let key = Self.optInLists[name] else { return true }
        return UserDefaults.standard.bool(forKey: key)
    }

    /// Applies enabled lists now and keeps the controller subscribed to
    /// lists that finish compiling later (first launch) and to Settings
    /// toggle flips.
    func attach(to controller: WKUserContentController) {
        controllers.add(controller)
        for item in compiled where isEnabled(item.name) {
            controller.add(item.list)
        }
    }

    /// Re-reads the gates and updates every live webview. New page loads see
    /// the change immediately; already-rendered pages need a reload.
    func refreshGates() {
        for item in compiled where Self.optInLists[item.name] != nil {
            let enabled = isEnabled(item.name)
            for controller in controllers.allObjects {
                // Remove-then-add keeps this idempotent regardless of the
                // controller's current state.
                controller.remove(item.list)
                if enabled {
                    controller.add(item.list)
                }
            }
        }
    }
}
