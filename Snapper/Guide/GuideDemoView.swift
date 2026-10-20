import AVFoundation
import SwiftUI

/// A short recording of the feature being used in Snapper, looping without
/// sound like a GIF. Clips are bundled as `guide-<topic id>.mp4` and made by
/// scripts/record-guide-demo.sh.
struct GuideDemoView: View {
    let url: URL
    let title: String

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var loop: GuideLoop?
    @State private var isPlaying = false

    /// Bundled clip for a topic, if one has been recorded.
    static func url(for topic: GuideTopic) -> URL? {
        Bundle.main.url(forResource: "guide-\(topic.id)", withExtension: "mp4")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("SEE IT IN SNAPPER").font(.caption.weight(.bold)).foregroundStyle(Theme.accent)
            ZStack {
                Theme.canvas
                if let loop { PlayerLayerView(player: loop.player) }
            }
            // The clips are 4:5, the phone on a backdrop.
            .aspectRatio(4.0 / 5.0, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                if !isPlaying {
                    Image(systemName: "play.fill")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 56, height: 56)
                        .background(.black.opacity(0.55), in: Circle())
                        .accessibilityHidden(true)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { toggle() }
            .accessibilityElement()
            .accessibilityLabel(Text("Video of \(title) in Snapper"))
            .accessibilityValue(isPlaying ? Text("Playing") : Text("Paused"))
            .accessibilityAddTraits(.startsMediaSession)
            .accessibilityAction { toggle() }
        }
        .padding(16)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 20))
        .onAppear {
            if loop == nil { loop = GuideLoop(url: url) }
            // With Reduce Motion the clip waits to be played.
            if !reduceMotion { play() }
        }
        .onDisappear { pause() }
    }

    private func toggle() { isPlaying ? pause() : play() }

    private func play() {
        loop?.player.play()
        isPlaying = true
    }

    private func pause() {
        loop?.player.pause()
        isPlaying = false
    }
}

/// Plays one clip over and over, silently.
@MainActor
private final class GuideLoop {
    let player = AVQueuePlayer()
    private let looper: AVPlayerLooper

    init(url: URL) {
        player.isMuted = true
        player.preventsDisplaySleepDuringVideoPlayback = false
        looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(url: url))
    }
}

private struct PlayerLayerView: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> PlayerView {
        let view = PlayerView()
        view.playerLayer.player = player
        view.playerLayer.videoGravity = .resizeAspect
        return view
    }

    func updateUIView(_ view: PlayerView, context: Context) {
        view.playerLayer.player = player
    }

    final class PlayerView: UIView {
        override static var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }
}
