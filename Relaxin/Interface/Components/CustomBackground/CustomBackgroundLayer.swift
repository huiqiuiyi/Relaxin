import AVFoundation
import SwiftUI

/// A full-bleed background layer driven by `CustomBackgroundStore`.
/// Renders an image or a looping muted video as the app's wallpaper,
/// replacing the default white background. The terminal character
/// decoration (rendered by `TerminalCharacterBackground`) stays on top.
struct CustomBackgroundLayer: View {
    var body: some View {
        Group {
            switch CustomBackgroundStore.kind {
            case .none:
                // No custom wallpaper: keep the default solid background.
                SwiftUI.Color.clear
            case .image:
                if let url = CustomBackgroundStore.storedURL,
                   let image = UIImage(contentsOfFile: url.path) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .ignoresSafeArea()
                        // Keep terminal text readable on the wallpaper.
                        .overlay {
                            SwiftUI.Color.black.opacity(0.25)
                        }
                } else {
                    SwiftUI.Color.clear
                }
            case .video:
                if let url = CustomBackgroundStore.storedURL {
                    RelaxinVideoBackground(url: url)
                        .ignoresSafeArea()
                        // Keep terminal text readable on the wallpaper.
                        .overlay {
                            SwiftUI.Color.black.opacity(0.25)
                        }
                } else {
                    SwiftUI.Color.clear
                }
            }
        }
        .ignoresSafeArea()
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
