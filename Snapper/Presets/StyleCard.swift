import UIKit

/// An optional sharing artifact, never baked into ordinary photo exports.
@MainActor
enum StyleCard {
    static func image(photo: UIImage, preset: SavedPreset, lookName: String, isSample: Bool) -> UIImage {
        let width: CGFloat = 1200
        let margin: CGFloat = 48
        let photoHeight = min(1500, (width - margin * 2) * photo.size.height / max(photo.size.width, 1))
        let size = CGSize(width: width, height: photoHeight + 240)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            UIColor(white: 0.96, alpha: 1).setFill()
            UIRectFill(CGRect(origin: .zero, size: size))
            let scale = min((width - margin * 2) / max(photo.size.width, 1), photoHeight / max(photo.size.height, 1))
            let drawn = CGSize(width: photo.size.width * scale, height: photo.size.height * scale)
            photo.draw(in: CGRect(x: (width - drawn.width) / 2, y: margin, width: drawn.width, height: drawn.height))
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineBreakMode = .byTruncatingTail
            let titleAttributes: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 40, weight: .semibold),
                                                                 .foregroundColor: UIColor.black, .paragraphStyle: paragraph]
            (preset.name as NSString).draw(in: CGRect(x: margin, y: photoHeight + 80, width: width - margin * 2, height: 52), withAttributes: titleAttributes)
            let detail = "Snapper · \(lookName) · \(Int(preset.strength * 100))%" + (isSample ? " · Sample photo" : "")
            (detail as NSString).draw(in: CGRect(x: margin, y: photoHeight + 144, width: width - margin * 2, height: 40),
                                     withAttributes: [.font: UIFont.systemFont(ofSize: 24), .foregroundColor: UIColor.darkGray])
        }
    }
}
