import SwiftUI

/// The editor's slider: one row with the name, a thin track that fills from
/// its origin (the middle, for −1…1 controls) to a small white handle, and
/// the value in figures. A gradient track shows what the slider does instead
/// (hue, saturation, warmth). Drag anywhere along it to move the value from
/// where it is, so a touch never makes it jump; it settles on the origin as
/// it passes; double-tap returns to its default.
struct ProSlider: View {
    let title: String
    @Binding var value: Double
    var range: ClosedRange<Double> = -1...1
    /// Where the fill starts and double-tap returns to. By default 0 when
    /// the range includes it, otherwise the lower bound.
    var origin: Double?
    /// What double-tap returns to, and where the value reads as unchanged.
    /// By default the origin.
    var defaultValue: Double?
    var gradient: [Color]?
    var format: (Double) -> String = ProSlider.signed
    var onEditingChanged: (Bool) -> Void = { _ in }

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dragStart: Double?
    /// Resets on its own when a drag ends or is cancelled (say, by a scroll
    /// view taking the touch), so the slider is never left held.
    @GestureState private var isDragging = false

    private static let thumbSize: CGFloat = 22

    private var span: Double { max(range.upperBound - range.lowerBound, .ulpOfOne) }
    private var resolvedOrigin: Double { origin ?? (range.contains(0) ? 0 : range.lowerBound) }
    private var resolvedDefault: Double { defaultValue ?? resolvedOrigin }
    private var isAtOrigin: Bool { abs(value - resolvedOrigin) < span * 0.002 }
    private var isAtDefault: Bool { abs(value - resolvedDefault) < span * 0.002 }
    private var isAtEnd: Bool { value <= range.lowerBound || value >= range.upperBound }
    /// Whether the origin is inside the track rather than at an end.
    private var isBipolar: Bool { resolvedOrigin > range.lowerBound && resolvedOrigin < range.upperBound }

    var body: some View {
        HStack(spacing: 10) {
            Text(title)
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.85))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(width: 84, alignment: .leading)
            track
            Text(format(value))
                .font(.subheadline.weight(.medium).monospacedDigit())
                .foregroundStyle(isAtDefault ? Color.secondary : Theme.accent)
                .lineLimit(1)
                .frame(minWidth: 44, alignment: .trailing)
        }
        .frame(minHeight: 32)
        .opacity(isEnabled ? 1 : 0.4)
        .sensoryFeedback(.selection, trigger: isAtOrigin) { _, atOrigin in atOrigin && isBipolar }
        .sensoryFeedback(.impact(weight: .light), trigger: isAtEnd) { _, atEnd in atEnd }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(title))
        .accessibilityValue(Text(format(value)))
        .accessibilityAdjustableAction { direction in
            let step = span / 40 * (direction == .increment ? 1 : -1)
            value = min(max(value + step, range.lowerBound), range.upperBound)
            onEditingChanged(false)
        }
        .accessibilityAction(named: Text("Reset")) { reset() }
    }

    private var track: some View {
        GeometryReader { geometry in
            let inset = Self.thumbSize / 2
            let usable = max(geometry.size.width - inset * 2, 1)
            let midY = geometry.size.height / 2
            let position = { (value: Double) -> CGFloat in
                inset + CGFloat((min(max(value, range.lowerBound), range.upperBound) - range.lowerBound) / span) * usable
            }
            let originX = position(resolvedOrigin), valueX = position(value)

            ZStack(alignment: .topLeading) {
                if let gradient {
                    Capsule()
                        .fill(LinearGradient(colors: gradient, startPoint: .leading, endPoint: .trailing))
                        .frame(width: usable, height: 5)
                        .position(x: inset + usable / 2, y: midY)
                } else {
                    Capsule()
                        .fill(.white.opacity(0.14))
                        .frame(width: usable, height: 3)
                        .position(x: inset + usable / 2, y: midY)
                    Capsule()
                        .fill(Theme.accent)
                        .frame(width: abs(valueX - originX), height: 3)
                        .position(x: (valueX + originX) / 2, y: midY)
                }
                if isBipolar {
                    Capsule()
                        .fill(.white.opacity(0.45))
                        .frame(width: 1.5, height: 9)
                        .position(x: originX, y: midY)
                }
                Circle()
                    .fill(.white)
                    .overlay(Circle().strokeBorder(.black.opacity(0.18), lineWidth: 0.5))
                    .frame(width: Self.thumbSize, height: Self.thumbSize)
                    .shadow(color: .black.opacity(0.4), radius: 2.5, y: 1)
                    .scaleEffect(dragStart == nil ? 1 : 1.15)
                    .position(x: valueX, y: midY)
                    .animation(.snapper(Motion.quick, reduceMotion: reduceMotion), value: dragStart == nil)
            }
            .contentShape(Rectangle())
            .gesture(drag(usable: usable))
        }
        .frame(height: 32)
        .onTapGesture(count: 2) { reset() }
        .onChange(of: isDragging) { _, dragging in
            if !dragging { endDrag() }
        }
    }

    private func drag(usable: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .updating($isDragging) { _, dragging, _ in dragging = true }
            .onChanged { gesture in
                guard isEnabled else { return }
                if dragStart == nil {
                    dragStart = value
                    onEditingChanged(true)
                }
                var next = (dragStart ?? value) + Double(gesture.translation.width / usable) * span
                // A little stickiness at the origin, so it's easy to find again.
                if isBipolar, abs(next - resolvedOrigin) < span * 0.012 { next = resolvedOrigin }
                value = min(max(next, range.lowerBound), range.upperBound)
            }
            .onEnded { _ in endDrag() }
    }

    private func endDrag() {
        guard dragStart != nil else { return }
        dragStart = nil
        onEditingChanged(false)
    }

    private func reset() {
        guard isEnabled, !isAtDefault else { return }
        withAnimation(.snapper(Motion.standard, reduceMotion: reduceMotion)) { value = resolvedDefault }
        onEditingChanged(false)
    }
}

extension ProSlider {
    /// "+12", "−8", "0", for −1…1 controls.
    nonisolated static func signed(_ value: Double) -> String {
        let number = Int((value * 100).rounded())
        if number > 0 { return "+\(number)" }
        if number < 0 { return "−\(-number)" }
        return "0"
    }

    /// "64%".
    nonisolated static func percent(_ value: Double) -> String { "\(Int((value * 100).rounded()))%" }
}

/// Shows its content as it is when it fits the space, and scrolls it
/// (for the largest text sizes) when it doesn't.
struct FitOrScroll<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        ViewThatFits(in: .vertical) {
            content
            ScrollView { content }
        }
    }
}
