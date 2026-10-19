import ExtensionKit
import LockedCameraCapture
import SwiftUI

/// Snapper's Lock Screen camera, which the system opens from Camera Control,
/// the Lock Screen and Control Center while the iPhone is locked.
@main
struct SnapperCaptureExtension: LockedCameraCaptureExtension {
    var body: some LockedCameraCaptureExtensionScene {
        LockedCameraCaptureUIScene { session in
            LockedCameraScreen(session: session)
        }
    }
}

/// Owns the camera for one Lock Screen session.
private struct LockedCameraScreen: View {
    @State private var model: LockedCameraModel

    init(session: LockedCameraCaptureSession) {
        _model = State(initialValue: LockedCameraModel(session: session))
    }

    var body: some View {
        LockedCameraView(model: model)
    }
}
