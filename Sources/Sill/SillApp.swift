import SwiftUI
import Sparkle

@main
struct SillApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var store: TabStore

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
                    store.newTab()
                    NotificationCenter.default.post(name: .focusRailField, object: nil)
                }
                .keyboardShortcut("t", modifiers: .command)

                Button("New Workspace…") {
                    NotificationCenter.default.post(name: .newWorkspace, object: nil)
                }
                .keyboardShortcut("n", modifiers: [.command, .shift])

                Button("Close Tab") {
                    if let tab = store.selectedTab {
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
            }
        }
    }
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
