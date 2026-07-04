import Foundation

/// H4 harness (PRD §4.2): `Sill --benchmark-seed` loads 40 defined tabs across
/// 4 workspaces, hibernates 3 of them by ordinary workspace switching, then
/// touches /tmp/sill-benchmark-ready so scripts/benchmark.sh can measure RSS.
/// Runs against a throwaway database — never the real one.
@MainActor
enum BenchmarkRunner {
    static let readyFilePath = "/tmp/sill-benchmark-ready"

    /// 4 × 10 stable, login-free pages. `--print-benchmark-plan` emits this
    /// list so benchmark.sh drives Arc/Chrome with identical tabs.
    static let plan: [(name: String, urls: [String])] = [
        ("Reading", [
            "https://en.wikipedia.org/wiki/Web_browser",
            "https://en.wikipedia.org/wiki/WebKit",
            "https://en.wikipedia.org/wiki/Memory_management",
            "https://en.wikipedia.org/wiki/Sydney",
            "https://en.wikipedia.org/wiki/Coffee",
            "https://www.theguardian.com/international",
            "https://www.bbc.com/news",
            "https://news.ycombinator.com",
            "https://lobste.rs",
            "https://www.abc.net.au/news",
        ]),
        ("Docs", [
            "https://developer.mozilla.org/en-US/docs/Web/JavaScript",
            "https://developer.mozilla.org/en-US/docs/Web/CSS",
            "https://developer.apple.com/documentation/webkit",
            "https://developer.apple.com/documentation/swiftui",
            "https://www.swift.org/documentation/",
            "https://docs.python.org/3/",
            "https://doc.rust-lang.org/book/",
            "https://go.dev/doc/",
            "https://nodejs.org/docs/latest/api/",
            "https://www.postgresql.org/docs/current/",
        ]),
        ("Code", [
            "https://github.com/apple/swift",
            "https://github.com/WebKit/WebKit",
            "https://github.com/torvalds/linux",
            "https://github.com/rust-lang/rust",
            "https://github.com/python/cpython",
            "https://github.com/golang/go",
            "https://github.com/nodejs/node",
            "https://github.com/sqlite/sqlite",
            "https://github.com/git/git",
            "https://github.com/curl/curl",
        ]),
        ("Web", [
            "https://www.wikipedia.org",
            "https://duckduckgo.com",
            "https://www.apple.com",
            "https://www.mozilla.org/en-US/",
            "https://web.dev",
            "https://css-tricks.com",
            "https://www.smashingmagazine.com",
            "https://caniuse.com",
            "https://www.w3.org",
            "https://html.spec.whatwg.org",
        ]),
    ]

    static var isActive: Bool {
        CommandLine.arguments.contains("--benchmark-seed")
    }

    /// Throwaway DB for benchmark runs; also handles --print-benchmark-plan.
    static var databasePathOverride: String? {
        if CommandLine.arguments.contains("--print-benchmark-plan") {
            for group in plan {
                for url in group.urls { print(url) }
            }
            exit(0)
        }
        guard isActive else { return nil }
        let path = NSTemporaryDirectory() + "sill-benchmark.sqlite"
        try? FileManager.default.removeItem(atPath: path)
        try? FileManager.default.removeItem(atPath: path + "-wal")
        try? FileManager.default.removeItem(atPath: path + "-shm")
        try? FileManager.default.removeItem(atPath: readyFilePath)
        return path
    }

    static func startIfRequested(store: TabStore) {
        guard isActive else { return }
        Task { @MainActor in
            for group in plan {
                let workspace = store.createWorkspace(named: group.name)
                await store.switchWorkspace(to: workspace.id)
                for urlString in group.urls {
                    if let url = URL(string: urlString) {
                        store.newTab(url: url, select: false)
                    }
                }
                // Drop the blank tab each empty workspace is born with.
                for tab in store.tabs where tab.url == nil {
                    store.closeTab(tab)
                }
                store.selectedTabID = store.tabs.first?.id
                await waitForLoads(store)
            }
            // Ending on the last workspace leaves 3 of 4 hibernated.
            FileManager.default.createFile(atPath: readyFilePath, contents: Data("ready\n".utf8))
            NSLog("Sill benchmark: 40 tabs loaded, 3 workspaces hibernated, ready to measure")
        }
    }

    private static func waitForLoads(_ store: TabStore, timeout: TimeInterval = 60) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let stillLoading = store.tabs.contains { $0.isLoading }
            if !stillLoading {
                // Small settle so late subresources land before we move on.
                try? await Task.sleep(for: .seconds(3))
                return
            }
            try? await Task.sleep(for: .seconds(1))
        }
    }
}
