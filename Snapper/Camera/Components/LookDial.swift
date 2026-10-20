import SwiftUI

/// The camera's look selector, drawn as a dial: a mono readout of where the
/// look sits in its collection, its name in the serif, and a scale with a
/// tick per look whose amber needle slides to the current one.
struct LookDial: View {
    let look: Look
    let collectionName: String?
    /// The look's place in its collection, or nil for Original.
    let position: Int?
    let count: Int
    /// Shows the chevron that says a tap opens the look picker. The Lock
    /// Screen camera has no picker: its looks change by swiping the preview.
    var opensPicker = true

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(readout).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                if let collectionName {
                    Text(collectionName)
                        .foregroundStyle(Theme.accent)
                        .shadow(color: Theme.accent.opacity(0.45), radius: 4)
                }
            }
            .font(.system(.caption2, design: .monospaced, weight: .medium))
            .textCase(.uppercase)
            .lineLimit(1)
            HStack(spacing: 6) {
                Text(look.name)
                    .font(Theme.lookName(.headline))
                    .lineLimit(1)
                    .contentTransition(.opacity)
                Spacer(minLength: 0)
                if opensPicker {
                    Image(systemName: "chevron.down")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                }
            }
            DialScale(position: position, count: count)
                .frame(height: 9)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .dialPanel()
    }

    private var readout: String {
        guard let position, count > 0 else { return String(localized: "No look") }
        return String(localized: "Look \(Self.twoDigits(position + 1))/\(Self.twoDigits(count))")
    }

    private static func twoDigits(_ value: Int) -> String {
        value < 10 ? "0\(value)" : "\(value)"
    }

    /// Where `look` sits among the looks of its collection, in catalog order.
    nonisolated static func position(of look: Look, in library: LookLibrary) -> (index: Int, count: Int)? {
        guard let collectionID = look.collectionID else { return nil }
        let siblings = library.looks.filter { $0.collectionID == collectionID }
        guard let index = siblings.firstIndex(where: { $0.id == look.id }) else { return nil }
        return (index, siblings.count)
    }
}

/// Fine ticks, a taller tick for each look in the collection, and the amber
/// needle on the current one.
private struct DialScale: View {
    let position: Int?
    let count: Int

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width, height = geometry.size.height
            Canvas { context, size in
                var x: CGFloat = 1
                while x < size.width {
                    context.fill(Path(CGRect(x: x, y: size.height * 0.45, width: 1, height: size.height * 0.55)),
                                 with: .color(.white.opacity(0.22)))
                    x += 6
                }
                for index in 0..<max(count, 0) {
                    context.fill(Path(CGRect(x: Self.majorX(index, count: count, width: size.width) - 0.5, y: 0,
                                             width: 1, height: size.height)),
                                 with: .color(.white.opacity(0.6)))
                }
            }
            if let position, count > 0 {
                Capsule()
                    .fill(Theme.accent)
                    .frame(width: 2, height: height + 4)
                    .shadow(color: Theme.accent.opacity(0.6), radius: 3)
                    .position(x: Self.majorX(position, count: count, width: width), y: height / 2)
                    .animation(.snapper(Motion.standard, reduceMotion: reduceMotion), value: position)
            }
        }
        .accessibilityHidden(true)
    }

    private static func majorX(_ index: Int, count: Int, width: CGFloat) -> CGFloat {
        guard count > 1 else { return width / 2 }
        return 6 + (width - 12) * CGFloat(index) / CGFloat(count - 1)
    }
}

extension View {
    /// The dial's panel: near-black with a hairline edge, like an instrument.
    func dialPanel(cornerRadius: CGFloat = 12) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return background(Color(red: 0.055, green: 0.055, blue: 0.063), in: shape)
            .overlay(shape.strokeBorder(.white.opacity(0.16), lineWidth: 1))
    }
}
