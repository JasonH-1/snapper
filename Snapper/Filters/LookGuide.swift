import Foundation

/// Shooting guidance for the five featured looks. These are creative starting
/// points, not claims that any filter can repair poor exposure or blur.
struct LookGuide: Identifiable, Sendable {
    let id: String
    let bestFor: String
    let tip: String
    static let featured: [LookGuide] = [
        LookGuide(id: "boardwalk", bestFor: String(localized: "Daylight · travel · everyday moments"),
                  tip: String(localized: "Start in open shade or late-afternoon light. Lower the strength for a subtler warm print.")),
        LookGuide(id: "flashbulb", bestFor: String(localized: "Direct flash · friends · nights out"),
                  tip: String(localized: "Turn on the flash and keep your friends close. Leave space behind them for a darker background.")),
        LookGuide(id: "cream", bestFor: String(localized: "Window light · soft portraits"),
                  tip: String(localized: "Face a window or open shade. Start with neutral exposure and adjust warmth to suit the light.")),
        LookGuide(id: "afterglow", bestFor: String(localized: "City lights · dusk · warm highlights"),
                  tip: String(localized: "Include a bright sign or warm light in the scene. Hold steady and avoid underexposing faces.")),
        LookGuide(id: "halo", bestFor: String(localized: "Backlight · glowing highlights · film texture"),
                  tip: String(localized: "Try bright edges against a darker background. Use a lower strength when the glow feels too strong.")),
    ]
    static func forLook(_ id: String) -> LookGuide? { featured.first { $0.id == id } }
}
