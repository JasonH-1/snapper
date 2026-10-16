import Foundation

/// The photo that stands in for the camera where there is none (Simulator).
enum DemoScene {
    /// The bundled demo photo. In Debug builds, the `SNAPPER_DEMO_IMAGE`
    /// environment variable can name another file (a full path), so looks and
    /// effects can be checked on other scenes, such as test-photos/night-city,
    /// without rebuilding. See test-photos/README.md.
    static var url: URL? {
        #if DEBUG
        if let path = ProcessInfo.processInfo.environment["SNAPPER_DEMO_IMAGE"],
           FileManager.default.isReadableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        #endif
        return Bundle.main.url(forResource: "demo-scene", withExtension: "jpg")
    }
}
