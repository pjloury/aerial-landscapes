import SwiftUI
import AVKit

class VideoPlayerModel: NSObject, ObservableObject {
    @Published var currentVideoTitle: String = ""
    let player: AVQueuePlayer
    @Published var videos: [VideoItem] = []  // Local videos only
    private var currentPlaylist: [VideoItem] = []
    private let selectedVideoIdsKey = "selectedVideoIds"
    
    struct VideoItem: Identifiable {
        let id: String
        let url: URL
        let title: String
        let isLocal: Bool
        let thumbnailURL: URL?
        
        init(url: URL, title: String, isLocal: Bool, thumbnailURL: URL? = nil) {
            self.id = title
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
        
        loadBundledVideos()
        print("Loaded \(videos.count) bundled videos")
        
        if !UserDefaults.standard.bool(forKey: "hasLaunchedBefore") {
            print("First launch - selecting all local videos")
            let localVideoIds = videos.map { $0.id }
            UserDefaults.standard.set(localVideoIds, forKey: selectedVideoIdsKey)
            UserDefaults.standard.set(true, forKey: "hasLaunchedBefore")
            updatePlaylist(videos)
        } else {
            print("Subsequent launch - loading saved selection")
            if let selectedIds = UserDefaults.standard.array(forKey: selectedVideoIdsKey) as? [String] {
                let selectedVideos = videos.filter { selectedIds.contains($0.id) }
                print("Found \(selectedVideos.count) previously selected videos")
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
            
            if currentPlaylist.count == 1 {
                // Single video - seek back to start and continue playing
                finishedItem.seek(to: .zero) { [weak self] _ in
                    self?.player.play()
                }
            } else {
                // Multiple videos - add finished video back to queue
                if let urlAsset = finishedItem.asset as? AVURLAsset,
                   let video = self.currentPlaylist.first(where: { $0.url == urlAsset.url }) {
                    let newItem = AVPlayerItem(url: video.url)
                    self.player.insert(newItem, after: self.player.items().last)
                }
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
        if let resourcePath = Bundle.main.resourcePath {
            let enumerator = FileManager.default.enumerator(atPath: resourcePath)
            print("All resources in bundle:")
            while let filePath = enumerator?.nextObject() as? String {
                let lowercasePath = filePath.lowercased()
                if lowercasePath.hasSuffix(".mov") || lowercasePath.hasSuffix(".mp4") {
                    print("Found video: \(filePath)")
                    let filename = (filePath as NSString).deletingPathExtension
                    let fileExtension = (filePath as NSString).pathExtension
                    
                    if let url = Bundle.main.url(forResource: filename, withExtension: fileExtension) {
                        let title = url.deletingPathExtension().lastPathComponent
                            .replacingOccurrences(of: "-", with: " ")
                        
                        // Generate thumbnail
                        let thumbnailURL = generateThumbnail(for: url, title: title)
                        
                        let video = VideoItem(url: url, title: title, isLocal: true, thumbnailURL: thumbnailURL)
                        videos.append(video)
                    }
                }
            }
        }
    }
    
    private func generateThumbnail(for videoURL: URL, title: String) -> URL? {
        let asset = AVAsset(url: videoURL)
        let imageGenerator = AVAssetImageGenerator(asset: asset)
        imageGenerator.appliesPreferredTrackTransform = true
        
        // Get thumbnail from first frame
        let time = CMTime(seconds: 0, preferredTimescale: 1)
        
        do {
            let cgImage = try imageGenerator.copyCGImage(at: time, actualTime: nil)
            let uiImage = UIImage(cgImage: cgImage)
            
            // Create a URL in the cache directory for the thumbnail
            let cacheDirectory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            let thumbnailURL = cacheDirectory.appendingPathComponent("\(title)_thumbnail.jpg")
            
            // Convert UIImage to JPEG data and write to file
            if let imageData = uiImage.jpegData(compressionQuality: 0.8) {
                try imageData.write(to: thumbnailURL)
                return thumbnailURL
            }
        } catch {
            print("Error generating thumbnail for \(title): \(error)")
        }
        
        return nil
    }
    
    func updatePlaylist(_ selectedVideos: [VideoItem]) {
        print("Updating playlist with \(selectedVideos.count) selected videos")
        player.removeAllItems()
        
        // Only proceed if we have local videos to play
        let localVideos = selectedVideos.filter { $0.isLocal }
        print("Found \(localVideos.count) local videos")
        guard !localVideos.isEmpty else {
            print("No local videos to play")
            return
        }
        
        // Shuffle the videos and store them
        currentPlaylist = localVideos.shuffled()
        
        if currentPlaylist.count == 1 {
            // If only one video, set it to loop
            print("Single video mode - enabling loop for: \(currentPlaylist[0].title)")
            let item = AVPlayerItem(url: currentPlaylist[0].url)
            player.replaceCurrentItem(with: item)
            player.actionAtItemEnd = .none // Prevents playback from stopping at end
        } else {
            // Multiple videos - add them all to queue
            for video in currentPlaylist {
                print("Adding video to queue: \(video.title) at URL: \(video.url)")
                let item = AVPlayerItem(url: video.url)
                player.insert(item, after: player.items().last)
            }
        }
        
        // Set initial title and play
        currentVideoTitle = currentPlaylist[0].title
        print("Starting playback with: \(currentVideoTitle)")
        
        // Force a play command and check player status
        player.play()
        if player.timeControlStatus == .playing {
            print("Player is playing")
        } else {
            print("Player failed to start playing. Status: \(player.timeControlStatus.rawValue)")
        }
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
            
            // Generate thumbnail for downloaded video
            let thumbnailURL = generateThumbnail(for: tempURL, title: video.title)
            
            let localVideo = VideoItem(url: tempURL,
                                     title: video.title,
                                     isLocal: true,
                                     thumbnailURL: thumbnailURL)
            
            DispatchQueue.main.async {
                self.videos.append(localVideo)
                completion(true)
            }
        }.resume()
    }
    
    func updateSelectedVideos(_ selectedVideos: [VideoItem]) {
        // Save selection to UserDefaults (including both local and remote)
        let selectedIds = selectedVideos.map { $0.id }
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
