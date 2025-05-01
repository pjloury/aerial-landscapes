class PlayerContainerView: UIView {
    private var playerLayer: AVPlayerLayer?
    
    var player: AVPlayer? {
        didSet {
            playerLayer?.player = player
        }
    }
    
    override init(frame: CGRect) {
        super.init(frame: frame)
        setupPlayerLayer()
    }
    
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupPlayerLayer()
    }
    
    private func setupPlayerLayer() {
        let layer = AVPlayerLayer()
        layer.videoGravity = .resizeAspectFill
        self.layer.addSublayer(layer)
        self.playerLayer = layer
    }
    
    override func layoutSubviews() {
        super.layoutSubviews()
        playerLayer?.frame = bounds
    }
}

struct VideoPlayerView: UIViewControllerRepresentable {
    let player: AVPlayer
    
    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = player
        controller.showsPlaybackControls = false
        controller.videoGravity = .resizeAspectFill
        return controller
    }
    
    func updateUIViewController(_ uiViewController: AVPlayerViewController, context: Context) {
        // No updates needed
    }
}

struct NowPlayingView: View {
    @ObservedObject var videoPlayerModel: VideoPlayerModel
    
    var body: some View {
        ZStack {
            VideoPlayerView(player: videoPlayerModel.player)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .edgesIgnoringSafeArea(.all)
            
            // Show message when no videos are selected
            if videoPlayerModel.selectedPlaylist.isEmpty {
                Text("Head to More Videos to get started")
                    .font(.system(size: 30, weight: .medium))
                    .foregroundColor(.white)
                    .shadow(color: .black.opacity(0.8), radius: 6, x: 0, y: 2)
            }
            
            // Title overlay
            if !videoPlayerModel.selectedPlaylist.isEmpty {
                VStack {
                    Spacer()
                    HStack {
                        Text(videoPlayerModel.currentVideoTitle)
                            .font(.system(.callout, design: .default))
                            .foregroundColor(.white)
                            .shadow(color: .black.opacity(0.8), radius: 6, x: 0, y: 2)
                            .shadow(color: .black.opacity(0.6), radius: 4, x: 0, y: 1)
                            .padding(.leading, 60)
                            .padding(.bottom, 60)
                        Spacer()
                    }
                }
            }
        }
    }
} 