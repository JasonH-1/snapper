import Photos

/// Adds photos to the system photo library (add-only access).
enum PhotoLibrarySaver {
    enum SaveError: LocalizedError {
        case notAuthorized
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .notAuthorized:
                String(localized: "Snapper doesn't have permission to add photos. You can allow it in Settings.")
            case .failed(let reason):
                String(localized: "The photo couldn't be saved. \(reason)")
            }
        }
    }

    static var isAuthorized: Bool {
        let status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        return status == .authorized || status == .limited
    }

    static var canAsk: Bool {
        PHPhotoLibrary.authorizationStatus(for: .addOnly) == .notDetermined
    }

    /// Shows the system prompt if needed. Returns whether saving is allowed.
    @discardableResult
    static func requestAccess() async -> Bool {
        switch PHPhotoLibrary.authorizationStatus(for: .addOnly) {
        case .authorized, .limited:
            return true
        case .notDetermined:
            let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            return status == .authorized || status == .limited
        default:
            return false
        }
    }

    /// Saves `photo` (and optionally the unfiltered `original`) as new assets.
    static func save(_ photo: Data, original: Data? = nil) async throws {
        guard await requestAccess() else { throw SaveError.notAuthorized }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCreationRequest.forAsset()
                request.addResource(with: .photo, data: photo, options: nil)
                if let original {
                    PHAssetCreationRequest.forAsset().addResource(with: .photo, data: original, options: nil)
                }
            }
        } catch {
            throw SaveError.failed(error.localizedDescription)
        }
    }
}
