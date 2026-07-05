import SwiftUI

/// Real favicons — an explicit, owner-approved deviation from PRD §3.2's
/// "zero network calls of our own" (the same kind of exception granted for
/// the content blocker in M3). Every materialized tab gets a best-effort,
/// in-memory-only fetch; only Pinned/Favorited tabs persist to disk, so a
/// site you never stick with costs nothing across relaunches. Never blocks or
/// retries within a run — a failed or pending lookup just falls back to
/// GlyphView's letter chip.
@MainActor
@Observable
final class FaviconStore {
    static let shared = FaviconStore()

    /// The page's own `<link rel="icon">`, read via JS against an
    /// already-loaded webview — not a new request in itself.
    static let discoveryScript = """
        (function(){
          var l = document.querySelector('link[rel~="icon"]');
          return l ? l.href : null;
        })();
        """

    private(set) var images: [String: NSImage] = [:]
    private var attempted: Set<String> = []
    private let directory: URL

    private init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Sill/Favicons", isDirectory: true)
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        directory = support
    }

    /// Read-only lookup for GlyphView; loads from the on-disk cache (Pinned/
    /// Favorited) if present, but never triggers a fetch itself.
    func image(for url: URL?) -> NSImage? {
        guard let host = url?.host() else { return nil }
        let domain = HostDisplay.registrableDomain(of: host)
        if let cached = images[domain] { return cached }
        guard let image = NSImage(contentsOf: diskPath(for: domain)) else { return nil }
        images[domain] = image
        return image
    }

    /// Best-effort glyph upgrade for any tab that finishes loading — in-memory
    /// only, never written to disk. One attempt per domain per run.
    func requestEphemeral(for pageURL: URL?, discoveredIconURLString: String? = nil) {
        guard let host = pageURL?.host() else { return }
        let domain = HostDisplay.registrableDomain(of: host)
        guard images[domain] == nil, !attempted.contains(domain) else { return }
        attempted.insert(domain)
        fetch(domain: domain, discoveredIconURLString: discoveredIconURLString, persist: false)
    }

    /// Called when the owner pins or favorites a tab — persists to disk so it
    /// survives relaunch even for a site not revisited that session.
    func fetchAndCache(for pageURL: URL, discoveredIconURLString: String? = nil) {
        guard let host = pageURL.host() else { return }
        let domain = HostDisplay.registrableDomain(of: host)
        guard !FileManager.default.fileExists(atPath: diskPath(for: domain).path) else { return }
        attempted.insert(domain)
        fetch(domain: domain, discoveredIconURLString: discoveredIconURLString, persist: true)
    }

    private func diskPath(for domain: String) -> URL {
        directory.appendingPathComponent("\(domain).png")
    }

    private func fetch(domain: String, discoveredIconURLString: String?, persist: Bool) {
        guard let candidate = discoveredIconURLString.flatMap(URL.init(string:))
            ?? URL(string: "https://\(domain)/favicon.ico") else { return }

        Task {
            guard let (data, response) = try? await URLSession.shared.data(from: candidate),
                  let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let image = NSImage(data: data) else { return }
            images[domain] = image
            guard persist,
                  let tiff = image.tiffRepresentation,
                  let rep = NSBitmapImageRep(data: tiff),
                  let pngData = rep.representation(using: .png, properties: [:]) else { return }
            try? pngData.write(to: diskPath(for: domain))
        }
    }
}
