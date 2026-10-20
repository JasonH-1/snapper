import SwiftUI

/// The look's name, shown large in the middle of the preview for a moment
/// after it changes.
struct LookBanner: View {
    let look: Look
    let collectionName: String?
    let isLocked: Bool

    var body: some View {
        VStack(spacing: 6) {
            if let collectionName {
                Text(collectionName.uppercased())
                    .font(.caption.weight(.semibold))
                    .tracking(2.5)
                    .foregroundStyle(.white.opacity(0.8))
            }
            HStack(spacing: 10) {
                Text(look.name)
                    .font(Theme.lookTitle(size: 38))
                    .foregroundStyle(.white)
                if isLocked {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                        .accessibilityLabel(Text("Premium look"))
                }
            }
        }
        .shadow(color: .black.opacity(0.45), radius: 12, y: 2)
        .padding(.horizontal, 24)
        .accessibilityElement(children: .combine)
    }
}

/// The yellow hairline tag in the camera's top bar while a Premium look or
/// style is on without Premium.
struct PremiumTag: View {
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
        HStack(spacing: 6) {
            Image(systemName: "lock.fill")
            Text("Premium")
        }
        .font(.system(.footnote, design: .monospaced, weight: .semibold))
        .textCase(.uppercase)
        .foregroundStyle(Theme.accent)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Theme.accent.opacity(0.1), in: shape)
        .overlay(shape.strokeBorder(Theme.accent.opacity(0.8), lineWidth: 1))
    }
}
