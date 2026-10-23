import Foundation

/// Searchable shooting guidance, with a small featured selection. These are creative starting
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
        LookGuide(id: "pocket", bestFor: String(localized: "Flash · friends · 2000s digicam"),
                  tip: String(localized: "Turn on the flash and get close. Add the date stamp when you finish the photo for the full digicam look.")),
    ] + expansion.filter { ["sunday", "graphite", "daybreak", "peel"].contains($0.id) }

    /// The looks added with Everyday Film, Black & White, Cinema and Instant Prints.
    private static let expansion: [LookGuide] = [
        LookGuide(id: "sunday", bestFor: String(localized: "Soft daylight · everyday moments"),
                  tip: String(localized: "Works in almost any daylight. Lower the strength for a barely-there finish.")),
        LookGuide(id: "sundial", bestFor: String(localized: "Golden sun · deep blue skies · red accents"),
                  tip: String(localized: "Shoot in direct sun with the light behind you so the sky turns deep blue.")),
        LookGuide(id: "evergreen", bestFor: String(localized: "Parks · forests · cool greens"),
                  tip: String(localized: "Look for open shade under trees; it keeps greens rich and highlights clean.")),
        LookGuide(id: "terracotta", bestFor: String(localized: "Old towns · warm walls · earthy reds"),
                  tip: String(localized: "Frame brick, clay or painted walls in soft afternoon light.")),
        LookGuide(id: "alpine", bestFor: String(localized: "Mountains · clear air · crisp whites"),
                  tip: String(localized: "Expose for the sky so snow and clouds keep their detail.")),
        LookGuide(id: "amber100", bestFor: String(localized: "Late sun · golden midtones · quiet color"),
                  tip: String(localized: "Try it late in the day, when warm light falls across faces and walls.")),
        LookGuide(id: "coast", bestFor: String(localized: "Beach · sea · pale sand"),
                  tip: String(localized: "Keep the horizon level and let the water fill part of the frame.")),
        LookGuide(id: "travelogue", bestFor: String(localized: "Travel · vivid blues · bold shadows"),
                  tip: String(localized: "Look for bright sun and strong shadows, like a landmark against a clear sky.")),
        LookGuide(id: "graphite", bestFor: String(localized: "Street · everyday black and white"),
                  tip: String(localized: "Look for strong light and clear shapes; color no longer competes.")),
        LookGuide(id: "noir", bestFor: String(localized: "Hard light · deep shadows · drama"),
                  tip: String(localized: "Put your subject in a shaft of side light and let the rest fall to black.")),
        LookGuide(id: "chalk", bestFor: String(localized: "Soft portraits · pale interiors"),
                  tip: String(localized: "Use window light in a bright room; the lifted blacks give an airy print.")),
        LookGuide(id: "platinum", bestFor: String(localized: "Overcast light · silver greys"),
                  tip: String(localized: "Try a cloudy day for long, smooth greys with a cool silver cast.")),
        LookGuide(id: "blueprint", bestFor: String(localized: "Water · metal · cyan tone"),
                  tip: String(localized: "Pick geometric scenes such as stairs, bridges or glass.")),
        LookGuide(id: "daybreak", bestFor: String(localized: "Low sun · peach light · cool shade"),
                  tip: String(localized: "Shoot early or late with the sun low: it warms the highlights and cools the shade.")),
        LookGuide(id: "raincheck", bestFor: String(localized: "Grey days · wet streets · slate blues"),
                  tip: String(localized: "Overcast light suits it; wet pavements and shopfronts keep their muted color.")),
        LookGuide(id: "velvet", bestFor: String(localized: "Lamplight · evenings · burgundy shade"),
                  tip: String(localized: "Try lamp-lit rooms or candlelight. Lower the strength if faces get too warm.")),
        LookGuide(id: "copper", bestFor: String(localized: "Golden hour · steel blues · contrast"),
                  tip: String(localized: "Face toward low sun and let metal, glass or water catch the light.")),
        LookGuide(id: "reel", bestFor: String(localized: "Hard light · silver color · low saturation"),
                  tip: String(localized: "Midday sun gives the strongest bleach-style contrast.")),
        LookGuide(id: "peel", bestFor: String(localized: "Instant print · warm paper · cool shadows"),
                  tip: String(localized: "Add an instant frame in Finish for the full printed look.")),
        LookGuide(id: "pastel", bestFor: String(localized: "Flowers · still life · candy color"),
                  tip: String(localized: "Expose a little bright: pale scenes give the softest pastels.")),
        LookGuide(id: "keepsake", bestFor: String(localized: "Family moments · warm print"),
                  tip: String(localized: "Try faces in warm indoor light for a print from an old album.")),
        LookGuide(id: "mintprint", bestFor: String(localized: "Faded print · minty shade"),
                  tip: String(localized: "Green leaves and pale skies bring out the mint cast.")),
        LookGuide(id: "roseprint", bestFor: String(localized: "Gentle portraits · rose paper"),
                  tip: String(localized: "Use soft light on faces; the rosy paper flatters skin.")),
        LookGuide(id: "fadedpaper", bestFor: String(localized: "Aged print · milky blacks"),
                  tip: String(localized: "Choose quiet, everyday scenes and let the faded blacks set the mood.")),
        LookGuide(id: "mall", bestFor: String(localized: "Shop lights · indoors · red accents"),
                  tip: String(localized: "Shoot under shop or office lights, then add the date stamp in Finish.")),
        LookGuide(id: "pixelpop", bestFor: String(localized: "Full sun · bold primaries · playful"),
                  tip: String(localized: "Find bright primary colors in full sun: signs, toys, painted walls.")),
    ]
    static func forLook(_ id: String) -> LookGuide? {
        featured.first { $0.id == id } ?? expansion.first { $0.id == id }
    }
}
