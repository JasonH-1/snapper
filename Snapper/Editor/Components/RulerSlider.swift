import SwiftUI

/// A tick ruler that slides under a fixed yellow pointer, like Photos'
/// adjustment dials. Ticks between zero and the pointer light up; double-tap
/// returns to zero.
struct RulerSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    /// The value between two ticks.
    var tickStep: Double
    /// Every this many ticks is a long one.
    var majorEvery = 5
    var spacing: CGFloat = 9
    var onEditingChanged: (Bool) -> Void = { _ in }

    @State private var dragStartValue: Double?

    var body: some View {
        Canvas { context, size in
            let midX = size.width / 2
            let midY = size.height / 2
            let first = Int((range.lowerBound / tickStep).rounded(.up))
            let last = Int((range.upperBound / tickStep).rounded(.down))
            for index in first...last {
                let tickValue = Double(index) * tickStep
                let x = midX + CGFloat((tickValue - value) / tickStep) * spacing
                guard x > -2, x < size.width + 2 else { continue }
                let isMajor = index % majorEvery == 0
                let isZero = index == 0
                let height: CGFloat = isZero ? size.height * 0.85 : (isMajor ? size.height * 0.62 : size.height * 0.36)
                let lit = isBetweenZeroAndValue(tickValue)
                let color: Color = lit ? Theme.accent : .white.opacity(isMajor ? 0.75 : 0.35)
                // Fade out towards the edges.
                let fade = min(1, min(x, size.width - x) / 40)
                var tick = Path()
                tick.addRoundedRect(in: CGRect(x: x - 1, y: midY - height / 2, width: 2, height: height),
                                    cornerSize: CGSize(width: 1, height: 1))
                context.fill(tick, with: .color(color.opacity(fade)))
            }
            var pointer = Path()
            pointer.addRoundedRect(in: CGRect(x: midX - 1.5, y: 0, width: 3, height: size.height),
                                   cornerSize: CGSize(width: 1.5, height: 1.5))
            context.fill(pointer, with: .color(Theme.accent))
        }
        .contentShape(Rectangle())
        .gesture(drag)
        .onTapGesture(count: 2) {
            withAnimation(.easeOut(duration: 0.2)) { value = 0 }
            onEditingChanged(false)
        }
        .sensoryFeedback(.selection, trigger: isAtZero) { _, atZero in atZero }
        .sensoryFeedback(.impact(weight: .light), trigger: isAtEnd) { _, atEnd in atEnd }
        .accessibilityElement()
        .accessibilityValue(Text(value, format: .number.precision(.fractionLength(0...1))))
        .accessibilityAdjustableAction { direction in
            let delta = tickStep * (direction == .increment ? 1 : -1)
            value = min(max(value + delta, range.lowerBound), range.upperBound)
            onEditingChanged(false)
        }
    }

    private var isAtZero: Bool { abs(value) < tickStep / 2 }
    private var isAtEnd: Bool { value <= range.lowerBound || value >= range.upperBound }

    private func isBetweenZeroAndValue(_ tick: Double) -> Bool {
        let low = min(0, value), high = max(0, value)
        return tick >= low - 1e-9 && tick <= high + 1e-9 && abs(value) >= tickStep / 2
    }

    private var drag: some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { gesture in
                if dragStartValue == nil {
                    dragStartValue = value
                    onEditingChanged(true)
                }
                let start = dragStartValue ?? value
                // Dragging left moves the ruler left: the value goes up.
                var next = start - Double(gesture.translation.width / spacing) * tickStep
                // A little stickiness at zero.
                if abs(next) < tickStep * 0.4 { next = 0 }
                value = min(max(next, range.lowerBound), range.upperBound)
            }
            .onEnded { _ in
                dragStartValue = nil
                onEditingChanged(false)
            }
    }
}
