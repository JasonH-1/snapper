import SwiftUI

/// The shutter: a white release inside a dial bezel of tick marks. The
/// release dips and the bezel turns a notch when pressed. While the
/// self-timer counts down, the release becomes a stop square (tap to cancel).
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

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        ZStack {
            TickBezel()
                .rotationEffect(.degrees(configuration.isPressed && !reduceMotion ? 6 : 0))
            Circle()
                .strokeBorder(.white.opacity(0.9), lineWidth: 1.5)
                .frame(width: 70, height: 70)
            RoundedRectangle(cornerRadius: isCountingDown ? 8 : 29, style: .continuous)
                .fill(isCountingDown
                      ? AnyShapeStyle(Theme.accent)
                      : AnyShapeStyle(LinearGradient(colors: [.white, Color(white: 0.89)], startPoint: .top, endPoint: .bottom)))
                .frame(width: isCountingDown ? 30 : 58, height: isCountingDown ? 30 : 58)
                .scaleEffect(configuration.isPressed ? 0.88 : (isBusy ? 0.9 : 1))
                .opacity(isBusy ? 0.75 : 1)
        }
        .frame(width: 86, height: 86)
        .contentShape(Circle())
        .animation(.spring(response: 0.22, dampingFraction: 0.65), value: configuration.isPressed)
        .animation(.easeInOut(duration: 0.2), value: isBusy)
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: isCountingDown)
    }
}

/// Sixty ticks around the shutter, every fifth one longer, like the bezel
/// of a dial.
private struct TickBezel: View {
    var body: some View {
        Canvas { context, size in
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let outer = min(size.width, size.height) / 2 - 1
            for index in 0..<60 {
                let isMajor = index % 5 == 0
                let angle = Double(index) / 60 * 2 * .pi - .pi / 2
                let inner = outer - (isMajor ? 7 : 4)
                var tick = Path()
                tick.move(to: CGPoint(x: center.x + inner * cos(angle), y: center.y + inner * sin(angle)))
                tick.addLine(to: CGPoint(x: center.x + outer * cos(angle), y: center.y + outer * sin(angle)))
                context.stroke(tick, with: .color(.white.opacity(isMajor ? 0.85 : 0.35)), lineWidth: isMajor ? 1.6 : 1)
            }
        }
        .accessibilityHidden(true)
    }
}
