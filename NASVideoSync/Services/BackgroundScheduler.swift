import BackgroundTasks
import Foundation

/// "When charging" trigger: a BGProcessingTask that iOS runs while the phone is plugged in and online,
/// typically overnight. These windows are long (minutes), so this is where most big videos get sent.
enum BackgroundScheduler {
    static let chargingTaskID = "com.kamesh.NASVideoSync.charging-sync"

    /// Wildcard family for user-started uploads (iOS 26 continued processing); each submit appends a UUID.
    static let uploadTaskPrefix = "com.kamesh.NASVideoSync.upload"

    /// Must be called before the app finishes launching.
    static func register() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: chargingTaskID, using: nil) { task in
            guard let task = task as? BGProcessingTask else { return }
            handle(task)
        }
    }

    /// Starts "Sync Now" as a continued-processing task: it keeps running with the screen off or
    /// after leaving the app, with progress shown by the system. Returns false if iOS refused it.
    @available(iOS 26.0, *)
    static func startContinuedSync() -> Bool {
        // The ".*" wildcard is only for Info.plist; the handler must be registered under the exact
        // identifier being submitted, at submit time (continued-processing tasks allow late registration).
        let identifier = "\(uploadTaskPrefix).\(UUID().uuidString)"
        let registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: nil) { task in
            guard let task = task as? BGContinuedProcessingTask else {
                task.setTaskCompleted(success: false)
                return
            }
            handleContinued(task)
        }
        guard registered else { return false }
        let request = BGContinuedProcessingTaskRequest(
            identifier: identifier,
            title: "Uploading videos to NAS",
            subtitle: "Preparing…")
        request.strategy = .fail
        do {
            try BGTaskScheduler.shared.submit(request)
            return true
        } catch {
            print("Continued processing submit failed: \(error)")
            return false
        }
    }

    @available(iOS 26.0, *)
    private static func handleContinued(_ task: BGContinuedProcessingTask) {
        task.progress.totalUnitCount = 1000
        task.expirationHandler = {
            Task { @MainActor in SyncEngine.shared.cancel() }
        }
        Task { @MainActor in
            let engine = SyncEngine.shared
            engine.onProgress = { name, overall, done, total in
                task.progress.completedUnitCount = Int64(overall * 1000)
                task.updateTitle("Uploading videos to NAS", subtitle: "\(min(done + 1, total)) of \(total) · \(name)")
            }
            let summary = await engine.sync(trigger: .manual)
            engine.onProgress = nil
            task.progress.completedUnitCount = task.progress.totalUnitCount
            task.updateTitle("NAS Sync", subtitle: summary.message)
            task.setTaskCompleted(success: summary.error == nil)
        }
    }

    static func scheduleIfEnabled() {
        guard SyncSettings.load().chargingTriggerEnabled else {
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: chargingTaskID)
            return
        }
        let request = BGProcessingTaskRequest(identifier: chargingTaskID)
        request.requiresExternalPower = true
        request.requiresNetworkConnectivity = true
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            print("BGTaskScheduler submit failed: \(error)")
        }
    }

    private static func handle(_ task: BGProcessingTask) {
        scheduleIfEnabled()
        let run = Task { @MainActor in
            let summary = await SyncEngine.shared.sync(trigger: .charging)
            task.setTaskCompleted(success: summary.error == nil)
        }
        task.expirationHandler = {
            run.cancel()
            Task { @MainActor in SyncEngine.shared.cancel() }
        }
    }
}
