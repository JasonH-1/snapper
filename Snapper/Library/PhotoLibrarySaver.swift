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

    /// Saves the photo file at `fileURL` (and optionally the unfiltered
    /// original at `originalURL`) as new assets. The photo file is moved into
    /// the library; the original is copied and stays where it is.
    ///
    /// Files rather than `Data`: adding image data from memory has been
    /// reported (Apple Developer Forums) to drop EXIF metadata such as the date
    /// and location on some iOS 26 releases, while the file route keeps the
    /// bytes as written.
    static func save(fileURL: URL, originalURL: URL? = nil) async throws {
        guard await requestAccess() else { throw SaveError.notAuthorized }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                let options = PHAssetResourceCreationOptions()
                options.shouldMoveFile = true
                PHAssetCreationRequest.forAsset().addResource(with: .photo, fileURL: fileURL, options: options)
                if let originalURL {
                    PHAssetCreationRequest.forAsset().addResource(with: .photo, fileURL: originalURL, options: nil)
                }
            }
        } catch {
            throw SaveError.failed(error.localizedDescription)
        }
    }
}
