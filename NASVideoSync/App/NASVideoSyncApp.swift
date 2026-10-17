import SwiftUI
import UIKit

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        BackgroundScheduler.register()
        // Start listening for the home region right away: when iOS relaunches us in the
        // background for a region event, this is the only code that runs.
        LocationTrigger.shared.start()
        return true
    }
}

@main
struct NASVideoSyncApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background {
                BackgroundScheduler.scheduleIfEnabled()
            }
        }
    }
}
