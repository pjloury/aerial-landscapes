import SwiftUI
import AVKit

class VideoPlayerModel: NSObject, ObservableObject {
    @Published var currentVideoTitle: String = ""
    let player: AVQueuePlayer
    @Published var videos: [VideoItem] = []  // Local videos only
    private var currentPlaylist: [VideoItem] = []
    private let selectedVideoIdsKey = "selectedVideoIds"
    
    struct VideoItem: Identifiable {
        let id = UUID()
        let url: URL
        let title: String
        let isLocal: Bool
        let thumbnailURL: URL?
        
        init(url: URL, title: String, isLocal: Bool, thumbnailURL: URL? = nil) {
            self.url = url
            self.title = title
            self.isLocal = isLocal
            self.thumbnailURL = thumbnailURL
        }
    }
    
    override init() {
        self.player = AVQueuePlayer()
        super.init()
        setupPlayerObserver()
        
        // First load the bundled videos
        loadBundledVideos()
        
        // Check if this is first launch by looking for our key in UserDefaults
        if !UserDefaults.standard.bool(forKey: "hasLaunchedBefore") {
            // First launch - select all local videos
            let localVideoIds = videos.map { $0.id.uuidString }
            UserDefaults.standard.set(localVideoIds, forKey: selectedVideoIdsKey)
            UserDefaults.standard.set(true, forKey: "hasLaunchedBefore")
            updatePlaylist(videos)
        } else {
            // Subsequent launch - use saved selection
            if let selectedIds = UserDefaults.standard.array(forKey: selectedVideoIdsKey) as? [String] {
                let selectedVideos = videos.filter { selectedIds.contains($0.id.uuidString) }
                updatePlaylist(selectedVideos)
            }
        }
    }
    
    private func setupPlayerObserver() {
        NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self = self,
                  let finishedItem = notification.object as? AVPlayerItem else { return }
            
            // When a video finishes, add it back to the end of the queue
            if let urlAsset = finishedItem.asset as? AVURLAsset,
               let video = self.currentPlaylist.first(where: { $0.url == urlAsset.url }) {
                let newItem = AVPlayerItem(url: video.url)
                self.player.insert(newItem, after: self.player.items().last)
            }
            
            // Update title to the now-playing video
            if let currentItem = self.player.currentItem,
               let urlAsset = currentItem.asset as? AVURLAsset,
               let currentVideo = self.currentPlaylist.first(where: { $0.url == urlAsset.url }) {
                self.currentVideoTitle = currentVideo.title
            }
        }
    }
    
    private func loadBundledVideos() {
        if let movVideos = Bundle.main.urls(forResourcesWithExtension: "mov", subdirectory: nil) {
            videos = movVideos.map { url in
                let title = url.deletingPathExtension().lastPathComponent
                    .replacingOccurrences(of: "-", with: " ")
                return VideoItem(url: url, title: title, isLocal: true, thumbnailURL: nil)
            }
        }
    }
    
    func updatePlaylist(_ selectedVideos: [VideoItem]) {
        player.removeAllItems()
        
        // Only proceed if we have local videos to play
        let localVideos = selectedVideos.filter { $0.isLocal }
        guard !localVideos.isEmpty else { return }
        
        // Shuffle the videos and store them
        currentPlaylist = localVideos.shuffled()
        
        // Add initial set of videos to the queue
        for video in currentPlaylist {
            let item = AVPlayerItem(url: video.url)
            player.insert(item, after: player.items().last)
        }
        
        // Set initial title
        currentVideoTitle = currentPlaylist[0].title
        player.play()
    }
    
    var remoteVideos: [VideoItem] {
        RemoteVideos.videos
    }
    
    func downloadAndAddVideo(_ video: VideoItem, completion: @escaping (Bool) -> Void) {
        URLSession.shared.dataTask(with: video.url) { [weak self] data, response, error in
            guard let self = self,
                  let data = data,
                  error == nil else {
                DispatchQueue.main.async {
                    completion(false)
                }
                return
            }
            
            let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(video.url.lastPathComponent)
            try? data.write(to: tempURL)
            
            let localVideo = VideoItem(url: tempURL,
                                     title: video.title,
                                     isLocal: true,
                                     thumbnailURL: video.thumbnailURL)
            
            DispatchQueue.main.async {
                self.videos.append(localVideo)
                completion(true)
            }
        }.resume()
    }
    
    func updateSelectedVideos(_ selectedVideos: [VideoItem]) {
        // Save selection to UserDefaults (including both local and remote)
        let selectedIds = selectedVideos.map { $0.id.uuidString }
        UserDefaults.standard.set(selectedIds, forKey: selectedVideoIdsKey)
        // Update playlist with only local videos
        let localSelectedVideos = selectedVideos.filter { $0.isLocal }
        updatePlaylist(localSelectedVideos)
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
    }
}

// Helper extension to safely access array elements
extension Array {
    func safe(_ index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
} 
