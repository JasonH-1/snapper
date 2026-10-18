import Foundation

struct CuratedStyle: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let tip: String
    let recipe: PhotoRecipe
    var preset: SavedPreset { SavedPreset(name: name, recipe: recipe) }
}

/// Versioned, bundled editorial releases. Adding a collection does not alter old
/// styles: saved photos and presets store the complete recipe, not a catalog index.
struct CuratedCollection: Identifiable, Sendable {
    let id: String
    let title: String
    let subtitle: String
    let edition: String
    let styles: [CuratedStyle]

    static let releases: [CuratedCollection] = [
        .init(id: "golden-hour-01", title: "Golden Hour", subtitle: "Warm light, gentle highlights and open shadows.", edition: "Collection 01", styles: [
            style("golden-soft", "Soft Gold", "Try late-afternoon side light; keep highlights below clipping.", look: "cream", strength: 0.7, warmth: 0.15, highlights: -0.25, shadows: 0.15, bloom: 0.12),
            style("golden-postcard", "Sunlit Postcard", "Leave space around a bright subject for a travel-photo feel.", look: "postcard", strength: 0.65, warmth: 0.1, highlights: -0.2, shadows: 0.1, vignette: 0.15),
            style("golden-halo", "Evening Glow", "Backlit hair and bright windows reveal the glow.", look: "halo", strength: 0.55, warmth: 0.08, bloom: 0.2, halation: 0.12)
        ]),
        .init(id: "after-dark-01", title: "After Dark", subtitle: "Protect bright signs and add restrained film halos.", edition: "Collection 02", styles: [
            style("night-neon", "Neon Walk", "Include a small bright sign and keep the camera steady.", look: "afterglow", strength: 0.65, highlights: -0.3, shadows: 0.12, halation: 0.25, vignette: 0.12),
            style("night-train", "Last Light", "Use mixed cool and warm light for depth.", look: "lasttrain", strength: 0.6, highlights: -0.2, shadows: 0.15, bloom: 0.15),
            style("night-flash", "Flash Diary", "Direct flash works best with your subject nearby.", look: "flashbulb", strength: 0.65, highlights: -0.15, halation: 0.08, vignette: 0.2)
        ]),
        .init(id: "quiet-days-01", title: "Quiet Days", subtitle: "Subtle color and soft contrast for everyday scenes.", edition: "Collection 03", styles: [
            style("quiet-window", "Window Light", "Face a window and avoid mixed room lighting.", look: "cream", strength: 0.4, highlights: -0.15, shadows: 0.2, bloom: 0.08),
            style("quiet-weekend", "Weekend", "Try open shade for softer skin and clothing colors.", look: "boardwalk", strength: 0.5, highlights: -0.1, shadows: 0.1, vignette: 0.08),
            style("quiet-air", "Soft Air", "Give a simple subject breathing room against a clean background.", look: "halo", strength: 0.35, highlights: -0.2, shadows: 0.08, bloom: 0.1)
        ])
    ]
    static func contains(_ style: CuratedStyle) -> Bool { releases.contains { $0.styles.contains(style) } }
    private static func style(_ id: String, _ name: String, _ tip: String, look: String, strength: Double,
                              warmth: Double = 0, highlights: Double = 0, shadows: Double = 0,
                              bloom: Double = 0, halation: Double = 0, vignette: Double = 0) -> CuratedStyle {
        let edits = PhotoAdjustments(warmth: warmth, highlights: highlights, shadows: shadows,
                                     bloom: bloom, halation: halation, vignette: vignette)
        return CuratedStyle(id: id, name: name, tip: tip,
                            recipe: PhotoRecipe(lookID: look, strength: strength, adjustments: edits))
    }
}
