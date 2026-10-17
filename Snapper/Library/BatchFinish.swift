import Foundation

/// Only the explicitly selected finishing parts are shared across a set.
struct BatchFinish: Hashable, Sendable {
    var replaceFrame = false
    var frame: PhotoFinish.Frame = .white
    var border = 0.05
    var replaceLayout = false
    var layout: PhotoFinish.Layout = .post
    var hasChanges: Bool { replaceFrame || replaceLayout }

    func applying(to original: PhotoRecipe) -> PhotoRecipe {
        var recipe = original
        if replaceFrame {
            recipe.finish.frame = frame
            recipe.finish.border = min(max(border.isFinite ? border : 0.05, 0.01), 0.16)
        }
        if replaceLayout { recipe.finish.layout = layout }
        return recipe
    }
}
