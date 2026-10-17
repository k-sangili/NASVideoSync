import AppIntents

/// Shortcuts action, like PhotoSync's "Transfer new photos / videos". Pair it with a Shortcuts
/// personal automation (e.g. "When I join <home Wi-Fi>" or "When charger is connected") to run it hands-free.
struct SyncVideosIntent: AppIntent {
    static let title: LocalizedStringResource = "Transfer New Videos to NAS"
    static let description = IntentDescription("Copies videos that aren't on your TrueNAS yet.")
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let summary = await SyncEngine.shared.sync(trigger: .shortcut)
        return .result(dialog: "\(summary.message)")
    }
}

struct NASVideoSyncShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: SyncVideosIntent(),
            phrases: [
                "Sync videos with \(.applicationName)",
                "Transfer new videos with \(.applicationName)",
            ],
            shortTitle: "Sync Videos",
            systemImageName: "arrow.up.to.line.circle")
    }
}
