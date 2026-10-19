import SwiftUI

/// Small renders of every look, for the look picker and the favourites list:
/// each collection on its own example photo (`LookSamples`), or every look on
/// one of the person's photos. Rendered off the main actor.
@MainActor
@Observable
final class LookThumbnails {
    private(set) var images: [String: UIImage] = [:]
    @ObservationIgnored private var isLoading = false

    @ObservationIgnored private var photoTask: Task<Void, Never>?

    func load(looks: [Look], renderer: PhotoRenderer) {
        guard !isLoading, images.isEmpty else { return }
        // In catalog order, so the first collections appear first.
        var groups: [(url: URL, looks: [Look])] = []
        for look in looks {
            guard let url = LookSamples.url(for: look) else { continue }
            if let index = groups.firstIndex(where: { $0.url == url }) {
                groups[index].looks.append(look)
            } else {
                groups.append((url, [look]))
            }
        }
        guard !groups.isEmpty else { return }
        isLoading = true
        Task {
            for group in groups {
                let rendered = await renderer.thumbnails(sourceURL: group.url, looks: group.looks, maxPixelSize: 240)
                images.merge(rendered) { _, new in new }
            }
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
