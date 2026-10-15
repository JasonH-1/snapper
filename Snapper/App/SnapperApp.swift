import SwiftUI

@main
struct SnapperApp: App {
    @State private var camera = CameraModel(library: .bundled())

    var body: some Scene {
        WindowGroup {
            CameraView(model: camera, hasPremium: false, lastCapture: nil, isProcessingCapture: false)
        }
    }
}
