import Foundation
import WebKit
import Observation

extension Notification.Name {
    static let downloadFinished = Notification.Name("sill.downloadFinished")
}

/// Tracks WKDownloads into ~/Downloads. Listed at the foot of the rail (D2a).
@MainActor
@Observable
final class DownloadsStore: NSObject {
    @Observable
    @MainActor
    final class Item: Identifiable {
        let id = UUID()
        var filename: String
        var destination: URL?
        var progress: Double = 0
        var state: State = .running
        var startedAt = Date()

        enum State: Equatable { case running, finished, failed(String) }

        init(filename: String) {
            self.filename = filename
        }
    }

    private(set) var items: [Item] = []
    @ObservationIgnored private var itemsByDownload = [ObjectIdentifier: Item]()
    @ObservationIgnored private var progressObservers = [ObjectIdentifier: NSKeyValueObservation]()

    func adopt(_ download: WKDownload) {
        download.delegate = self
    }

    private func item(for download: WKDownload) -> Item {
        let key = ObjectIdentifier(download)
        if let existing = itemsByDownload[key] { return existing }
        let item = Item(filename: "download")
        itemsByDownload[key] = item
        items.insert(item, at: 0)
        progressObservers[key] = download.progress.observe(\.fractionCompleted, options: [.new]) { [weak item] progress, _ in
            Task { @MainActor in item?.progress = progress.fractionCompleted }
        }
        return item
    }

    private func release(_ download: WKDownload) {
        let key = ObjectIdentifier(download)
        progressObservers[key]?.invalidate()
        progressObservers[key] = nil
        itemsByDownload[key] = nil
    }
}

extension DownloadsStore: WKDownloadDelegate {
    func download(
        _ download: WKDownload,
        decideDestinationUsing response: URLResponse,
        suggestedFilename: String,
        completionHandler: @escaping (URL?) -> Void
    ) {
        let item = item(for: download)
        let downloadsDirectory = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        var destination = downloadsDirectory.appendingPathComponent(suggestedFilename)
        // Never overwrite: suffix like Finder does.
        var attempt = 1
        let baseName = destination.deletingPathExtension().lastPathComponent
        let ext = destination.pathExtension
        while FileManager.default.fileExists(atPath: destination.path) {
            attempt += 1
            let suffixed = ext.isEmpty ? "\(baseName)-\(attempt)" : "\(baseName)-\(attempt).\(ext)"
            destination = downloadsDirectory.appendingPathComponent(suffixed)
        }
        item.filename = destination.lastPathComponent
        item.destination = destination
        completionHandler(destination)
    }

    func downloadDidFinish(_ download: WKDownload) {
        let item = item(for: download)
        item.state = .finished
        release(download)
        // The rail's "Downloads" count badge is the only other signal a
        // download happened at all — easy to miss entirely, same family of
        // gap as the header's existing "Copied"/"Saved to Desktop" toasts.
        NotificationCenter.default.post(name: .downloadFinished, object: nil, userInfo: ["filename": item.filename])
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        item(for: download).state = .failed(error.localizedDescription)
        release(download)
    }
}
