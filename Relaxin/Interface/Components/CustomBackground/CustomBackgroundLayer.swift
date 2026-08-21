import AVFoundation
import SwiftUI

/// A full-bleed background layer driven by `CustomBackgroundStore`.
/// Renders an image or a looping muted video behind the terminal content.
struct CustomBackgroundLayer: View {
    var body: some View {
        Group {
            switch CustomBackgroundStore.kind {
            case .none:
                Color.clear
            case .image:
                if let url = CustomBackgroundStore.storedURL,
                   let image = UIImage(contentsOfFile: url.path) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .ignoresSafeArea()
                        .opacity(0.35)
                } else {
                    Color.clear
                }
            case .video:
                if let url = CustomBackgroundStore.storedURL {
                    RelaxinVideoBackground(url: url)
                        .ignoresSafeArea()
                        .opacity(0.35)
                } else {
                    Color.clear
                }
            }
        }
    }
}

/// Looping, muted AVPlayer background used for video payloads.
private struct RelaxinVideoBackground: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> RelaxinVideoBackgroundView {
        let view = RelaxinVideoBackgroundView()
        view.configure(url: url)
        return view
    }

    func updateUIView(_ uiView: RelaxinVideoBackgroundView, context: Context) {}
}

private final class RelaxinVideoBackgroundView: UIView {
    private let player = AVPlayer()
    private var playerLayer: AVPlayerLayer?

    func configure(url: URL) {
        player.replaceCurrentItem(with: AVPlayerItem(url: url))
        player.isMuted = true
        player.actionAtItemEnd = .none
        player.play()

        if playerLayer == nil {
            let layer = AVPlayerLayer(player: player)
            layer.videoGravity = .resizeAspectFill
            layer.frame = bounds
            self.layer.addSublayer(layer)
            playerLayer = layer
        }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(playerItemDidReachEnd(_:)),
            name: .AVPlayerItemDidPlayToEndTime,
            object: player.currentItem
        )
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        playerLayer?.frame = bounds
    }

    @objc private func playerItemDidReachEnd(_ notification: Notification) {
        player.seek(to: .zero)
        player.play()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        player.pause()
    }
}
