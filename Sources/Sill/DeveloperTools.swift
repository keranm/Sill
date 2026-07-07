import WebKit

/// developer-tools.md #1 — Inspector. `isInspectable` (set in
/// `TabStore.makeWebView`) is the real commitment: it makes right-click →
/// "Inspect Element" always available, for free, from WebKit itself. This
/// extension is just a menu-item convenience on top of that — WebKit has no
/// public API to *open* the inspector programmatically, only to allow it, so
/// this reaches for the private `_inspector`/`show()` pair that third-party
/// WebKit browsers commonly use for exactly this. Every step is guarded with
/// `responds(to:)` so a future macOS renaming this away just makes the menu
/// item silently do nothing — right-click remains the reliable path either way.
extension WKWebView {
    @discardableResult
    func showInspector() -> Bool {
        guard isInspectable else { return false }
        let inspectorSelector = NSSelectorFromString("_inspector")
        guard responds(to: inspectorSelector),
              let inspector = perform(inspectorSelector)?.takeUnretainedValue() else { return false }
        let showSelector = NSSelectorFromString("show")
        guard inspector.responds(to: showSelector) else { return false }
        _ = inspector.perform(showSelector)
        return true
    }
}
