import WebKit
import Observation

/// One tab. May be *materialized* (owns a live WKWebView) or *dormant*
/// (snapshot only: URL, title, scroll — the hibernation state, PRD §4.2).
/// Dormant tabs cost almost nothing; the WebContent process is gone.
@MainActor
@Observable
final class BrowserTab: Identifiable {
    let id: UUID
    private(set) var webView: WKWebView?

    private(set) var title: String
    private(set) var url: URL?
    private(set) var canGoBack = false
    private(set) var canGoForward = false
    private(set) var isLoading = false
    private(set) var hasOnlySecureContent = true

    /// Scroll position to restore after the next load finishes.
    var pendingScrollY: Double
    /// Set by the navigation delegate on TLS/cert failure; drives the interstitial.
    var certificateFailure: (host: String, reason: String)?
    /// Transition typing for observation: "typed" when the load came from our
    /// go-to fields; otherwise the delegate maps WKNavigationType.
    @ObservationIgnored var transitionHint: String?
    @ObservationIgnored var lastNavigationType: String = "other"

    var isMaterialized: Bool { webView != nil }

    @ObservationIgnored private let onStateChange: () -> Void
    @ObservationIgnored private var observers: [NSKeyValueObservation] = []

    init(
        id: UUID = UUID(),
        url: URL? = nil,
        title: String = "New Tab",
        scrollY: Double = 0,
        onStateChange: @escaping () -> Void
    ) {
        self.id = id
        self.url = url
        self.title = title
        self.pendingScrollY = scrollY
        self.onStateChange = onStateChange
    }

    // MARK: Materialize / dehydrate

    /// Brings the tab to life in the given webview and loads its snapshot URL.
    func materialize(webView: WKWebView) {
        guard self.webView == nil else { return }
        self.webView = webView
        observeWebView(webView)
        if let url {
            webView.load(URLRequest(url: url))
        }
    }

    /// Hibernation: capture scroll, then release the webview (and with it the
    /// WebContent process). Snapshot fields survive on the tab itself.
    func dehydrate() async {
        guard let webView else { return }
        if let result = try? await webView.evaluateJavaScript("window.scrollY"),
           let scrollY = result as? Double {
            pendingScrollY = scrollY
        } else if let scrollY = try? await webView.evaluateJavaScript("window.scrollY") as? NSNumber {
            pendingScrollY = scrollY.doubleValue
        }
        observers = []
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        webView.removeFromSuperview()
        self.webView = nil
        certificateFailure = nil
        isLoading = false
    }

    /// Called by the navigation delegate when a load finishes.
    func applyPendingScrollIfNeeded() {
        guard pendingScrollY > 0, let webView else { return }
        let y = pendingScrollY
        pendingScrollY = 0
        webView.evaluateJavaScript("window.scrollTo(0, \(y))", completionHandler: nil)
    }

    func load(_ url: URL) {
        if let webView {
            webView.load(URLRequest(url: url))
        } else {
            self.url = url
        }
    }

    // MARK: Derived display

    var securityState: SecurityState {
        if let failure = certificateFailure {
            return .certificateFailure(host: failure.host, reason: failure.reason)
        }
        guard let url, let scheme = url.scheme?.lowercased() else { return .blank }
        switch scheme {
        case "https":
            return hasOnlySecureContent ? .secure : .mixedContent
        case "http":
            return .insecureHTTP
        default:
            return .blank
        }
    }

    /// No-network favicon stand-in (PRD §3.2 bans our own fetches; the D2a
    /// mocks use letter chips).
    var glyphLetter: String {
        guard let host = url?.host() else { return "•" }
        let domain = HostDisplay.registrableDomain(of: host)
        return domain.first.map { String($0).uppercased() } ?? "•"
    }

    // MARK: WebView state mirroring

    private func observeWebView(_ webView: WKWebView) {
        observers = [
            webView.observe(\.title, options: [.initial, .new]) { [weak self] view, _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if let title = view.title, !title.isEmpty {
                        self.title = title
                    } else if let host = view.url?.host() {
                        self.title = host
                    }
                }
            },
            webView.observe(\.url, options: [.initial, .new]) { [weak self] view, _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if let url = view.url {
                        self.url = url
                    }
                    self.onStateChange()
                }
            },
            webView.observe(\.canGoBack, options: [.initial, .new]) { [weak self] view, _ in
                MainActor.assumeIsolated { self?.canGoBack = view.canGoBack }
            },
            webView.observe(\.canGoForward, options: [.initial, .new]) { [weak self] view, _ in
                MainActor.assumeIsolated { self?.canGoForward = view.canGoForward }
            },
            webView.observe(\.isLoading, options: [.initial, .new]) { [weak self] view, _ in
                MainActor.assumeIsolated { self?.isLoading = view.isLoading }
            },
            webView.observe(\.hasOnlySecureContent, options: [.initial, .new]) { [weak self] view, _ in
                MainActor.assumeIsolated { self?.hasOnlySecureContent = view.hasOnlySecureContent }
            },
        ]
    }
}
