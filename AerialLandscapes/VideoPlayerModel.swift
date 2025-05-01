import Foundation
import AVKit
import AVFoundation
import SwiftUI

class VideoPlayerModel: NSObject, ObservableObject {
    @Published var currentVideoTitle: String = ""
    let player: AVQueuePlayer
    @Published private(set) var videos: [Video] = []
    
    // Track currently playing index
    private var currentPlaylistIndex: Int = 0
    
    // Add a property to track the current playlist order
    private var currentPlaylist: [Video] = []
    
    // Get selected videos in a computed property
    var selectedVideos: [Video] {
        return videos.filter { $0.isLocal && $0.isSelected }
    }
    
    // Add S3 service
    let s3VideoService = S3VideoService()
    
    @Published private(set) var isInitialLoad = true
    
    @Published private(set) var remoteVideos: [Video] = []
    
    @Published var downloadProgress: [String: Double] = [:]
    
    private var documentsDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }
    
    private var videosDirectory: URL {
        let directory = documentsDirectory.appendingPathComponent("Videos")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
    
    private var thumbnailsDirectory: URL {
        let directory = documentsDirectory.appendingPathComponent("Thumbnails")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
    
    private var videoConfig: VideoConfig {
        return VideoConfig.shared
    }
    
    private let videoManager = VideoManager.shared
    
    override init() {
        self.player = AVQueuePlayer()
        super.init()
        
        // Set up observers
        setupPlayerObserver()
        addPlayerObserver()
        
        // Initialize VideoManager with default videos if empty
        if videoManager.videos.isEmpty {
            let defaultVideos = videoConfig.videos.map(Video.fromMetadata)
            videoManager.updateVideos(defaultVideos)
            
            // First launch - select all local videos by default
            defaultVideos.forEach { video in
                if video.isLocal {
                    videoManager.updateSelection(for: video.id, isSelected: true)
                }
            }
        }
        
        // Load initial state
        loadVideos()
        
        // Start fetching remote videos after initial setup
        fetchRemoteVideos()
    }
    
    private func loadVideos() {
        // Get videos from VideoManager (single source of truth)
        videos = videoManager.videos
        
        // Ensure thumbnails for all videos
        videos.forEach { video in
            _ = ensureThumbnail(for: video)
        }
        
        // Debug logging
        print("\n📱 Loaded \(videos.count) videos:")
        print("Selected videos: \(selectedVideos.map(\.displayTitle).joined(separator: ", "))")
        videos.forEach { video in
            print("- \(video.displayTitle) (\(video.geozone)) [Selected: \(video.isSelected)]")
            print("  Local URL: \(video.isLocal ? video.url.path : "Not downloaded")")
        }
        
        // Update player with currently selected videos
        DispatchQueue.main.async {
            self.updateSelectedVideos(self.videos)
        }
    }
    
    private func fetchRemoteVideos() {
        s3VideoService.fetchAvailableVideos { [weak self] result in
            DispatchQueue.main.async {
                switch result {
                case .success(let newVideos):
                    // Update or add new videos to VideoManager
                    var existingVideos = self?.videoManager.videos ?? []
                    
                    print("\n☁️ Fetched \(newVideos.count) remote videos:")
                    newVideos.forEach { video in
                        print("- \(video.displayTitle) (\(video.geozone))")
                        print("  Remote URL: \(video.remoteVideoURL)")
                        print("  Thumbnail URL: \(video.remoteThumbnailURL)")
                    }
                    
                    for remoteVideo in newVideos {
                        if let existingIndex = existingVideos.firstIndex(where: { $0.id == remoteVideo.id }) {
                            // Update existing video
                            existingVideos[existingIndex].localVideoPath = nil  // Reset local path if not found
                            print("📝 Updated existing video: \(remoteVideo.displayTitle)")
                        } else {
                            // Add new video
                            existingVideos.append(remoteVideo)
                            print("➕ Added new video: \(remoteVideo.displayTitle)")
                        }
                    }
                    
                    self?.videoManager.updateVideos(existingVideos)
                    self?.loadVideos()  // Reload all videos
                    print("\n✅ Updated video cache with \(newVideos.count) remote videos")
                    
                case .failure(let error):
                    print("❌ Error fetching remote videos: \(error)")
                }
                self?.isInitialLoad = false
            }
        }
    }
    
    // Setup player observer for end of video
    private func setupPlayerObserver() {
        NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self = self,
                  let finishedItem = notification.object as? AVPlayerItem else { return }
            
            print("\n🔄 Video finished playing")
            
            guard !currentPlaylist.isEmpty else { return }
            
            // Remove the finished item
            self.player.remove(finishedItem)
            
            // Increment index and wrap around if needed
            currentPlaylistIndex = (currentPlaylistIndex + 1) % currentPlaylist.count
            
            // Get the next video from our stored playlist order
            let nextVideo = currentPlaylist[currentPlaylistIndex]
            
            // Create new player item and add to queue
            let playerItem = AVPlayerItem(url: nextVideo.url)
            self.player.insert(playerItem, after: self.player.items().last)
            addPlayerItemObserver(playerItem, title: nextVideo.displayTitle)
            
            // Ensure playback continues
            self.player.play()
            
            // Update title after ensuring the player has started playing the next item
            DispatchQueue.main.async {
                if let currentItem = self.player.currentItem,
                   let currentVideo = self.getVideo(from: currentItem) {
                    self.currentVideoTitle = currentVideo.displayTitle
                    print("▶️ Now playing: \(currentVideo.displayTitle)")
                    print("Queue position: \(self.currentPlaylistIndex + 1) of \(self.currentPlaylist.count)")
                }
            }
        }
        
        // Add observer for when the current item changes
        NotificationCenter.default.addObserver(
            forName: .AVPlayerItemTimeJumped,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self = self,
                  let currentItem = self.player.currentItem,
                  let currentVideo = self.getVideo(from: currentItem) else { return }
            
            self.currentVideoTitle = currentVideo.displayTitle
            print("🎵 Current item changed to: \(currentVideo.displayTitle)")
        }
    }
    
    func updateSelectedVideos(_ videos: [Video]) {
        print("\n🎬 Updating playlist")
        
        let selectedVideos = self.selectedVideos
        guard !selectedVideos.isEmpty else {
            print("❌ No videos selected")
            player.removeAllItems()
            currentVideoTitle = ""
            currentPlaylistIndex = 0
            currentPlaylist = []
            return
        }
        
        // Clear existing queue and reset index
        player.removeAllItems()
        currentPlaylistIndex = 0
        
        // Shuffle the selected videos for variety
        let shuffledVideos = selectedVideos.shuffled()
        // Store the shuffled order
        currentPlaylist = shuffledVideos
        
        print("📋 Adding \(shuffledVideos.count) videos to queue:")
        print("Playlist order:")
        shuffledVideos.enumerated().forEach { index, video in
            print("\(index + 1). \(video.displayTitle)")
        }
        
        // Add all selected videos to queue
        for video in shuffledVideos {
            print("➕ Adding to queue: \(video.displayTitle)")
            let playerItem = AVPlayerItem(url: video.url)
            player.insert(playerItem, after: player.items().last)
            addPlayerItemObserver(playerItem, title: video.displayTitle)
        }
        
        // Set initial title and start playback
        if let firstVideo = shuffledVideos.first {
            // Update title immediately before starting playback
            currentVideoTitle = firstVideo.displayTitle
            print("▶️ Starting playback with: \(firstVideo.displayTitle)")
            
            // Ensure we're at the start of the video
            player.seek(to: .zero)
            
            // Force playback to start
            DispatchQueue.main.async {
                self.player.play()
            }
        }
    }
    
    private func addPlayerItemObserver(_ item: AVPlayerItem, title: String) {
        // Observe status changes
        item.addObserver(self, forKeyPath: #keyPath(AVPlayerItem.status), options: [.old, .new], context: nil)
        
        // Observe if playback is likely to keep up
        item.addObserver(self, forKeyPath: #keyPath(AVPlayerItem.isPlaybackLikelyToKeepUp), options: [.old, .new], context: nil)
        
        // Add error observer
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(playerItemFailedToPlay(_:)),
            name: .AVPlayerItemFailedToPlayToEndTime,
            object: item
        )
    }
    
    private func addPlayerObserver() {
        // Observe player's timeControlStatus
        player.addObserver(self, forKeyPath: #keyPath(AVPlayer.timeControlStatus), options: [.old, .new], context: nil)
    }
    
    override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey : Any]?, context: UnsafeMutableRawPointer?) {
        if let item = object as? AVPlayerItem {
            switch keyPath {
            case #keyPath(AVPlayerItem.status):
                let status = AVPlayerItem.Status(rawValue: change?[.newKey] as? Int ?? 0)
                print("\n📺 Player item status changed:")
                print("Status: \(status?.rawValue ?? -1)")
                if let error = item.error {
                    print("Error: \(error.localizedDescription)")
                }
                
            case #keyPath(AVPlayerItem.isPlaybackLikelyToKeepUp):
                print("\n⚡️ Playback likely to keep up: \(item.isPlaybackLikelyToKeepUp)")
            default:
                break
            }
        } else if let player = object as? AVPlayer, keyPath == #keyPath(AVPlayer.timeControlStatus) {
            let status = AVPlayer.TimeControlStatus(rawValue: change?[.newKey] as? Int ?? 0)
            print("\n⏯️ Player time control status changed: \(status?.rawValue ?? -1)")
            switch status {
            case .paused:
                print("Player is paused")
            case .waitingToPlayAtSpecifiedRate:
                print("Player is waiting/buffering")
            case .playing:
                print("Player is playing")
            default:
                print("Unknown player status")
            }
        }
    }
    
    @objc private func playerItemFailedToPlay(_ notification: Notification) {
        if let item = notification.object as? AVPlayerItem,
           let error = item.error {
            print("\n❌ Player item failed to play")
            print("Error: \(error.localizedDescription)")
            
            if let urlAsset = item.asset as? AVURLAsset {
                print("Failed URL: \(urlAsset.url)")
            }
        }
    }
    
    deinit {
        // Remove timeObserver cleanup since we're not using it anymore
        NotificationCenter.default.removeObserver(self)
        
        player.items().forEach { item in
            item.removeObserver(self, forKeyPath: #keyPath(AVPlayerItem.status))
            item.removeObserver(self, forKeyPath: #keyPath(AVPlayerItem.isPlaybackLikelyToKeepUp))
        }
        
        player.removeObserver(self, forKeyPath: #keyPath(AVPlayer.timeControlStatus))
    }
    
    var allVideos: [Video] {
        // Get the list of downloaded video titles
        let downloadedTitles = Set(videos.map { $0.displayTitle })
        
        // Start with all local videos
        var orderedVideos = videos
        
        // Add only remote videos that aren't already downloaded
        let nonDownloadedRemoteVideos = remoteVideos.filter { !downloadedTitles.contains($0.displayTitle) }
        orderedVideos.append(contentsOf: nonDownloadedRemoteVideos)
        
        return orderedVideos
    }
    
    func downloadAndAddVideo(_ video: Video, completion: @escaping (Bool) -> Void) {
        print("\n📥 Starting download for: \(video.displayTitle)")
        
        guard let remotePath = video.remoteVideoPath else {
            print("❌ No remote video path available")
            completion(false)
            return
        }
        
        let request = s3VideoService.generateSignedRequest(for: video)
        
        let task = URLSession.shared.downloadTask(with: request) { [weak self] tempURL, response, error in
            guard let self = self else { return }
            
            if let error = error {
                print("❌ Download failed: \(error.localizedDescription)")
                completion(false)
                return
            }
            
            guard let tempURL = tempURL,
                  let response = response as? HTTPURLResponse,
                  (200...299).contains(response.statusCode) else {
                print("❌ Invalid response or missing file")
                completion(false)
                return
            }
            
            do {
                let finalURL = self.videosDirectory.appendingPathComponent(remotePath)
                try? FileManager.default.removeItem(at: finalURL)
                try FileManager.default.moveItem(at: tempURL, to: finalURL)
                
                // Update VideoManager
                let relativePath = "Videos/\(remotePath)"
                self.videoManager.updateLocalPath(for: video.id, path: relativePath)
                
                // Reload videos to update UI
                DispatchQueue.main.async {
                    self.loadVideos()
                    self.downloadProgress.removeValue(forKey: video.id)
                    completion(true)
                }
                
            } catch {
                print("❌ Failed to save video: \(error.localizedDescription)")
                completion(false)
            }
        }
        
        task.progress.observe(\.fractionCompleted, options: [.new]) { [weak self] (progress: Progress, _: NSKeyValueObservedChange<Double>) in
            DispatchQueue.main.async {
                self?.downloadProgress[video.id] = progress.fractionCompleted
            }
        }
        
        task.resume()
    }
    
    private func ensureThumbnail(for video: Video) -> URL? {
        print("\n🖼️ Ensuring thumbnail for: \(video.displayTitle)")
        
        // 1. Check for existing local thumbnail
        if let localPath = video.localThumbnailPath {
            let thumbnailURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent(localPath)
            if FileManager.default.fileExists(atPath: thumbnailURL.path) {
                print("✅ Using existing local thumbnail: \(thumbnailURL.path)")
                return thumbnailURL
            }
        }
        
        // 2. If we have a local video, generate thumbnail
        if video.isLocal {
            print("📹 Generating thumbnail from local video: \(video.url.path)")
            if let thumbnailURL = generateThumbnail(from: video.url, videoId: video.id) {
                let relativePath = "Thumbnails/\(video.id)_thumbnail.jpg"
                videoManager.updateThumbnailPath(for: video.id, path: relativePath)
                print("✅ Generated and saved local thumbnail: \(thumbnailURL.path)")
                return thumbnailURL
            }
        }
        
        // 3. Download remote thumbnail if available
        if let remoteThumbnailURL = video.remoteThumbnailURL {
            print("☁️ Downloading remote thumbnail: \(remoteThumbnailURL)")
            downloadThumbnail(from: remoteThumbnailURL) { [weak self] thumbnailURL in
                if let thumbnailURL = thumbnailURL {
                    let relativePath = "Thumbnails/\(video.id)_thumbnail.jpg"
                    self?.videoManager.updateThumbnailPath(for: video.id, path: relativePath)
                    print("✅ Downloaded and saved remote thumbnail: \(thumbnailURL.path)")
                }
            }
        }
        
        return nil
    }
    
    private func generateThumbnail(from videoURL: URL, videoId: String) -> URL? {
        let asset = AVAsset(url: videoURL)
        let imageGenerator = AVAssetImageGenerator(asset: asset)
        imageGenerator.appliesPreferredTrackTransform = true
        
        let thumbnailURL = thumbnailsDirectory.appendingPathComponent("\(videoId)_thumbnail.jpg")
        
        do {
            let cgImage = try imageGenerator.copyCGImage(at: .zero, actualTime: nil)
            let uiImage = UIImage(cgImage: cgImage)
            if let jpegData = uiImage.jpegData(compressionQuality: 0.8) {
                try jpegData.write(to: thumbnailURL)
                return thumbnailURL
            }
        } catch {
            print("❌ Failed to generate thumbnail: \(error)")
        }
        
        return nil
    }
    
    private func downloadThumbnail(from url: URL, completion: @escaping (URL?) -> Void) {
        let task = URLSession.shared.downloadTask(with: url) { [weak self] tempURL, response, error in
            guard let self = self,
                  let tempURL = tempURL,
                  error == nil else {
                print("❌ Failed to download thumbnail: \(error?.localizedDescription ?? "Unknown error")")
                completion(nil)
                return
            }
            
            let thumbnailURL = self.thumbnailsDirectory.appendingPathComponent("\(UUID().uuidString)_thumbnail.jpg")
            
            do {
                try FileManager.default.moveItem(at: tempURL, to: thumbnailURL)
                completion(thumbnailURL)
            } catch {
                print("❌ Failed to save thumbnail: \(error)")
                completion(nil)
            }
        }
        task.resume()
    }
    
    // Add this public method to VideoPlayerModel
    func toggleVideoSelection(for videoId: String) {
        // Get current selection state
        let currentState = videoManager.videos.first(where: { $0.id == videoId })?.isSelected ?? false
        
        // Prevent deselecting the last local video
        if currentState {
            let selectedLocalVideos = videos.filter { $0.isLocal && $0.isSelected }
            if selectedLocalVideos.count <= 1 {
                return
            }
        }
        
        // Update selection state in VideoManager
        videoManager.updateSelection(for: videoId, isSelected: !currentState)
        
        // Update local videos array
        videos = videoManager.videos
        
        // Update player playlist
        updateSelectedVideos(videos)
        
        // Debug logging
        print("\n🎬 Video selection changed:")
        print("Video: \(videoId)")
        print("New state: \(!currentState)")
        print("Currently selected: \(selectedVideos.map(\.displayTitle).joined(separator: ", "))")
    }
    
    // Add a method to get the current video from a player item
    private func getVideo(from playerItem: AVPlayerItem) -> Video? {
        guard let asset = playerItem.asset as? AVURLAsset else { return nil }
        return currentPlaylist.first { $0.url == asset.url }
    }
}

// Helper extension for safe array access
extension Array {
    subscript(safe index: Int) -> Element? {
        return indices.contains(index) ? self[index] : nil
    }
} 
