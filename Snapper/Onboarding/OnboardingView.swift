import AVFoundation
import SwiftUI

/// First-run introduction: what the looks do, how to switch them, then the
/// camera and photo library permissions, each explained before the system
/// asks. Buttons say "Continue" rather than "Allow" per App Review guidance.
struct OnboardingView: View {
    let library: LookLibrary
    let renderer: PhotoRenderer
    var onFinish: () -> Void

    @State private var page = 0
    @State private var heroPair: (before: UIImage, after: UIImage)?
    @State private var collectionCards: [(name: String, look: String, image: UIImage)] = []
    @State private var cameraStatus = AVCaptureDevice.authorizationStatus(for: .video)
    @State private var photosAllowed = PhotoLibrarySaver.isAuthorized
    @State private var photosAsked = !PhotoLibrarySaver.canAsk

    private let pageCount = 3

    var body: some View {
        VStack(spacing: 0) {
            TabView(selection: $page) {
                introPage.tag(0)
                swipePage.tag(1)
                permissionsPage.tag(2)
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .animation(.easeInOut, value: page)

            controls
        }
        .background(Color(.systemBackground).ignoresSafeArea())
        .task { await loadImages() }
        .sensoryFeedback(.selection, trigger: page)
    }

    // MARK: - Pages

    private var introPage: some View {
        VStack(spacing: 28) {
            Group {
                if let heroPair {
                    BeforeAfterView(before: heroPair.before, after: heroPair.after)
                } else {
                    Rectangle().fill(.quaternary).overlay { ProgressView() }
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 420)
            .clipShape(RoundedRectangle(cornerRadius: Theme.cardCornerRadius, style: .continuous))
            .padding(.horizontal, 24)

            pageText(title: Text("Find your look"),
                     detail: Text("See your scene through each look before you take the shot. Start with \(library.freeLooks.count - 1) free looks and save without a watermark."))
        }
        .padding(.top, 24)
    }

    private var swipePage: some View {
        VStack(spacing: 28) {
            ZStack {
                ForEach(Array(collectionCards.enumerated()), id: \.offset) { index, card in
                    collectionCard(card, index: index)
                }
                if collectionCards.isEmpty {
                    ProgressView()
                }
            }
            .frame(height: 420)

            pageText(title: Text("Swipe to change the mood"),
                     detail: Text("Choose a look for your day, star your favorites, or save your own style in Presets. Shoot with it and reuse it on imported photos."))
        }
        .padding(.top, 24)
    }

    private func collectionCard(_ card: (name: String, look: String, image: UIImage), index: Int) -> some View {
        let offset = CGFloat(index - 1)
        return Image(uiImage: card.image)
            .resizable()
            .scaledToFill()
            .frame(width: 210, height: 300)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(alignment: .bottomLeading) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(card.name.uppercased())
                        .font(.caption2.weight(.bold))
                        .tracking(1.5)
                    Text(card.look)
                        .font(Theme.lookTitle(size: 20))
                }
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.5), radius: 6)
                .padding(12)
            }
            .shadow(color: .black.opacity(0.25), radius: 14, y: 8)
            .rotationEffect(.degrees(Double(offset) * 8))
            .offset(x: offset * 78, y: abs(offset) * 18)
            .zIndex(index == 1 ? 1 : 0)
            .accessibilityLabel(Text("\(card.name): \(card.look)"))
    }

    private var permissionsPage: some View {
        VStack(alignment: .leading, spacing: 24) {
            Spacer(minLength: 12)
            VStack(alignment: .leading, spacing: 10) {
                Text("Ready when you are")
                    .font(Theme.lookTitle(size: 32))
                Text("Snapper works entirely on your iPhone. It needs two permissions:")
                    .font(.body)
                    .foregroundStyle(.secondary)
            }
            permissionRow(symbol: "camera.fill",
                          title: Text("Camera"),
                          detail: Text("To show your scene through each look and take photos."),
                          state: cameraState,
                          action: { requestCamera() })
            permissionRow(symbol: "photo.on.rectangle",
                          title: Text("Photos"),
                          detail: Text("To save your shots to your library. Importing only opens photos you choose."),
                          state: photosState,
                          action: { requestPhotos() })
            Text("You can change these anytime in the Settings app.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 28)
    }

    private enum PermissionState {
        case notAsked, allowed, declined
    }

    private var cameraState: PermissionState {
        switch cameraStatus {
        case .authorized: .allowed
        case .notDetermined: .notAsked
        default: .declined
        }
    }

    private var photosState: PermissionState {
        if photosAllowed { return .allowed }
        return photosAsked ? .declined : .notAsked
    }

    private func permissionRow(symbol: String, title: Text, detail: Text, state: PermissionState, action: @escaping () -> Void) -> some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(Theme.accent)
                .frame(width: 44, height: 44)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                title.font(.headline)
                detail.font(.footnote).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            switch state {
            case .notAsked:
                Button("Continue", action: action)
                    .font(.subheadline.weight(.semibold))
                    .buttonStyle(.borderedProminent)
                    .tint(.primary)
                    .foregroundStyle(Color(.systemBackground))
            case .allowed:
                Image(systemName: "checkmark.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.green)
                    .accessibilityLabel(Text("Allowed"))
            case .declined:
                Text("Off")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func pageText(title: Text, detail: Text) -> some View {
        VStack(spacing: 10) {
            title
                .font(Theme.lookTitle(size: 30))
                .multilineTextAlignment(.center)
            detail
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 32)
    }

    // MARK: - Controls

    private var controls: some View {
        VStack(spacing: 18) {
            HStack(spacing: 8) {
                ForEach(0..<pageCount, id: \.self) { index in
                    Capsule()
                        .fill(index == page ? Color.primary : Color.secondary.opacity(0.35))
                        .frame(width: index == page ? 20 : 7, height: 7)
                }
            }
            .animation(.spring(response: 0.3, dampingFraction: 0.8), value: page)
            .accessibilityHidden(true)

            Button {
                if page < pageCount - 1 {
                    withAnimation { page += 1 }
                } else {
                    onFinish()
                }
            } label: {
                Text(page < pageCount - 1 ? "Next" : "Start Shooting")
            }
            .buttonStyle(PrimaryButtonStyle())
            .padding(.horizontal, 24)
        }
        .padding(.bottom, 16)
    }

    // MARK: - Permissions

    private func requestCamera() {
        Task {
            _ = await AVCaptureDevice.requestAccess(for: .video)
            cameraStatus = AVCaptureDevice.authorizationStatus(for: .video)
        }
    }

    private func requestPhotos() {
        Task {
            photosAllowed = await PhotoLibrarySaver.requestAccess()
            photosAsked = true
        }
    }

    // MARK: - Images

    private func loadImages() async {
        guard heroPair == nil,
              let photo = Bundle.main.url(forResource: "showcase-cafe", withExtension: "jpg") else { return }
        let signature = library.look(id: "boardwalk") ?? library.looks.dropFirst().first ?? .original
        if let before = await renderer.showcase(url: photo, look: .original),
           let after = await renderer.showcase(url: photo, look: signature) {
            heroPair = (before, after)
        }
        var cards: [(name: String, look: String, image: UIImage)] = []
        let picks = ["postcard", "afterglow", "cream"]
        for (index, collection) in library.collections.prefix(3).enumerated() {
            let look = library.look(id: picks[index]).flatMap { $0.collectionID == collection.id ? $0 : nil }
                ?? library.looks.first { $0.collectionID == collection.id }
            guard let look, let image = await renderer.showcase(url: photo, look: look, maxPixelSize: 800) else { continue }
            cards.append((collection.name, look.name, image))
        }
        collectionCards = cards
    }
}
