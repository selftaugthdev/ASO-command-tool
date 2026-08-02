import SwiftUI
import ASOStore

@main
struct ASOCommandCenterApp: App {
    @State private var state: AppState
    @State private var startupError: String?

    init() {
        do {
            let store = try ASOStore.standard()
            _state = State(initialValue: AppState(store: store))
        } catch {
            // Falling back to memory keeps the window usable so the user can see
            // what went wrong instead of getting a silent launch failure.
            let fallback = try! ASOStore(database: try! Database())
            _state = State(initialValue: AppState(store: fallback))
            _startupError = State(initialValue:
                "Could not open the local database, running in memory only. "
                + "Nothing will be saved. (\(error.localizedDescription))")
        }
    }

    var body: some Scene {
        Window("ASO Command Center", id: "main") {
            ContentView()
                .environment(state)
                .frame(minWidth: 1100, minHeight: 700)
                .task {
                    if let startupError { state.report(.error, startupError) }
                    // One-shot repair for lists imported before sentinel ranks
                    // were filtered, which showed a fake #1000 on every
                    // unranked keyword.
                    if let repaired = try? state.store.clearSentinelRanks(), repaired > 0 {
                        state.reloadKeywords()
                        state.report(.info,
                            "Cleared \(repaired) placeholder rank(s) from an import. "
                          + "Those keywords show as unranked until you run Refresh Ranks.")
                    }
                    // Sampled here, after the window exists, never in the scene
                    // body: a Keychain prompt raised before the first draw
                    // leaves the app running with no window.
                    await state.refreshCredentialStatus()
                }
        }
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("ASO") {
                Button("Pull Metadata") { Task { await state.pullMetadata() } }
                    .keyboardShortcut("r", modifiers: [.command])
                    .disabled(state.selectedApp == nil || !state.hasASCCredentials)
                Button("Refresh Ranks") { Task { await state.refreshRanks() } }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                    .disabled(state.selectedApp == nil)
                Divider()
                Button("Sync Search Ads Spend") { Task { await state.syncSpend() } }
                    .disabled(!state.hasASACredentials)
                Button("Sync Revenue") { Task { await state.syncRevenue() } }
                    .disabled(!state.hasFirebaseCredentials)
            }
        }
    }
}
