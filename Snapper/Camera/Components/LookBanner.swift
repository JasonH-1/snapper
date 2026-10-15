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
                        .foregroundStyle(Theme.premiumGradient)
                        .accessibilityLabel(Text("Premium look"))
                }
            }
        }
        .shadow(color: .black.opacity(0.45), radius: 12, y: 2)
        .padding(.horizontal, 24)
        .accessibilityElement(children: .combine)
    }
}

/// Small persistent label under the preview naming the current look.
struct LookCaption: View {
    let look: Look
    let collectionName: String?
    let isLocked: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "chevron.compact.left")
                .foregroundStyle(.white.opacity(0.35))
            HStack(spacing: 6) {
                if isLocked {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Theme.premiumGradient)
                }
                Text(look.name)
                    .font(Theme.lookTitle(size: 17))
                    .foregroundStyle(.white)
                if let collectionName {
                    Text(collectionName)
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.5))
                }
            }
            .contentTransition(.opacity)
            Image(systemName: "chevron.compact.right")
                .foregroundStyle(.white.opacity(0.35))
        }
        .lineLimit(1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Look: \(look.name)"))
        .accessibilityValue(isLocked ? Text("Premium") : Text(""))
        .accessibilityHint(Text("Swipe left or right on the preview to change the look."))
    }
}
