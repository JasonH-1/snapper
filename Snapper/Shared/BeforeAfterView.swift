import SwiftUI

/// Two versions of a photo split by a draggable divider: the original on the
/// left, the look on the right. When `autoSweep` is on, the divider glides
/// back and forth until the person touches it.
struct BeforeAfterView: View {
    let before: UIImage
    let after: UIImage
    var autoSweep = true
    var showsLabels = true

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var position: CGFloat = 0.5
    @State private var userControlled = false
    @State private var sweepTask: Task<Void, Never>?

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            ZStack(alignment: .leading) {
                image(after, size: geometry.size)
                image(before, size: geometry.size)
                    .mask(alignment: .leading) {
                        Rectangle().frame(width: max(0, width * position))
                    }
                divider(height: geometry.size.height)
                    .offset(x: width * position - 1)
                if showsLabels {
                    labels
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if !userControlled {
                            userControlled = true
                            sweepTask?.cancel()
                        }
                        var transaction = Transaction()
                        transaction.disablesAnimations = true
                        withTransaction(transaction) {
                            position = min(max(value.location.x / max(width, 1), 0.02), 0.98)
                        }
                    }
            )
        }
        .onAppear { startSweep() }
        .onDisappear { sweepTask?.cancel() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Before and after comparison"))
        .accessibilityAdjustableAction { direction in
            userControlled = true
            sweepTask?.cancel()
            switch direction {
            case .increment: position = min(position + 0.1, 0.98)
            case .decrement: position = max(position - 0.1, 0.02)
            @unknown default: break
            }
        }
    }

    private func image(_ uiImage: UIImage, size: CGSize) -> some View {
        Image(uiImage: uiImage)
            .resizable()
            .scaledToFill()
            .frame(width: size.width, height: size.height)
            .clipped()
    }

    private func divider(height: CGFloat) -> some View {
        ZStack {
            Rectangle()
                .fill(Theme.accent)
                .frame(width: 2, height: height)
                .shadow(color: .black.opacity(0.35), radius: 3)
            Circle()
                .fill(Theme.accent)
                .frame(width: 30, height: 30)
                .shadow(color: .black.opacity(0.3), radius: 4)
                .overlay {
                    Image(systemName: "chevron.left.chevron.right")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.black)
                }
                .offset(x: 0)
        }
        .frame(width: 2)
    }

    private var labels: some View {
        VStack {
            HStack {
                label("Before")
                Spacer()
                label("After")
            }
            Spacer()
        }
        .padding(12)
        .allowsHitTesting(false)
    }

    private func label(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .font(.caption2.weight(.bold))
            .textCase(.uppercase)
            .tracking(1.2)
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.black.opacity(0.45), in: Capsule())
    }

    private func startSweep() {
        guard autoSweep, !userControlled, !reduceMotion else { return }
        sweepTask?.cancel()
        sweepTask = Task { @MainActor in
            var target: CGFloat = 0.78
            while !Task.isCancelled {
                withAnimation(.easeInOut(duration: 1.8)) { position = target }
                try? await Task.sleep(for: .seconds(2.4))
                target = target > 0.5 ? 0.22 : 0.78
            }
        }
    }
}
