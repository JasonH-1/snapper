import SwiftUI

/// The shutter: a white ring with an inner disc that dips when pressed. While
/// the self-timer counts down, the disc becomes a stop square (tap to cancel).
struct ShutterButton: View {
    var isBusy: Bool
    var isCountingDown = false
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            EmptyView()
        }
        .buttonStyle(ShutterButtonStyle(isBusy: isBusy, isCountingDown: isCountingDown))
        .accessibilityLabel(isCountingDown ? Text("Cancel timer") : Text("Take photo"))
    }
}

private struct ShutterButtonStyle: ButtonStyle {
    var isBusy: Bool
    var isCountingDown: Bool

    func makeBody(configuration: Configuration) -> some View {
        ZStack {
            Circle()
                .strokeBorder(.white, lineWidth: 4)
                .frame(width: 78, height: 78)
            RoundedRectangle(cornerRadius: isCountingDown ? 8 : 32, style: .continuous)
                .fill(isCountingDown ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(.white))
                .frame(width: isCountingDown ? 30 : 64, height: isCountingDown ? 30 : 64)
                .scaleEffect(configuration.isPressed ? 0.86 : (isBusy ? 0.9 : 1))
                .opacity(isBusy ? 0.75 : 1)
        }
        .frame(width: 84, height: 84)
        .contentShape(Circle())
        .animation(.spring(response: 0.22, dampingFraction: 0.65), value: configuration.isPressed)
        .animation(.easeInOut(duration: 0.2), value: isBusy)
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: isCountingDown)
    }
}
