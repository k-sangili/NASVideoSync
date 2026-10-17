import Foundation

/// User-editable configuration, persisted in UserDefaults. The SMB password lives in the Keychain.
struct SyncSettings: Codable, Equatable {
    var host = "192.168.50.164"
    var share = "Videos"
    /// Folder inside the share, e.g. "iPhone". Empty means the share root.
    var baseFolder = "iPhone"
    var username = ""

    /// Organize uploads as <baseFolder>/<yyyy>/<yyyy-MM>/.
    var subfoldersByDate = true
    /// Only transfer when the phone is on Wi-Fi (Tailscale over cellular is skipped).
    var wifiOnly = true
    /// Only videos created on/after this date are synced. nil = whole library.
    var syncSince: Date? = nil
    /// After a verified upload, remove the video from the phone (iOS asks for confirmation; it goes to Recently Deleted).
    var deleteAfterUpload = true

    // Autotransfer triggers (PhotoSync-style)
    var chargingTriggerEnabled = true
    var locationTriggerEnabled = false
    var homeLatitude: Double? = nil
    var homeLongitude: Double? = nil
    var homeRadiusMeters: Double = 150

    var isConfigured: Bool { !host.isEmpty && !share.isEmpty && !username.isEmpty }

    private static let key = "SyncSettings.v1"

    static func load() -> SyncSettings {
        guard let data = UserDefaults.standard.data(forKey: key) else { return SyncSettings() }
        // Overlay saved values on the defaults, so settings saved by an older build
        // (missing newer keys) still load instead of resetting everything.
        guard let saved = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let defaultsData = try? JSONEncoder().encode(SyncSettings()),
              var merged = try? JSONSerialization.jsonObject(with: defaultsData) as? [String: Any]
        else { return SyncSettings() }
        merged.merge(saved) { _, new in new }
        guard let mergedData = try? JSONSerialization.data(withJSONObject: merged),
              let settings = try? JSONDecoder().decode(SyncSettings.self, from: mergedData)
        else { return SyncSettings() }
        return settings
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }
}
