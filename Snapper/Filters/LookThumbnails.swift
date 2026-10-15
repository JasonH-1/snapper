import SwiftUI

/// Small renders of a sample photo in every look, for the look picker and
/// the favourites list. Rendered once, off the main actor.
@MainActor
@Observable
final class LookThumbnails {
    private(set) var images: [String: UIImage] = [:]
    @ObservationIgnored private var isLoading = false

    func load(looks: [Look], renderer: PhotoRenderer) {
        guard !isLoading, images.isEmpty, let url = DemoScene.url else { return }
        isLoading = true
        Task {
            images = await renderer.thumbnails(sourceURL: url, looks: looks, maxPixelSize: 240)
            isLoading = false
        }
    }
}
