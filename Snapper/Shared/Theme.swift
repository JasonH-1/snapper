import SwiftUI

/// Shared visual constants.
enum Theme {
    static let previewCornerRadius: CGFloat = 18
    static let cardCornerRadius: CGFloat = 20
    static let controlSize: CGFloat = 44

    /// Look names are set in the serif face for a printed, editorial feel.
    static func lookTitle(size: CGFloat) -> Font {
        .system(size: size, weight: .medium, design: .serif)
    }

    static let premiumGradient = LinearGradient(
        colors: [Color(red: 1.0, green: 0.76, blue: 0.37), Color(red: 1.0, green: 0.45, blue: 0.42)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
}

/// A round, translucent button used for camera controls.
struct CameraIconButtonStyle: ButtonStyle {
    var size: CGFloat = Theme.controlSize

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 18, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(.white.opacity(configuration.isPressed ? 0.22 : 0.12), in: Circle())
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
            .contentShape(Circle())
    }
}

/// Primary call-to-action button (filled, full width).
struct PrimaryButtonStyle: ButtonStyle {
    var isProminent = true

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .foregroundStyle(isProminent ? Color.black : Color.primary)
            .background {
                if isProminent {
                    RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.premiumGradient)
                } else {
                    RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.quaternary)
                }
            }
            .opacity(configuration.isPressed ? 0.85 : 1)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}
