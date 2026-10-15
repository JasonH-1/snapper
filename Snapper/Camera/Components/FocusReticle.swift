import SwiftUI

/// The square that appears where you tap to focus.
struct FocusReticle: View {
    @State private var settled = false

    var body: some View {
        RoundedRectangle(cornerRadius: 4, style: .continuous)
            .strokeBorder(Theme.accent, lineWidth: 1.5)
            .frame(width: 76, height: 76)
            .scaleEffect(settled ? 1 : 1.35)
            .opacity(settled ? 0.9 : 0)
            .onAppear {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) { settled = true }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}
