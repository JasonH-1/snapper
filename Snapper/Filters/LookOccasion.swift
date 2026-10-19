import Foundation

/// Small, hand-curated starting points; the full catalog stays available.
enum LookOccasion: String, CaseIterable, Identifiable {
    case friends, travel, portraits, night
    var id: String { rawValue }
    var title: String {
        switch self {
        case .friends: String(localized: "Friends & Flash")
        case .travel: String(localized: "Travel & Daylight")
        case .portraits: String(localized: "Soft Portraits")
        case .night: String(localized: "City at Night")
        }
    }
    var lookIDs: [String] {
        switch self {
        case .friends: ["flashbulb", "pocket", "cream"]
        case .travel: ["boardwalk", "postcard", "halo"]
        case .portraits: ["cream", "halo", "boardwalk"]
        case .night: ["afterglow", "afterparty", "flashbulb"]
        }
    }
    var tip: String {
        switch self {
        case .friends: String(localized: "For direct flash, keep friends close and leave space behind them. Try Cream for a softer result.")
        case .travel: String(localized: "Start in open shade or late-afternoon light. Include a face and a bright sky when comparing looks.")
        case .portraits: String(localized: "Face a window or open shade. Reduce look strength in the editor when skin feels too warm.")
        case .night: String(localized: "Include a bright sign or warm light. Hold steady; use flash for nearby friends when faces are too dark.")
        }
    }
}
