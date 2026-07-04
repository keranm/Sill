import WebKit

/// Declarative request blocking via WebKit's content-rule engine — the same
/// mechanism Safari ad blockers use. Rules are data, compiled by WebKit;
/// Sill's own code never touches page content, so the §3 constraints
/// (metadata only, no content scripts) stay intact. Complements the owner's
/// DNS-level blocking; its main target is ad-tech that dodges DNS with
/// randomised domains (Admiral and friends).
///
/// Lists live in Resources/Blocklists/*.json (Safari content-blocker format).
/// Current snapshot: EasyList ad-server domains, July 2026. Refresh by
/// re-running the conversion documented in docs/M3-consent-import.md.
@MainActor
final class ContentBlocker {
    private(set) var ruleLists: [WKContentRuleList] = []
    private var onReady: [(WKContentRuleList) -> Void] = []

    func compile() {
        guard let urls = Bundle.module.urls(forResourcesWithExtension: "json", subdirectory: "Blocklists"),
              !urls.isEmpty else { return }
        let store = WKContentRuleListStore.default()
        for url in urls {
            let identifier = url.deletingPathExtension().lastPathComponent
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int ?? 0
            let versionedID = "\(identifier)-\(size)"

            store?.lookUpContentRuleList(forIdentifier: versionedID) { [weak self] cached, _ in
                if let cached {
                    Task { @MainActor in self?.adopt(cached) }
                    return
                }
                guard let json = try? String(contentsOf: url, encoding: .utf8) else { return }
                store?.compileContentRuleList(forIdentifier: versionedID, encodedContentRuleList: json) { compiled, error in
                    if let compiled {
                        Task { @MainActor in self?.adopt(compiled) }
                    } else if let error {
                        NSLog("Sill content blocker: compile failed for \(identifier): \(error)")
                    }
                }
            }
        }
    }

    private func adopt(_ ruleList: WKContentRuleList) {
        ruleLists.append(ruleList)
        for callback in onReady {
            callback(ruleList)
        }
    }

    /// Applies already-compiled lists and subscribes the controller to any
    /// that finish compiling later (first launch).
    func attach(to controller: WKUserContentController) {
        for ruleList in ruleLists {
            controller.add(ruleList)
        }
        onReady.append { [weak controller] ruleList in
            controller?.add(ruleList)
        }
    }
}
