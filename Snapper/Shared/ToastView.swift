import SwiftUI

/// Compact message capsule shown at the top of the camera.
struct ToastView: View {
    let toast: Toast
    var onAction: (Toast.Action) -> Void
    var onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: toast.symbol)
                .foregroundStyle(toast.action == .showPaywall ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(.white))
            Text(toast.message)
                .font(.footnote.weight(.medium))
                .foregroundStyle(.white)
                .fixedSize(horizontal: false, vertical: true)
            if let action = toast.action, let title = toast.actionTitle {
                Button {
                    onAction(action)
                } label: {
                    Text(title)
                        .font(.footnote.weight(.bold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(action == .showPaywall ? Theme.accent : .white, in: Capsule())
                        .foregroundStyle(.black)
                }
            }
        }
        .padding(.leading, 14)
        .padding(.trailing, toast.action == nil ? 14 : 8)
        .padding(.vertical, 10)
        .background(.black.opacity(0.78), in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.12), lineWidth: 1))
        .padding(.horizontal, 16)
        .onTapGesture(perform: onDismiss)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isStaticText)
    }
}
