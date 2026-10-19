import CoreGraphics
import Foundation

/// Finishing is reversible and rendered identically in previews and exports.
struct PhotoFinish: Hashable, Codable, Sendable {
    enum Frame: String, Codable, CaseIterable, Identifiable, Sendable {
        case none, white, cream, black, instant
        var id: String { rawValue }
        var title: String {
            switch self {
            case .none: String(localized: "None")
            case .white: String(localized: "White")
            case .cream: String(localized: "Cream")
            case .black: String(localized: "Black")
            case .instant: String(localized: "Instant")
            }
        }
    }
    enum Layout: String, Codable, CaseIterable, Identifiable, Sendable {
        case original, square, post, story
        var id: String { rawValue }
        var ratio: CGFloat? {
            switch self {
            case .original: nil
            case .square: 1
            case .post: 4.0 / 5.0
            case .story: 9.0 / 16.0
            }
        }
        var title: String {
            switch self {
            case .original: String(localized: "Photo")
            case .square: String(localized: "Square 1:1")
            case .post: String(localized: "Post 4:5")
            case .story: String(localized: "Story 9:16")
            }
        }
    }
    var frame: Frame = .none
    /// Padding as a fraction of the canvas's shorter edge.
    var border = 0.05
    var layout: Layout = .original
    /// A frozen, user-confirmed date label. Never changes on later exports.
    var dateStamp: String?
    static let none = PhotoFinish()
    var isActive: Bool { frame != .none || layout != .original || dateStamp != nil }
    /// Frames and layouts are Premium; the classic date stamp is free.
    var requiresPremium: Bool { frame != .none || layout != .original }

    /// The same finish with only its free part, the date stamp.
    var withoutPremium: PhotoFinish {
        var free = self
        free.frame = .none
        free.layout = .original
        return free
    }

    struct Geometry {
        let canvas: CGRect
        let photo: CGRect
    }

    /// Fit the complete cropped image inside the selected layout; never cut
    /// away more of the photo. Bound full-resolution canvases to 8192px.
    func geometry(for size: CGSize) -> Geometry {
        guard size.width > 0, size.height > 0 else {
            return Geometry(canvas: .zero, photo: .zero)
        }
        let amount = frame == .none ? 0 : CGFloat(min(max(border.isFinite ? border : 0.05, 0.01), 0.16))
        let padding = min(size.width, size.height) * amount
        let extraBottom = frame == .instant ? padding * 2 : 0
        var canvasSize = CGSize(width: size.width + padding * 2, height: size.height + padding * 2 + extraBottom)
        if let ratio = layout.ratio {
            let long = max(canvasSize.width, canvasSize.height)
            canvasSize = CGSize(width: long * ratio, height: long)
        }
        let cap = min(1, 8192 / max(canvasSize.width, canvasSize.height))
        canvasSize = CGSize(width: max(1, (canvasSize.width * cap).rounded()), height: max(1, (canvasSize.height * cap).rounded()))
        let inset = min(canvasSize.width, canvasSize.height) * amount
        let bottom = frame == .instant ? inset * 3 : inset
        let available = CGSize(width: max(1, canvasSize.width - inset * 2), height: max(1, canvasSize.height - inset - bottom))
        let scale = min(available.width / size.width, available.height / size.height)
        let photoSize = CGSize(width: size.width * scale, height: size.height * scale)
        let photo = CGRect(x: (canvasSize.width - photoSize.width) / 2,
                           y: bottom + (available.height - photoSize.height) / 2,
                           width: photoSize.width, height: photoSize.height)
        return Geometry(canvas: CGRect(origin: .zero, size: canvasSize), photo: photo)
    }
}
