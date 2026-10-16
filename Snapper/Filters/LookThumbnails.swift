import SwiftUI

/// Small renders of a sample photo (or one of the person's photos) in every
/// look, for the look picker and the favourites list. Rendered off the main actor.
@MainActor
@Observable
final class LookThumbnails {
    private(set) var images: [String: UIImage] = [:]
    @ObservationIgnored private var isLoading = false

    @ObservationIgnored private var photoTask: Task<Void, Never>?

    func load(looks: [Look], renderer: PhotoRenderer) {
        guard !isLoading, images.isEmpty, let url = DemoScene.url else { return }
        isLoading = true
        Task {
            images = await renderer.thumbnails(sourceURL: url, looks: looks, maxPixelSize: 240)
            isLoading = false
        }
    }

    /// Renders one of the person's photos (keeping its sliders and crop) in
    /// every look instead of the sample.
    func load(photo url: URL, recipe: PhotoRecipe, seed: UInt64, looks: [Look], renderer: PhotoRenderer) {
        photoTask?.cancel()
        images = [:]
        photoTask = Task {
            let rendered = await renderer.thumbnails(sourceURL: url, looks: looks, recipe: recipe, seed: seed, maxPixelSize: 240)
            guard !Task.isCancelled else { return }
            images = rendered
        }
    }
}
