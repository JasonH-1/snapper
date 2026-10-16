import AVKit
import SwiftUI

extension View {
    /// The volume buttons (and Camera Control) take the photo, like the
    /// system Camera, on iOS 18 and later. While enabled, they don't change
    /// the volume.
    func volumeButtonShutter(enabled: Bool, action: @escaping () -> Void) -> some View {
        modifier(VolumeButtonShutter(enabled: enabled, action: action))
    }
}

private struct VolumeButtonShutter: ViewModifier {
    let enabled: Bool
    let action: () -> Void

    func body(content: Content) -> some View {
        if #available(iOS 18, *) {
            content.onCameraCaptureEvent(isEnabled: enabled) { event in
                // Fire on release, like the shutter button.
                if event.phase == .ended { action() }
            }
        } else {
            content
        }
    }
}
