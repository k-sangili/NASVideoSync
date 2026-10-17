import CoreLocation
import Foundation
import Observation
import UIKit

/// "Arrive home" trigger, like PhotoSync's location-based Autotransfer. With "Always" location access,
/// iOS relaunches the app in the background when you enter the home region. That window is short
/// (~30 s), so the run makes whatever progress it can; uploads resume where they left off.
@MainActor
@Observable
final class LocationTrigger: NSObject, CLLocationManagerDelegate {
    static let shared = LocationTrigger()

    private static let monitorName = "NASVideoSyncHome" // CLMonitor names must be alphanumeric
    private static let homeID = "home"

    private let manager = CLLocationManager()
    private var monitor: CLMonitor?
    private var eventsTask: Task<Void, Never>?

    private(set) var authorization: CLAuthorizationStatus

    override private init() {
        authorization = manager.authorizationStatus
        super.init()
        manager.delegate = self
    }

    var hasAlwaysAccess: Bool { authorization == .authorizedAlways }

    /// Call at launch so region events that relaunched the app get delivered.
    func start() {
        guard eventsTask == nil else { return }
        eventsTask = Task {
            let monitor = await CLMonitor(Self.monitorName)
            self.monitor = monitor
            await self.applySettings()
            do {
                for try await event in await monitor.events where event.identifier == Self.homeID {
                    if event.state == .satisfied { await self.handleArrival() }
                }
            } catch {
                print("CLMonitor events ended: \(error)")
            }
        }
    }

    /// Adds or removes the home region to match the saved settings.
    func applySettings() async {
        guard let monitor else { return }
        let settings = SyncSettings.load()
        await monitor.remove(Self.homeID)
        guard settings.locationTriggerEnabled,
              let lat = settings.homeLatitude, let lon = settings.homeLongitude
        else { return }
        let condition = CLMonitor.CircularGeographicCondition(
            center: CLLocationCoordinate2D(latitude: lat, longitude: lon),
            radius: settings.homeRadiusMeters)
        // Assume we're home when setting it up, so the first event is the next real arrival.
        await monitor.add(condition, identifier: Self.homeID, assuming: .satisfied)
    }

    func requestAlwaysAccess() {
        switch manager.authorizationStatus {
        case .notDetermined: manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse: manager.requestAlwaysAuthorization()
        default: break
        }
    }

    func currentLocation() async -> CLLocation? {
        do {
            for try await update in CLLocationUpdate.liveUpdates() {
                if let location = update.location { return location }
            }
        } catch {
            print("Location update failed: \(error)")
        }
        return nil
    }

    private func handleArrival() async {
        let app = UIApplication.shared
        var bgTask = UIBackgroundTaskIdentifier.invalid
        bgTask = app.beginBackgroundTask(withName: "ArrivedHomeSync") {
            SyncEngine.shared.cancel()
        }
        await SyncEngine.shared.sync(trigger: .location)
        // Hand whatever is left to the charging task.
        BackgroundScheduler.scheduleIfEnabled()
        app.endBackgroundTask(bgTask)
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            self.authorization = status
            // iOS asks for "When In Use" first; follow up with the "Always" upgrade.
            if status == .authorizedWhenInUse, SyncSettings.load().locationTriggerEnabled {
                self.manager.requestAlwaysAuthorization()
            }
        }
    }
}
