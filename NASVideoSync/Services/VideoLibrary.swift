import Foundation
import Photos

struct VideoItem: Sendable {
    let id: String
    let creationDate: Date
    let originalFilename: String
}

/// Reads videos from the Photos library and exports them to local files for upload.
enum VideoLibrary {
    static func requestAccess() async -> Bool {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        return status == .authorized || status == .limited
    }

    static var hasAccess: Bool {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        return status == .authorized || status == .limited
    }

    /// Videos created on/after `since`, oldest first.
    static func videos(since: Date?) -> [VideoItem] {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        options.includeAssetSourceTypes = [.typeUserLibrary, .typeiTunesSynced, .typeCloudShared]
        if let since {
            options.predicate = NSPredicate(format: "creationDate >= %@", since as NSDate)
        }
        let result = PHAsset.fetchAssets(with: .video, options: options)
        var items: [VideoItem] = []
        items.reserveCapacity(result.count)
        result.enumerateObjects { asset, _, _ in
            guard let resource = preferredResource(for: asset) else { return }
            items.append(VideoItem(
                id: asset.localIdentifier,
                creationDate: asset.creationDate ?? .distantPast,
                originalFilename: resource.originalFilename))
        }
        return items
    }

    /// Exports the video (downloading from iCloud if needed) to a cached file.
    /// The export is reused across runs so a short background window doesn't repeat it.
    static func exportedFile(
        for item: VideoItem, progress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> URL {
        let dir = try exportDirectory()
        let safeID = item.id.replacingOccurrences(of: "/", with: "_")
        let ext = (item.originalFilename as NSString).pathExtension
        let final = dir.appendingPathComponent("\(safeID).\(ext.isEmpty ? "mov" : ext)")
        if FileManager.default.fileExists(atPath: final.path) { return final }

        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [item.id], options: nil).firstObject,
              let resource = preferredResource(for: asset)
        else { throw CocoaError(.fileNoSuchFile) }

        let partial = final.appendingPathExtension("partial")
        try? FileManager.default.removeItem(at: partial)
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true
        options.progressHandler = progress
        try await PHAssetResourceManager.default().writeData(for: resource, toFile: partial, options: options)
        try FileManager.default.moveItem(at: partial, to: final)
        return final
    }

    /// The subset of `ids` still in the library.
    static func existing(_ ids: [String]) -> [String] {
        guard !ids.isEmpty else { return [] }
        var found: [String] = []
        PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)
            .enumerateObjects { asset, _, _ in found.append(asset.localIdentifier) }
        return found
    }

    /// Moves the assets to Recently Deleted. iOS shows its own confirmation and requires the app
    /// to be in the foreground; throws PHPhotosError.userCancelled if the user declines.
    static func delete(_ ids: [String]) async throws {
        try await PHPhotoLibrary.shared().performChanges {
            let assets = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)
            PHAssetChangeRequest.deleteAssets(assets)
        }
    }

    static func discardExport(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    /// The edited rendition if the video was edited in Photos, otherwise the original.
    private static func preferredResource(for asset: PHAsset) -> PHAssetResource? {
        let resources = PHAssetResource.assetResources(for: asset)
        return resources.first { $0.type == .fullSizeVideo }
            ?? resources.first { $0.type == .video }
    }

    private static func exportDirectory() throws -> URL {
        let dir = try FileManager.default
            .url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("Exports", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
