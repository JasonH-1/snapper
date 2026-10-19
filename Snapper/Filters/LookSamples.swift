import Foundation

/// The example photo each collection's looks are shown on while choosing a
/// look: one in the light the collection is made for, so night looks are
/// seen at night and portrait looks on a face. Looks in one collection share
/// a photo, so they can still be compared side by side.
enum LookSamples {
    /// Collection id → bundled photo in Resources/Showcase. Collections not
    /// listed, and Original, use the demo scene.
    static let photos: [String: String] = [
        "disposable": "showcase-beach",
        "neon": "showcase-night",
        "soft": "showcase-portrait",
        "overclock": "showcase-arcade",
        "darkroom": "showcase-cafe",
        "digicam": "showcase-cake",
    ]

    static func url(for look: Look) -> URL? {
        #if DEBUG
        // SNAPPER_DEMO_IMAGE puts every look on one test photo (see DemoScene).
        if ProcessInfo.processInfo.environment["SNAPPER_DEMO_IMAGE"] != nil { return DemoScene.url }
        #endif
        guard let name = look.collectionID.flatMap({ photos[$0] }),
              let url = Bundle.main.url(forResource: name, withExtension: "jpg") else { return DemoScene.url }
        return url
    }
}
