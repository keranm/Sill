import AppKit
import WebKit

extension Notification.Name {
    static let pageCaptured = Notification.Name("sill.pageCaptured")
}

/// developer-tools.md #2 — Page capture. A core toolbar feature, not
/// developer-gated: full-page and visible-area capture, both always
/// available. Built as a standalone service (not tucked inside a view) so a
/// later MCP `capture_page` tool (§4.10) can call the exact same function —
/// two entry points, one capability.
///
/// Full-page capture resizes the *live* webview to its full scroll height in
/// place before snapshotting, then restores it — deliberately not a hidden
/// reload in a detached webview, because that would lose whatever the page
/// is actually showing right now (scroll-triggered lazy content, SPA state,
/// filled-in form fields), which is the entire point of capturing "this
/// page" rather than "this URL fetched fresh." Known limitation, not solved
/// here: `position: fixed`/`sticky` elements (headers, cookie banners) can
/// appear duplicated down a tall capture, the same problem GoFullPage-style
/// extensions solve with viewport-stitching — accepted for v1 rather than
/// building that.
@MainActor
enum PageCapture {
    static func captureVisibleArea(of webView: WKWebView) async {
        guard let image = await snapshot(of: webView) else { return }
        save(image)
    }

    static func captureFullPage(of webView: WKWebView) async {
        let originalFrame = webView.frame
        defer { webView.frame = originalFrame }

        guard let contentHeight = await scrollHeight(of: webView), contentHeight > originalFrame.height else {
            // Already showing the whole page (or couldn't measure it) —
            // the visible-area snapshot is already the full page.
            await captureVisibleArea(of: webView)
            return
        }

        webView.frame = CGRect(origin: originalFrame.origin, size: CGSize(width: originalFrame.width, height: contentHeight))
        // WebKit needs a layout pass to actually render the newly-revealed
        // content before a snapshot of it means anything.
        try? await Task.sleep(for: .milliseconds(200))
        guard let image = await snapshot(of: webView) else { return }
        save(image)
    }

    private static func scrollHeight(of webView: WKWebView) async -> CGFloat? {
        guard let result = try? await webView.evaluateJavaScript("document.documentElement.scrollHeight"),
              let number = result as? NSNumber else { return nil }
        return CGFloat(truncating: number)
    }

    private static func snapshot(of webView: WKWebView) async -> NSImage? {
        await withCheckedContinuation { continuation in
            webView.takeSnapshot(with: nil) { image, _ in
                continuation.resume(returning: image)
            }
        }
    }

    private static func save(_ image: NSImage) {
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else { return }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let filename = "Sill Capture \(formatter.string(from: Date())).png"
        let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0]
        let url = desktop.appendingPathComponent(filename)
        try? png.write(to: url)
        NotificationCenter.default.post(name: .pageCaptured, object: nil)
    }
}
