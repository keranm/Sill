import SwiftUI
import Sparkle

@main
struct SillApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var store: TabStore
    @Environment(\.openWindow) private var openWindow

    init() {
        SelfTest.runIfRequested()
        SelfTest.runEngineIfRequested()
        FontLoader.registerBundledFonts()
        _store = State(initialValue: TabStore(
            databasePath: BenchmarkRunner.databasePathOverride ?? DemoSeed.databasePathOverride
        ))
    }

    var body: some Scene {
        WindowGroup("Sill") {
            ShellView(store: store)
                .frame(minWidth: 980, minHeight: 640)
                .background(WindowConfigurator())
                .onAppear {
                    appDelegate.store = store
                    BenchmarkRunner.startIfRequested(store: store)
                    DemoSeed.startIfRequested(store: store)
                    store.observations.markActiveDayIfNeeded() // H5 proxy
                }
                .task {
                    // The engine runs on idle, at least daily (PRD §4.5).
                    try? await Task.sleep(for: .seconds(10))
                    while !Task.isCancelled {
                        if store.observations.isObserving {
                            LearningEngine.run(db: store.database)
                            store.patterns.refresh()
                        }
                        try? await Task.sleep(for: .seconds(12 * 3600))
                    }
                }
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Tab") {
                    store.focusRequestedTabID = store.newTab().id
                }
                .keyboardShortcut("t", modifiers: .command)

                Button("New Workspace…") {
                    NotificationCenter.default.post(name: .newWorkspace, object: nil)
                }
                .keyboardShortcut("n", modifiers: [.command, .shift])

                Button("New Quick Look") {
                    openWindow(value: QuickLookRequest())
                }
                .keyboardShortcut("n", modifiers: [.command, .option])

                Button("Close Tab") {
                    if store.glanceURL != nil {
                        store.glanceURL = nil
                    } else if let tab = store.selectedTab {
                        store.closeTab(tab)
                    }
                }
                .keyboardShortcut("w", modifiers: .command)
            }

            CommandGroup(after: .textEditing) {
                Button("Command Palette") {
                    NotificationCenter.default.post(name: .openPalette, object: nil)
                }
                .keyboardShortcut("k", modifiers: .command)
            }

            // Stopgap home for observation controls until the Learning page (M5)
            // gives pause/delete their permanent above-the-fold spot (PRD §3.4).
            CommandMenu("Learning") {
                Button("Open Learning Page") {
                    NotificationCenter.default.post(name: .openLearning, object: nil)
                }
                .keyboardShortcut("l", modifiers: [.command, .shift])

                Button(store.observations.isPaused ? "Resume Observation" : "Pause Observation") {
                    store.observations.setPaused(!store.observations.isPaused)
                }
                .disabled(store.observations.consent != .granted)

                Button("Import Browsing History…") {
                    NotificationCenter.default.post(name: .openImport, object: nil)
                }
                .disabled(store.observations.consent != .granted)

                Button("Export Aggregate Metrics…") {
                    exportMetrics(store: store)
                }
                .disabled(store.observations.consent != .granted)

                Divider()

                Button("Delete Everything Learned…") {
                    let alert = NSAlert()
                    alert.messageText = "Delete everything learned?"
                    alert.informativeText = "Every observation, pattern and suggestion record is erased from this Mac. Workspaces you created stay. This can't be undone."
                    alert.addButton(withTitle: "Keep it")
                    alert.addButton(withTitle: "Delete")
                    if alert.runModal() == .alertSecondButtonReturn {
                        store.observations.deleteEverything()
                    }
                }
            }

            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") {
                    appDelegate.updaterController.checkForUpdates(nil)
                }
            }

            CommandGroup(after: .help) {
                Button("Send Feedback…") {
                    store.newTab(url: URL(string: "https://keranmckenzie.com/feedback/"))
                }
            }

            CommandGroup(after: .toolbar) {
                Button("Open Location") {
                    NotificationCenter.default.post(name: .openGoTo, object: nil)
                }
                .keyboardShortcut("l", modifiers: .command)

                Button("Reload Page") {
                    store.selectedTab?.webView?.reload()
                }
                .keyboardShortcut("r", modifiers: .command)

                Button("Back") {
                    store.selectedTab?.webView?.goBack()
                }
                .keyboardShortcut("[", modifiers: .command)

                Button("Forward") {
                    store.selectedTab?.webView?.goForward()
                }
                .keyboardShortcut("]", modifiers: .command)

                Button("Copy Address") {
                    guard let urlString = store.selectedTab?.url?.absoluteString else { return }
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(urlString, forType: .string)
                    NotificationCenter.default.post(name: .urlCopied, object: nil)
                }
                .keyboardShortcut("c", modifiers: [.command, .shift])
                .disabled(store.selectedTab?.url == nil)
            }

            CommandMenu("Develop") {
                Button("Show Web Inspector") {
                    if store.selectedTab?.webView?.showInspector() != true {
                        showInspectorFallbackAlert()
                    }
                }
                .keyboardShortcut("i", modifiers: [.command, .option])
                .disabled(store.selectedTab?.webView == nil)

                Divider()

                Button("Capture Visible Area") {
                    guard let webView = store.selectedTab?.webView else { return }
                    Task { await PageCapture.captureVisibleArea(of: webView) }
                }
                .disabled(store.selectedTab?.webView == nil)

                Button("Capture Full Page") {
                    guard let webView = store.selectedTab?.webView else { return }
                    Task { await PageCapture.captureFullPage(of: webView) }
                }
                .disabled(store.selectedTab?.webView == nil)

                Divider()

                Button("New API Client Tab") {
                    store.newAPIClientTab()
                }
                .keyboardShortcut("r", modifiers: [.command, .option])

                Button("New MCP Explorer Tab") {
                    store.newMCPClientTab()
                }
                .keyboardShortcut("m", modifiers: [.command, .option])
            }

            CommandMenu("Favorites") {
                ForEach(Array(store.favorites.prefix(9).enumerated()), id: \.offset) { index, favorite in
                    Button(favorite.title.isEmpty ? (favorite.url.host() ?? "Favorite") : favorite.title) {
                        store.openFavorite(favorite)
                    }
                    .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
                }
            }
        }
        .windowStyle(.hiddenTitleBar)

        WindowGroup(for: QuickLookRequest.self) { $request in
            if let request {
                QuickLookView(store: store, initialURLString: request.initialURLString)
            }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 760, height: 620)
    }
}

/// Merges the title bar into the content so the traffic lights float directly
/// over the rail/header (D2a v2's frameless look) instead of a separate bar.
struct WindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.styleMask.insert(.fullSizeContentView)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// `showInspector()`'s private-API attempt (DeveloperTools.swift) has no
/// public fallback if WebKit ever renames the selectors it reaches for —
/// rather than a menu item that silently does nothing when that happens,
/// say so and point at the two paths that always work regardless of WebKit
/// internals: right-click, or Safari's own system-wide Develop menu.
@MainActor
private func showInspectorFallbackAlert() {
    let alert = NSAlert()
    alert.messageText = "Couldn't open the inspector directly"
    alert.informativeText = "Right-click anywhere on the page and choose \"Inspect Element\" — that always works. Or enable Safari's Develop menu (Safari > Settings > Advanced > \"Show features for web developers\"), which lists every inspectable app's tabs system-wide, Sill included."
    alert.addButton(withTitle: "OK")
    alert.runModal()
}

/// Explicit user action only, per PRD §4.9: no URLs, titles, or individual
/// timestamps — the file is safe to post publicly.
@MainActor
private func exportMetrics(store: TabStore) {
    let export = store.observations.exportAggregate()
    guard let data = try? JSONSerialization.data(withJSONObject: export, options: [.prettyPrinted, .sortedKeys]) else { return }
    let panel = NSSavePanel()
    panel.nameFieldStringValue = "sill-metrics.json"
    panel.allowedContentTypes = [.json]
    guard panel.runModal() == .OK, let url = panel.url else { return }
    try? data.write(to: url)
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor var store: TabStore?
    let updaterController = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: nil,
        userDriverDelegate: nil
    )

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Light mode first (PRD §8.1); tokens keep dark cheap for later.
        NSApp.appearance = NSAppearance(named: .aqua)
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated {
            store?.persistEverything()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
