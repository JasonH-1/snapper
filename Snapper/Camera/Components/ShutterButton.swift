import SwiftUI

/// The shutter: a white ring with an inner disc that dips when pressed.
struct ShutterButton: View {
    var isBusy: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            EmptyView()
        }
        .buttonStyle(ShutterButtonStyle(isBusy: isBusy))
        .accessibilityLabel(Text("Take photo"))
    }
}

private struct ShutterButtonStyle: ButtonStyle {
    var isBusy: Bool

    func makeBody(configuration: Configuration) -> some View {
        ZStack {
            Circle()
                .strokeBorder(.white, lineWidth: 4)
                .frame(width: 78, height: 78)
            Circle()
                .fill(.white)
                .frame(width: 64, height: 64)
                .scaleEffect(configuration.isPressed ? 0.86 : (isBusy ? 0.9 : 1))
                .opacity(isBusy ? 0.75 : 1)
        }
        .frame(width: 84, height: 84)
        .contentShape(Circle())
        .animation(.spring(response: 0.22, dampingFraction: 0.65), value: configuration.isPressed)
        .animation(.easeInOut(duration: 0.2), value: isBusy)
    }
}
