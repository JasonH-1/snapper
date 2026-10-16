import SwiftUI

/// Covers the preview when there is nothing live to show: no permission,
/// camera interrupted, or an error. Each state explains itself and offers
/// the one action that helps.
struct CameraStatusOverlay: View {
    let status: CameraModel.Status
    let requestPermission: () -> Void

    @Environment(\.openURL) private var openURL

    var body: some View {
        switch status {
        case .needsPermission:
            message(symbol: "camera.fill",
                    title: Text("Camera access"),
                    detail: Text("Snapper needs the camera to show your scene through each look."),
                    actionTitle: Text("Continue"),
                    action: requestPermission)
        case .denied:
            message(symbol: "camera.fill",
                    title: Text("Camera access is off"),
                    detail: Text("Turn on Camera for Snapper in Settings to take photos."),
                    actionTitle: Text("Open Settings"),
                    action: openSettings)
        case .interrupted(let reason):
            message(symbol: "pause.circle",
                    title: Text("Camera paused"),
                    detail: Text(reason.message),
                    actionTitle: nil,
                    action: nil)
        case .failed(let reason):
            message(symbol: "exclamationmark.triangle",
                    title: Text("Something went wrong"),
                    detail: Text(reason),
                    actionTitle: nil,
                    action: nil)
        case .starting, .running, .noCamera:
            EmptyView()
        }
    }

    private func openSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) {
            openURL(url)
        }
    }

    private func message(symbol: String, title: Text, detail: Text, actionTitle: Text?, action: (() -> Void)?) -> some View {
        ZStack {
            Rectangle().fill(.black.opacity(0.72))
            VStack(spacing: 14) {
                Image(systemName: symbol)
                    .font(.system(size: 34, weight: .regular))
                    .foregroundStyle(.white.opacity(0.85))
                title
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.white)
                detail
                    .font(.subheadline)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white.opacity(0.7))
                    .fixedSize(horizontal: false, vertical: true)
                if let actionTitle, let action {
                    Button(action: action) {
                        actionTitle
                            .font(.headline)
                            .padding(.horizontal, 22)
                            .padding(.vertical, 11)
                            .background(.white, in: Capsule())
                            .foregroundStyle(.black)
                    }
                    .padding(.top, 6)
                }
            }
            .padding(32)
        }
        .transition(.opacity)
    }
}
