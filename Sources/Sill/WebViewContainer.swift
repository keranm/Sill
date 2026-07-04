import SwiftUI
import WebKit

/// Hosts a tab's WKWebView. The parent view applies `.id(tab.id)` so each tab
/// keeps its own NSView identity across tab switches.
struct WebViewContainer: NSViewRepresentable {
    let webView: WKWebView

    func makeNSView(context: Context) -> WKWebView {
        webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}
}
