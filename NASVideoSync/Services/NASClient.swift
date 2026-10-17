import AMSMB2
import Foundation

enum NASError: LocalizedError {
    case notConfigured
    case invalidHost
    case missingPassword

    var errorDescription: String? {
        switch self {
        case .notConfigured: "Set the NAS host, share and username in Settings."
        case .invalidHost: "The NAS host is not a valid address."
        case .missingPassword: "Enter the SMB password in Settings."
        }
    }
}

/// Thin wrapper over AMSMB2 for the handful of SMB operations the sync needs.
/// All paths are relative to the share root.
final class NASClient: @unchecked Sendable {
    private let manager: SMB2Manager
    private let share: String

    init(settings: SyncSettings) throws {
        guard settings.isConfigured else { throw NASError.notConfigured }
        guard let password = Keychain.password(for: settings.username) else { throw NASError.missingPassword }
        guard let url = URL(string: "smb://\(settings.host)"),
              let manager = SMB2Manager(
                  url: url,
                  credential: URLCredential(user: settings.username, password: password, persistence: .none))
        else { throw NASError.invalidHost }
        manager.timeout = 20
        self.manager = manager
        self.share = settings.share
    }

    func connect() async throws {
        try await manager.connectShare(name: share)
    }

    func disconnect() async {
        try? await manager.disconnectShare(gracefully: true)
    }

    /// File size on the NAS, or nil if the file doesn't exist.
    func size(of path: String) async -> Int64? {
        guard let attrs = try? await manager.attributesOfItem(atPath: path) else { return nil }
        return (attrs[.fileSizeKey] as? NSNumber)?.int64Value
    }

    /// mkdir -p
    func ensureDirectory(_ path: String) async throws {
        var current = ""
        for component in path.split(separator: "/") {
            current = current.isEmpty ? String(component) : "\(current)/\(component)"
            if (try? await manager.attributesOfItem(atPath: current)) != nil { continue }
            do {
                try await manager.createDirectory(atPath: current)
            } catch {
                // Another writer may have created it between the stat and the mkdir.
                if (try? await manager.attributesOfItem(atPath: current)) == nil { throw error }
            }
        }
    }

    /// Creates an empty file, replacing any existing one.
    func createEmptyFile(_ path: String) async throws {
        try? await manager.removeItem(atPath: path)
        try await manager.write(data: Data(), toPath: path, progress: nil)
    }

    /// Writes `data` at `offset`, truncating anything after it. The file must already exist:
    /// AMSMB2's append truncates to `offset` first, which fails with ENOENT on a missing file.
    func write(_ data: Data, to path: String, at offset: Int64) async throws {
        try await manager.append(data: data, toPath: path, offset: offset, progress: nil)
    }

    func move(_ path: String, to destination: String) async throws {
        try await manager.moveItem(atPath: path, toPath: destination)
    }

    func remove(_ path: String) async throws {
        try await manager.removeItem(atPath: path)
    }
}
