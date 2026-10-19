import AppIntents
import SwiftUI
import WidgetKit

@main
struct SnapperControlsBundle: WidgetBundle {
    var body: some Widget {
        SnapperCameraControl()
    }
}

/// A control for Control Center, the Lock Screen and the Action button that
/// opens Snapper's camera; while the iPhone is locked, its Lock Screen camera.
struct SnapperCameraControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "app.snapper.controls.camera") {
            ControlWidgetButton(action: SnapperCaptureIntent()) {
                Label("Snapper", systemImage: "camera.aperture")
            }
        }
        .displayName("Snapper Camera")
        .description("Opens Snapper's camera with your film looks, even from the Lock Screen.")
    }
}
