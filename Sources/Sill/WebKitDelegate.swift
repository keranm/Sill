import AppKit
import WebKit

/// Shared navigation + UI delegate for every webview in the shell.
/// Login flows need three things handled here: popup windows created with the
/// configuration WebKit provides (opener relationship intact), `window.close()`
/// honoured, and JS panels answered rather than silently dropped.
@MainActor
final class WebKitDelegate: NSObject, WKNavigationDelegate, WKUIDelegate {
    private weak var store: TabStore?

    init(store: TabStore) {
        self.store = store
    }

    // MARK: - Popups

    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        guard let store else { return nil }
        let opener = store.tab(for: webView)

        // Sites often open outbound links (target="_blank", window.open —
        // Gmail's "View Order" links, for instance) via this popup path
        // rather than same-tab navigation, so Pinned Tabs' Glance redirect
        // has to be checked here too, not just in decidePolicyFor below.
        if let destination = glanceDestination(for: navigationAction.request.url, from: opener) {
            store.glanceURL = destination
            return nil
        }

        let tab = store.newTab(configuration: configuration, select: true, openedFrom: opener)
        return tab.webView
    }

    /// Pinned Tabs stay anchored to their home domain: a link elsewhere opens
    /// in Glance instead of replacing the pinned page or opening a plain new
    /// tab. Resolves common link-wrapping redirectors first (Gmail rewrites
    /// external links as `google.com/url?q=...` for click tracking, which
    /// would otherwise still read as same-domain and slip through).
    private func glanceDestination(for requestURL: URL?, from tab: BrowserTab?) -> URL? {
        guard let tab, let requestURL, let homeDomain = tab.pinnedHomeDomain else { return nil }
        let destination = Self.resolvingRedirectWrapper(requestURL)
        guard let destinationHost = destination.host(),
              DisplayNames.observationDomain(for: destinationHost) != homeDomain else { return nil }
        return destination
    }

    private static func resolvingRedirectWrapper(_ url: URL) -> URL {
        guard let host = url.host(), host.hasSuffix("google.com"), url.path == "/url",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let target = components.queryItems?.first(where: { $0.name == "q" })?.value,
              let targetURL = URL(string: target) else {
            return url
        }
        return targetURL
    }

    func webViewDidClose(_ webView: WKWebView) {
        store?.closeTab(webView: webView)
    }

    // MARK: - Navigation policy

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        if navigationAction.shouldPerformDownload {
            decisionHandler(.download)
            return
        }
        // Transition typing for the observation schema (PRD §3.1).
        if navigationAction.targetFrame?.isMainFrame == true,
           let tab = store?.tab(for: webView) {
            tab.lastNavigationType = switch navigationAction.navigationType {
            case .linkActivated: "link"
            case .formSubmitted, .formResubmitted: "form"
            case .backForward: "back_forward"
            case .reload: "reload"
            default: "other"
            }
            if navigationAction.navigationType == .linkActivated,
               let destination = glanceDestination(for: navigationAction.request.url, from: tab) {
                store?.glanceURL = destination
                decisionHandler(.cancel)
                return
            }
        }
        // Hand non-web schemes (mailto:, app links from OAuth redirects) to the OS.
        if let url = navigationAction.request.url,
           let scheme = url.scheme?.lowercased(),
           !["http", "https", "about", "blob", "data", "file"].contains(scheme) {
            NSWorkspace.shared.open(url)
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationResponse: WKNavigationResponse,
        decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void
    ) {
        decisionHandler(navigationResponse.canShowMIMEType ? .allow : .download)
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        store?.downloads.adopt(download)
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        store?.downloads.adopt(download)
    }

    // MARK: - TLS failures → interstitial (PRD §4.1 negative states)

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        store?.tab(for: webView)?.certificateFailure = nil
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard let store, let tab = store.tab(for: webView) else { return }
        // Hibernation restore: put the page back where the user left it.
        tab.applyPendingScrollIfNeeded()

        // The one place live visits are observed (metadata only, consent-gated,
        // exclusions inside recordVisit — excluded sites leave nothing at all).
        if let url = webView.url {
            let transition = tab.transitionHint ?? tab.lastNavigationType
            tab.transitionHint = nil
            let context = store.observationContext(for: tab)
            store.observations.recordVisit(.init(
                url: url,
                title: webView.title ?? "",
                transition: transition,
                workspaceID: context.workspaceID,
                openDomains: context.openDomains
            ))

            // Real favicon for the rail glyph — in-memory only unless this
            // tab is Pinned/Favorited (see FaviconStore).
            webView.evaluateJavaScript(FaviconStore.discoveryScript) { result, _ in
                FaviconStore.shared.requestEphemeral(for: url, discoveredIconURLString: result as? String)
            }
        }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        let nsError = error as NSError
        guard nsError.domain == NSURLErrorDomain else { return }
        let reason: String?
        switch nsError.code {
        case NSURLErrorServerCertificateUntrusted:
            reason = "it isn't trusted by this Mac."
        case NSURLErrorServerCertificateHasBadDate:
            reason = "its dates are wrong — it may have expired."
        case NSURLErrorServerCertificateHasUnknownRoot:
            reason = "it was issued by an unknown authority."
        case NSURLErrorServerCertificateNotYetValid:
            reason = "it isn't valid yet."
        case NSURLErrorClientCertificateRejected, NSURLErrorClientCertificateRequired:
            reason = "the site rejected the connection's credentials."
        case NSURLErrorSecureConnectionFailed:
            reason = "the secure connection could not be established."
        default:
            reason = nil
        }
        if let reason,
           let tab = store?.tab(for: webView) {
            let host = (nsError.userInfo[NSURLErrorFailingURLErrorKey] as? URL)?.host()
                ?? webView.url?.host()
                ?? "The site"
            tab.certificateFailure = (host: host, reason: reason)
        }
    }

    // MARK: - File uploads (<input type="file"> → NSOpenPanel)

    func webView(
        _ webView: WKWebView,
        runOpenPanelWith parameters: WKOpenPanelParameters,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping ([URL]?) -> Void
    ) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = parameters.allowsDirectories
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        if let window = webView.window {
            panel.beginSheetModal(for: window) { response in
                completionHandler(response == .OK ? panel.urls : nil)
            }
        } else {
            completionHandler(panel.runModal() == .OK ? panel.urls : nil)
        }
    }

    // MARK: - JS panels

    func webView(
        _ webView: WKWebView,
        runJavaScriptAlertPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping () -> Void
    ) {
        let alert = NSAlert()
        alert.messageText = frame.securityOrigin.host
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
        completionHandler()
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptConfirmPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping (Bool) -> Void
    ) {
        let alert = NSAlert()
        alert.messageText = frame.securityOrigin.host
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        completionHandler(alert.runModal() == .alertFirstButtonReturn)
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptTextInputPanelWithPrompt prompt: String,
        defaultText: String?,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping (String?) -> Void
    ) {
        let alert = NSAlert()
        alert.messageText = frame.securityOrigin.host
        alert.informativeText = prompt
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = defaultText ?? ""
        alert.accessoryView = field
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        completionHandler(alert.runModal() == .alertFirstButtonReturn ? field.stringValue : nil)
    }
}
