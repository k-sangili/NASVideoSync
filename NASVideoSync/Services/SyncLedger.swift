import Foundation

/// Remembers which assets have been fully transferred, so each video is sent once.
actor SyncLedger {
    static let shared = SyncLedger()

    struct Entry: Codable {
        let remotePath: String
        let bytes: Int64
        let syncedAt: Date
    }

    private var entries: [String: Entry]
    private let fileURL: URL

    private init() {
        let dir = (try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        fileURL = dir.appendingPathComponent("sync-ledger.json")
        entries = (try? JSONDecoder().decode([String: Entry].self, from: Data(contentsOf: fileURL))) ?? [:]
    }

    func contains(_ id: String) -> Bool { entries[id] != nil }

    var all: [String: Entry] { entries }

    var count: Int { entries.count }

    var lastSyncDate: Date? { entries.values.map(\.syncedAt).max() }

    func record(_ id: String, remotePath: String, bytes: Int64) {
        entries[id] = Entry(remotePath: remotePath, bytes: bytes, syncedAt: .now)
        persist()
    }

    func reset() {
        entries = [:]
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}
