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

    /// Signal yellow (the AccentColor asset). Fills carry black content; as a
    /// text or icon colour it needs a dark surface, which is why the app is
    /// dark-only.
    static let accent = Color.accentColor
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

    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .foregroundStyle(foreground)
            .background(background, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .opacity(configuration.isPressed ? 0.85 : 1)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }

    /// Disabled buttons go grey so they never look tappable.
    private var foreground: Color {
        guard isEnabled else { return Color(.systemGray) }
        return isProminent ? .black : .primary
    }

    private var background: Color {
        isEnabled && isProminent ? Theme.accent : Color(.systemGray5)
    }
}
