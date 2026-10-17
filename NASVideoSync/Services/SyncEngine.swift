import Foundation
import Network
import os
import Observation
import UIKit

enum SyncTrigger: String, Sendable {
    case manual = "Manual"
    case charging = "Charging"
    case location = "Arrived home"
    case shortcut = "Shortcut"
}

struct SyncSummary: Sendable {
    var uploaded = 0
    var remaining = 0
    var skippedReason: String? = nil
    var error: String? = nil

    var message: String {
        if let error { return "Failed: \(error)" }
        if let skippedReason { return skippedReason }
        if uploaded == 0 && remaining == 0 { return "All videos are on the NAS." }
        var text = "Transferred \(uploaded) video\(uploaded == 1 ? "" : "s")."
        if remaining > 0 { text += " \(remaining) left, will continue next time." }
        return text
    }
}

/// Orchestrates a sync run. One run at a time; concurrent callers (e.g. a Shortcut firing while a
/// charging task is running) join the in-flight run instead of starting a second one.
///
/// Uploads are resumable: each video is written to `<name>.part` in 8 MB chunks and renamed when
/// complete, so a background window that ends mid-file resumes from the same offset next time.
@MainActor
@Observable
final class SyncEngine {
    static let shared = SyncEngine()

    enum Phase: Equatable {
        case idle
        case preparing
        case exporting(String)
        case uploading(String, Double)
    }

    private(set) var phase: Phase = .idle
    private(set) var pendingCount: Int?
    private(set) var syncedCount = 0
    /// Uploaded and verified-on-NAS videos still on the phone (only tracked when delete-after-upload is on).
    private(set) var awaitingDeletion = 0
    private(set) var isDeleting = false
    private(set) var lastSummary: String?
    private(set) var lastRun: Date?
    private(set) var lastTrigger: SyncTrigger?

    private var currentRun: Task<SyncSummary, Never>?

    /// Overall progress for the system's continued-processing UI: (file name, 0...1, files done, files total).
    var onProgress: ((String, Double, Int, Int) -> Void)?
    private var runDone = 0
    private var runTotal = 0

    var isRunning: Bool { currentRun != nil }

    private init() {
        let defaults = UserDefaults.standard
        lastSummary = defaults.string(forKey: "lastSummary")
        lastRun = defaults.object(forKey: "lastRun") as? Date
        lastTrigger = defaults.string(forKey: "lastTrigger").flatMap(SyncTrigger.init(rawValue:))
    }

    @discardableResult
    func sync(trigger: SyncTrigger) async -> SyncSummary {
        if let currentRun { return await currentRun.value }
        let run = Task { await self.perform() }
        currentRun = run
        let summary = await run.value
        currentRun = nil
        phase = .idle
        lastSummary = summary.message
        lastRun = .now
        lastTrigger = trigger
        let defaults = UserDefaults.standard
        defaults.set(summary.message, forKey: "lastSummary")
        defaults.set(lastRun, forKey: "lastRun")
        defaults.set(trigger.rawValue, forKey: "lastTrigger")
        await refreshCounts()
        if summary.uploaded > 0 {
            await removeSyncedFromPhone()
        }
        return summary
    }

    /// Starts a sync from the UI. On iOS 26+ it runs as a continued-processing task, so it keeps going
    /// with the screen off or the app closed. Older iOS gets ~30 s after leaving the app.
    func syncFromForeground() {
        if #available(iOS 26.0, *), BackgroundScheduler.startContinuedSync() { return }
        let app = UIApplication.shared
        var bgTask = UIBackgroundTaskIdentifier.invalid
        bgTask = app.beginBackgroundTask(withName: "VideoSync") { [weak self] in
            self?.cancel()
        }
        Task {
            await sync(trigger: .manual)
            app.endBackgroundTask(bgTask)
        }
    }

    func cancel() {
        currentRun?.cancel()
    }

    func refreshCounts() async {
        guard VideoLibrary.hasAccess else { return }
        let since = SyncSettings.load().syncSince
        let items = await Task.detached { VideoLibrary.videos(since: since) }.value
        var pending = 0
        for item in items where await !SyncLedger.shared.contains(item.id) { pending += 1 }
        pendingCount = pending
        syncedCount = await SyncLedger.shared.count
        if SyncSettings.load().deleteAfterUpload {
            let ids = Array(await SyncLedger.shared.all.keys)
            awaitingDeletion = await Task.detached { VideoLibrary.existing(ids).count }.value
        } else {
            awaitingDeletion = 0
        }
    }

    // MARK: - Delete after upload

    /// Deletes uploaded videos from the phone, after re-checking each one is on the NAS at full size.
    /// Only possible in the foreground (iOS shows a confirmation), so background uploads queue up
    /// here until the app is next opened. Pass `force` for the explicit button (prompts even if the
    /// user previously declined).
    func removeSyncedFromPhone(force: Bool = false) async {
        let settings = SyncSettings.load()
        guard settings.deleteAfterUpload, !isDeleting, currentRun == nil,
              UIApplication.shared.applicationState == .active
        else { return }

        // Don't re-prompt on every launch after a "Don't Allow"; wait for new uploads.
        let defaults = UserDefaults.standard
        let lastUpload = await SyncLedger.shared.lastSyncDate ?? .distantPast
        if !force, let declinedAt = defaults.object(forKey: "deletionDeclinedAt") as? Date, declinedAt > lastUpload {
            return
        }

        let entries = await SyncLedger.shared.all
        let onPhone = await Task.detached { VideoLibrary.existing(Array(entries.keys)) }.value
        guard !onPhone.isEmpty else { return }

        isDeleting = true
        defer { isDeleting = false }

        var verified: [String] = []
        do {
            let client = try NASClient(settings: settings)
            try await client.connect()
            for id in onPhone {
                guard let entry = entries[id] else { continue }
                if await client.size(of: entry.remotePath) == entry.bytes { verified.append(id) }
            }
            await client.disconnect()
        } catch {
            lastSummary = "Couldn't verify uploads on the NAS, nothing deleted: \(error.localizedDescription)"
            return
        }
        guard !verified.isEmpty else { return }

        do {
            try await VideoLibrary.delete(verified)
            defaults.removeObject(forKey: "deletionDeclinedAt")
            lastSummary = "Removed \(verified.count) synced video\(verified.count == 1 ? "" : "s") from iPhone (in Recently Deleted for 30 days)."
        } catch {
            defaults.set(Date.now, forKey: "deletionDeclinedAt")
        }
        await refreshCounts()
    }

    // MARK: - Run

    private func perform() async -> SyncSummary {
        let settings = SyncSettings.load()
        guard settings.isConfigured else { return SyncSummary(skippedReason: "Not set up yet: open Settings.") }
        guard VideoLibrary.hasAccess else { return SyncSummary(skippedReason: "No access to Photos.") }
        if settings.wifiOnly, await !NetworkStatus.isOnWiFi() {
            return SyncSummary(skippedReason: "Skipped: not on Wi-Fi.")
        }

        phase = .preparing
        let items = await Task.detached { VideoLibrary.videos(since: settings.syncSince) }.value
        var pending: [VideoItem] = []
        for item in items where await !SyncLedger.shared.contains(item.id) { pending.append(item) }
        var summary = SyncSummary(remaining: pending.count)
        guard !pending.isEmpty else { return summary }
        runTotal = pending.count
        runDone = 0

        let client: NASClient
        do {
            client = try NASClient(settings: settings)
            try await client.connect()
        } catch {
            summary.error = error.localizedDescription
            return summary
        }

        for item in pending {
            if Task.isCancelled { break }
            do {
                try await upload(item, using: client, settings: settings)
                summary.uploaded += 1
                runDone += 1
                summary.remaining -= 1
            } catch is CancellationError {
                break
            } catch {
                summary.error = "\(item.originalFilename): \(error.localizedDescription)"
                break
            }
        }
        await client.disconnect()
        return summary
    }

    private func upload(_ item: VideoItem, using client: NASClient, settings: SyncSettings) async throws {
        let folder = Self.remoteFolder(for: item, settings: settings)
        let finalPath = folder.isEmpty ? Self.remoteName(for: item) : "\(folder)/\(Self.remoteName(for: item))"
        let partPath = finalPath + ".part"

        // Already there (e.g. after reinstalling the app): just record it.
        if let existing = await client.size(of: finalPath) {
            await SyncLedger.shared.record(item.id, remotePath: finalPath, bytes: existing)
            return
        }

        let name = item.originalFilename
        phase = .exporting(name)
        report(name, 0)
        // Export (incl. iCloud download) counts as the first 20% of a file, upload as the rest.
        let localURL = try await VideoLibrary.exportedFile(for: item) { fraction in
            Task { @MainActor in self.report(name, 0.2 * fraction) }
        }
        let totalBytes = (try FileManager.default.attributesOfItem(atPath: localURL.path)[.size] as? NSNumber)?.int64Value ?? 0

        try await client.ensureDirectory(folder)
        var offset = await client.size(of: partPath) ?? 0
        if offset > totalBytes { offset = 0 }

        let handle = try FileHandle(forReadingFrom: localURL)
        defer { try? handle.close() }
        let chunkSize = 8 * 1024 * 1024

        phase = .uploading(name, totalBytes > 0 ? Double(offset) / Double(totalBytes) : 0)
        report(name, 0.2)
        if offset == 0 {
            // Fresh (or reset) .part file; chunk writes below require it to exist.
            try await client.createEmptyFile(partPath)
        }
        while offset < totalBytes {
            try Task.checkCancellation()
            let chunk: Data = try await Task.detached { [offset] in
                try handle.seek(toOffset: UInt64(offset))
                return try handle.read(upToCount: chunkSize) ?? Data()
            }.value
            if chunk.isEmpty { break }
            try await client.write(chunk, to: partPath, at: offset)
            offset += Int64(chunk.count)
            let fraction = Double(offset) / Double(totalBytes)
            phase = .uploading(name, fraction)
            report(name, 0.2 + 0.8 * fraction)
        }

        guard await client.size(of: partPath) == totalBytes else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSLocalizedDescriptionKey: "Size mismatch after upload"])
        }
        try await client.move(partPath, to: finalPath)
        await SyncLedger.shared.record(item.id, remotePath: finalPath, bytes: totalBytes)
        VideoLibrary.discardExport(localURL)
    }

    private func report(_ name: String, _ fileFraction: Double) {
        guard runTotal > 0 else { return }
        let overall = (Double(runDone) + min(fileFraction, 1)) / Double(runTotal)
        onProgress?(name, overall, runDone, runTotal)
    }

    // MARK: - Naming

    /// <base>/<yyyy>/<yyyy-MM>
    nonisolated static func remoteFolder(for item: VideoItem, settings: SyncSettings) -> String {
        let base = settings.baseFolder.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        guard settings.subfoldersByDate else { return base }
        let year = format(item.creationDate, "yyyy")
        let month = format(item.creationDate, "yyyy-MM")
        return [base, year, month].filter { !$0.isEmpty }.joined(separator: "/")
    }

    /// 2026-10-15_143012_IMG_1234.MOV — the timestamp keeps IMG_xxxx counter wraparounds from colliding.
    nonisolated static func remoteName(for item: VideoItem) -> String {
        "\(format(item.creationDate, "yyyy-MM-dd_HHmmss"))_\(item.originalFilename)"
    }

    private nonisolated static func format(_ date: Date, _ pattern: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = pattern
        return formatter.string(from: date)
    }
}

enum NetworkStatus {
    static func isOnWiFi() async -> Bool {
        await withCheckedContinuation { continuation in
            let monitor = NWPathMonitor()
            let queue = DispatchQueue(label: "NetworkStatus")
            let resumed = OSAllocatedUnfairLock(initialState: false)
            monitor.pathUpdateHandler = { path in
                let first = resumed.withLock { done in
                    defer { done = true }
                    return !done
                }
                guard first else { return }
                monitor.cancel()
                continuation.resume(returning: path.status == .satisfied && path.usesInterfaceType(.wifi))
            }
            monitor.start(queue: queue)
        }
    }
}
