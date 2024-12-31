import SwiftUI
import AVKit

// Helper extension to safely access array elements
extension Array {
    func safe(_ index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

class VideoPlayerModel: NSObject, ObservableObject {
    @Published var currentVideoTitle: String = ""
    let player: AVQueuePlayer
    @Published var videos: [VideoItem] = []
    private var currentIndex = 0
    private var playerLooper: AVPlayerLooper?
    
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
        loadBundledVideos()
    }
    
    private func loadBundledVideos() {
        print("Loading videos from bundle...")
        
        // Only load .mov files (HEVC videos)
        if let movVideos = Bundle.main.urls(forResourcesWithExtension: "mov", subdirectory: nil) {
            print("Found \(movVideos.count) HEVC videos")
            
            videos = movVideos.map { url in
                let title = url.deletingPathExtension().lastPathComponent
                    .replacingOccurrences(of: "-", with: " ")
                print("Loading HEVC video: \(title) from \(url)")
                return VideoItem(url: url, title: title, isLocal: true, thumbnailURL: nil)
            }
            
            print("Successfully loaded \(videos.count) HEVC videos: \(videos.map { $0.title })")
            
            // Verify each video is accessible
            for video in videos {
                print("Verifying video: \(video.title) at \(video.url)")
                let asset = AVURLAsset(url: video.url)
                asset.loadValuesAsynchronously(forKeys: ["playable"]) {
                    var error: NSError? = nil
                    let status = asset.statusOfValue(forKey: "playable", error: &error)
                    if status == .loaded {
                        print("✅ Video is playable: \(video.title)")
                    } else {
                        print("❌ Video is not playable: \(video.title), error: \(String(describing: error))")
                    }
                }
            }
        } else {
            print("No HEVC videos found in bundle")
        }
    }
    
    private func loadVideosFromPath(_ path: String) -> [VideoItem]? {
        print("Attempting to load videos from: \(path)")
        do {
            let fileURLs = try FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: path),
                                                                     includingPropertiesForKeys: nil,
                                                                     options: .skipsHiddenFiles)
            
            let videoItems = fileURLs.filter { url in
                let fileExtension = url.pathExtension.lowercased()
                return ["mp4", "mov"].contains(fileExtension)
            }.map { url in
                let title = url.deletingPathExtension().lastPathComponent
                    .replacingOccurrences(of: "-", with: " ")
                print("Found video: \(title) at \(url)")
                return VideoItem(url: url, title: title, isLocal: true, thumbnailURL: nil)
            }
            
            if !videoItems.isEmpty {
                print("Successfully loaded \(videoItems.count) videos from \(path)")
                return videoItems
            } else {
                print("No video files found in \(path)")
                return nil
            }
        } catch {
            print("Error loading videos from \(path): \(error)")
            return nil
        }
    }
    
    func startPlayback() {
        guard !videos.isEmpty else {
            print("No videos available to play")
            return
        }
        
        print("Starting playback with \(videos.count) videos")
        player.removeAllItems()
        
        // Create items array with proper asset configuration
        var items: [AVPlayerItem] = []
        for video in videos {
            print("Creating player item for: \(video.title)")
            let asset = AVURLAsset(url: video.url)
            
            // Load asset keys asynchronously
            let keys = ["playable", "tracks", "duration"]
            asset.loadValuesAsynchronously(forKeys: keys) {
                var error: NSError?
                let status = asset.statusOfValue(forKey: "playable", error: &error)
                
                if status == .loaded {
                    print("✅ Asset is playable for: \(video.title)")
                    print("Duration: \(asset.duration.seconds) seconds")
                    print("Tracks: \(asset.tracks.count)")
                    
                    // Print track details
                    for track in asset.tracks {
                        print("Track: \(track.mediaType.rawValue)")
                        if track.mediaType == .video {
                            print("Video dimensions: \(track.naturalSize)")
                            print("Video codec: \(track.description)")
                        }
                    }
                } else {
                    print("❌ Asset is not playable for: \(video.title)")
                    print("Error: \(String(describing: error))")
                }
            }
            
            let item = TaggedPlayerItem(url: video.url, videoId: video.id)
            items.append(item)
            
            // Observe item status
            NotificationCenter.default.addObserver(
                forName: .AVPlayerItemFailedToPlayToEndTime,
                object: item,
                queue: .main
            ) { [weak self] notification in
                if let error = notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error {
                    print("❌ Failed to play item: \(video.title)")
                    print("Error: \(error)")
                    
                    // If a video fails, remove it from the queue and move to the next one
                    if let self = self,
                       let failedItem = notification.object as? AVPlayerItem {
                        self.player.remove(failedItem)
                        self.currentIndex = (self.currentIndex + 1) % self.videos.count
                        self.updateCurrentVideoTitle()
                    }
                }
            }
        }
        
        // Add all items to the queue
        for item in items {
            player.insert(item, after: player.items().last)
        }
        
        // Set up observation of the current item
        NotificationCenter.default.removeObserver(self, name: .AVPlayerItemDidPlayToEndTime, object: nil)
        NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self = self,
                  let playerItem = notification.object as? AVPlayerItem else { return }
            
            DispatchQueue.main.async {
                // Update index
                self.currentIndex = (self.currentIndex + 1) % self.videos.count
                self.updateCurrentVideoTitle()
                
                // Create a new item instead of reusing the old one
                if let currentVideo = self.videos.safe(self.currentIndex) {
                    print("Creating new item for next playback: \(currentVideo.title)")
                    let newItem = TaggedPlayerItem(url: currentVideo.url, videoId: currentVideo.id)
                    self.player.remove(playerItem)
                    self.player.insert(newItem, after: self.player.items().last)
                }
            }
        }
        
        // Set initial title
        currentIndex = 0
        updateCurrentVideoTitle()
        print("Starting playback with: \(currentVideoTitle)")
        player.play()
    }
    
    // Add KVO observation for player item status
    override public func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey : Any]?, context: UnsafeMutableRawPointer?) {
        if keyPath == #keyPath(AVPlayerItem.status),
           let item = object as? AVPlayerItem {
            switch item.status {
            case .failed:
                print("❌ Player item failed: \(String(describing: item.error))")
            case .readyToPlay:
                print("✅ Player item ready to play")
            case .unknown:
                print("⚠️ Player item status unknown")
            @unknown default:
                break
            }
        }
    }
    
    private func updateCurrentVideoTitle() {
        guard currentIndex < videos.count else { return }
        currentVideoTitle = videos[currentIndex].title
    }
    
    func addVideo(url: URL, title: String) {
        let newVideo = VideoItem(url: url, title: title, isLocal: false, thumbnailURL: nil)
        videos.append(newVideo)
        
        // Add the new item to the queue
        let playerItem = AVPlayerItem(url: url)
        player.insert(playerItem, after: player.items().last)
        
        // If this is the first video, start playback
        if videos.count == 1 {
            startPlayback()
        }
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
    }
    
    var remoteVideos: [VideoItem] {
        RemoteVideos.videos
    }
    
    func removeVideo(_ video: VideoItem) {
        if let index = videos.firstIndex(where: { $0.id == video.id }) {
            videos.remove(at: index)
            // Remove from player queue if it exists
            if let item = player.items().first(where: { ($0 as? TaggedPlayerItem)?.videoId == video.id }) {
                player.remove(item)
            }
        }
    }
    
    func addVideo(_ video: VideoItem) {
        videos.append(video)
        let asset = AVURLAsset(url: video.url, options: [
            "AVURLAssetOutOfBandMIMETypeKey": "video/mp4",
            AVURLAssetPreferPreciseDurationAndTimingKey: true
        ])
        let item = TaggedPlayerItem(asset: asset, videoId: video.id)
        player.insert(item, after: player.items().last)
    }
    
    func downloadAndAddVideo(_ video: VideoItem, completion: @escaping (Bool) -> Void) {
        // Simple download using URLSession
        URLSession.shared.dataTask(with: video.url) { [weak self] data, response, error in
            guard let self = self,
                  let data = data,
                  error == nil else {
                DispatchQueue.main.async {
                    completion(false)
                }
                return
            }
            
            // Save to temporary file
            let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(video.url.lastPathComponent)
            try? data.write(to: tempURL)
            
            // Create new video item with local URL
            let localVideo = VideoItem(url: tempURL,
                                     title: video.title,
                                     isLocal: true,
                                     thumbnailURL: video.thumbnailURL)
            
            DispatchQueue.main.async {
                self.addVideo(localVideo)
                completion(true)
            }
        }.resume()
    }
}

// Custom AVPlayerItem subclass to track video ID
class TaggedPlayerItem: AVPlayerItem {
    let videoId: UUID
    
    init(asset: AVURLAsset, videoId: UUID) {
        self.videoId = videoId
        super.init(asset: asset, automaticallyLoadedAssetKeys: nil)
    }
    
    convenience init(url: URL, videoId: UUID) {
        let asset = AVURLAsset(url: url, options: [
            "AVURLAssetOutOfBandMIMETypeKey": "video/mp4",
            AVURLAssetPreferPreciseDurationAndTimingKey: true
        ])
        self.init(asset: asset, videoId: videoId)
    }
} 
