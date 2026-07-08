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

    /// Swagger UI exposes its own already-loaded spec URL via a stable,
    /// documented Redux-style selector — reading that directly is far more
    /// robust than trying to reverse-engineer wherever its config happens to
    /// live (inline script, external bundle, query-string override, ...).
    /// ReDoc's `<redoc>` custom element declares it as a plain attribute.
    /// Postman-published doc pages aren't covered — no comparably reliable
    /// signal for those was worth chasing for v1.
    private static let apiSpecURLDiscoveryScript = """
    (function () {
      try {
        if (window.ui && window.ui.specSelectors && window.ui.specSelectors.url) {
          var url = window.ui.specSelectors.url();
          if (url) return url;
        }
      } catch (e) {}
      var redoc = document.querySelector('redoc');
      if (redoc) {
        return redoc.getAttribute('spec-url') || redoc.getAttribute('specUrl') || null;
      }
      return null;
    })();
    """

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

    // MARK: - Context menu downloads

    /// WebKit's own "Download Linked File" / "Download Image" context-menu
    /// items don't actually do anything for a third-party host app — the
    /// item is present because WebKit puts it there unconditionally, but
    /// nothing wires it to a real download unless the host app does that
    /// itself. (Ordinary navigation-triggered downloads already work fine
    /// via the `WKNavigationDelegate`/`WKDownloadDelegate` pair below —
    /// this is a separate, WebKit-internal gap specific to the context
    /// menu, confirmed live: right-click download silently no-ops while a
    /// direct download link works.) Fixed the same way the Inspector menu
    /// item is (`DeveloperTools.swift`): a private, `responds(to:)`-style
    /// SPI hook — `_webView:getContextMenuFromProposedMenu:forElement:
    /// userInfo:completionHandler:` — to read the right-clicked link/image
    /// URL, then rewire just those two menu items to fire a real download
    /// through `WKWebView.startDownload(using:completionHandler:)`, which
    /// *is* public API and hands back an ordinary `WKDownload` that
    /// `DownloadsStore.adopt(_:)` already knows how to take from there.
    @objc(_webView:getContextMenuFromProposedMenu:forElement:userInfo:completionHandler:)
    func webView(
        _ webView: WKWebView,
        getContextMenuFromProposedMenu menu: NSMenu,
        forElement element: AnyObject,
        userInfo: AnyObject?,
        completionHandler: @escaping (NSMenu?) -> Void
    ) {
        guard let hitTestResult = element.value(forKey: "hitTestResult") as? NSObject else {
            completionHandler(menu)
            return
        }
        let linkURL = hitTestResult.value(forKey: "absoluteLinkURL") as? URL
        let imageURL = hitTestResult.value(forKey: "absoluteImageURL") as? URL
        for item in menu.items {
            let url: URL?
            switch item.identifier?.rawValue {
            case "WKMenuItemIdentifierDownloadLinkedFile": url = linkURL
            case "WKMenuItemIdentifierDownloadImage": url = imageURL
            default: continue
            }
            guard let url else { continue }
            let action = MenuDownloadAction { [weak self, weak webView] in
                guard let webView else { return }
                webView.startDownload(using: URLRequest(url: url)) { [weak self] download in
                    self?.store?.downloads.adopt(download)
                }
            }
            // Retained by the menu item for exactly as long as it might be
            // clicked; nothing else needs to keep this alive.
            item.representedObject = action
            item.target = action
            item.action = #selector(MenuDownloadAction.fire(_:))
        }

        // "Open in API Client" on any right-clicked link — a spec link
        // (swagger.json and friends) imports as a collection, anything else
        // lands prefilled as a GET, via TabStore.openInAPIClient.
        if let linkURL {
            let openItem = NSMenuItem(title: "Open in API Client", action: #selector(MenuDownloadAction.fire(_:)), keyEquivalent: "")
            let action = MenuDownloadAction { [weak self] in
                self?.store?.openInAPIClient(url: linkURL)
            }
            openItem.representedObject = action
            openItem.target = action
            // Sits with the other link actions, right after Copy Link.
            let copyLinkIndex = menu.items.firstIndex { $0.identifier?.rawValue == "WKMenuItemIdentifierCopyLink" }
            menu.insertItem(openItem, at: copyLinkIndex.map { $0 + 1 } ?? menu.items.count)
        }
        completionHandler(menu)
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

        // developer-tools.md #3 collections: re-detected fresh on every
        // navigation, since a JSON page is likely to be a spec file only
        // some of the time this tab is used for anything at all.
        tab.detectedAPICollection = nil
        tab.detectionTask?.cancel()
        // Captured now so a slow detection from this navigation can't land
        // after the user has already moved on and overwrite whatever the
        // next (or a since-cleared) navigation set — checked again before
        // every assignment below.
        let detectionURL = webView.url
        webView.evaluateJavaScript("document.contentType") { [weak tab, weak webView] result, _ in
            guard let tab, let webView else { return }
            if result as? String == "application/json" {
                // JSONFormatting's WKUserScript may already have rewritten
                // document.body for display by the time this runs, so it
                // stashes the original text for exactly this reader rather
                // than leaving it to be read back out of the mutated DOM.
                webView.evaluateJavaScript("window.__sillRawJSON || (document.body ? document.body.textContent : '')") { body, _ in
                    guard webView.url == detectionURL,
                          let text = body as? String, let data = text.data(using: .utf8),
                          let json = try? JSONSerialization.jsonObject(with: data) else { return }
                    let name = webView.url?.deletingPathExtension().lastPathComponent ?? "Imported API"
                    tab.detectedAPICollection = APISpecParser.detect(json, name: name, sourceURL: webView.url)
                }
            } else {
                // Cheap synchronous pre-check first: almost every page is
                // neither Swagger UI nor ReDoc, so skip the 800ms SPA-init
                // wait (and its own JS eval) unless a trace of either is
                // already in the DOM.
                webView.evaluateJavaScript("!!(window.ui || document.querySelector('redoc'))") { [weak tab, weak webView] present, _ in
                    guard let tab, let webView, webView.url == detectionURL,
                          present as? Bool == true else { return }
                    // Might be a rendered Swagger UI / ReDoc docs page rather
                    // than the raw spec — these are JS SPAs that need a moment
                    // to actually initialize before their spec URL is
                    // discoverable, hence the delay rather than checking
                    // immediately.
                    tab.detectionTask = Task { @MainActor [weak tab, weak webView] in
                        try? await Task.sleep(for: .milliseconds(800))
                        guard !Task.isCancelled,
                              let tab, let webView, webView.url == detectionURL,
                              let discovered = try? await webView.evaluateJavaScript(Self.apiSpecURLDiscoveryScript) as? String,
                              let specURL = URL(string: discovered, relativeTo: webView.url)?.absoluteURL else { return }
                        guard let (data, response) = try? await URLSession.shared.data(from: specURL),
                              (response as? HTTPURLResponse)?.statusCode == 200,
                              let json = try? JSONSerialization.jsonObject(with: data),
                              webView.url == detectionURL else { return }
                        let name = webView.url?.host() ?? "Imported API"
                        tab.detectedAPICollection = APISpecParser.detect(json, name: name, sourceURL: specURL)
                    }
                }
            }
        }

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

/// `NSMenuItem.action` needs a real target/selector — this just lets the
/// context-menu download fix (above) hand it an ordinary Swift closure.
private final class MenuDownloadAction: NSObject {
    private let handler: () -> Void

    init(_ handler: @escaping () -> Void) {
        self.handler = handler
    }

    @objc func fire(_ sender: Any?) {
        handler()
    }
}
