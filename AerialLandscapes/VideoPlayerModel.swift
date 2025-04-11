import Foundation
import AVKit

private struct BundledVideo {
    let filename: String
    let title: String
    let section: String
}

class VideoPlayerModel: NSObject, ObservableObject {
    @Published var currentVideoTitle: String = ""
    let player: AVQueuePlayer
    @Published var videos: [VideoItem] = []  // Local videos only
    @Published private(set) var currentPlaylist: [VideoItem] = []
    private let selectedVideoIdsKey = "selectedVideoIds"
    
    // Add a property to track download progress
    @Published var downloadProgress: [String: Double] = [:]
    
    // Add a property to track downloaded video info
    private let downloadedVideosKey = "downloadedVideos"
    
    // Add property to store observation
    private var progressObservation: NSKeyValueObservation?
    
    // Add S3 service
    let s3VideoService = S3VideoService()
    
    // Add new properties
    private let cacheManager = VideoCacheManager()
    @Published private(set) var isInitialLoad = true
    
    // Modify remoteVideos to be a published property
    @Published private(set) var remoteVideos: [VideoItem] = []
    
    private var documentsDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }
    
    private var videosDirectory: URL {
        let directory = documentsDirectory.appendingPathComponent("Videos")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
    
    private let bundledVideos: [BundledVideo] = [
        // California Videos
        BundledVideo(filename: "Fort Funston", title: "Fort Funston", section: "California"),
        BundledVideo(filename: "Waves", title: "Waves", section: "California"),
        BundledVideo(filename: "Stanford Main Quad", title: "Stanford Main Quad", section: "California"),
        BundledVideo(filename: "Sather Tower", title: "Sather Tower", section: "California"),
        BundledVideo(filename: "Salt Flats", title: "Salt Flats", section: "California"),
        
        // International Videos
        BundledVideo(filename: "TestAlps", title: "Test Alps", section: "International"),
        BundledVideo(filename: "TestHvar", title: "Test Hvar", section: "International"),
        BundledVideo(filename: "TestCopa", title: "Test Copa", section: "International"),
        BundledVideo(filename: "TestValencia", title: "Test Valencia", section: "International")
    ]
    
    struct VideoItem: Identifiable {
        let id: String
        let url: URL
        let title: String
        let isLocal: Bool
        let thumbnailURL: URL?
        let section: String
        
        var displayTitle: String {
            // Append (Remote) to remote video titles
            isLocal ? title : "\(title) (Remote)"
        }
        
        init(url: URL, title: String, isLocal: Bool, thumbnailURL: URL? = nil, section: String) {
            self.id = isLocal ? "local-\(title)" : "remote-\(title)"
            self.url = url
            self.title = title
            self.isLocal = isLocal
            self.thumbnailURL = thumbnailURL
            self.section = section
        }
    }
    
    override init() {
        self.player = AVQueuePlayer()
        super.init()
        
        // Load UI immediately
        DispatchQueue.main.async { [weak self] in
            self?.loadInitialState()
        }
    }
    
    private func loadInitialState() {
        print("\n=== 📱 Loading Initial State ===")
        
        // Load bundled videos
        loadBundledVideos()
        
        // Load cached metadata
        let cachedMetadata = cacheManager.loadVideoMetadata()
        print("📦 Loaded \(cachedMetadata.count) cached video metadata")
        
        // Convert cached metadata to VideoItems
        let cachedVideos = cachedMetadata.map { metadata -> VideoItem in
            let thumbnailURL = metadata.hasCachedThumbnail ? 
                thumbnailCacheCheck(for: metadata.title) : nil
            
            return VideoItem(
                url: metadata.isDownloaded ? 
                    videosDirectory.appendingPathComponent(metadata.remoteURL.lastPathComponent) : 
                    metadata.remoteURL,
                title: metadata.title,
                isLocal: metadata.isDownloaded,
                thumbnailURL: thumbnailURL,
                section: metadata.section
            )
        }
        
        // Update UI with cached data first
        DispatchQueue.main.async { [weak self] in
            self?.remoteVideos = cachedVideos.filter { !$0.isLocal }
            print("🔄 Updated UI with \(self?.remoteVideos.count ?? 0) cached remote videos")
        }
        
        // Then fetch fresh data from S3
        s3VideoService.fetchAvailableVideos { [weak self] result in
            guard let self = self else { return }
            
            switch result {
            case .success(let videos):
                // Update metadata cache
                let metadata = videos.map { video in
                    VideoCacheManager.VideoMetadata(
                        title: video.title,
                        remoteURL: video.url,
                        section: video.section,
                        hasCachedThumbnail: self.thumbnailCacheCheck(for: video.title) != nil,
                        isDownloaded: self.isVideoDownloaded(video),
                        lastUpdated: Date()
                    )
                }
                self.cacheManager.saveVideoMetadata(metadata)
                
                // Update UI
                DispatchQueue.main.async {
                    self.remoteVideos = videos
                    self.isInitialLoad = false
                    print("✅ Updated UI with \(videos.count) fresh remote videos")
                }
                
                // Start downloading thumbnails
                self.s3VideoService.refreshThumbnails()
                
            case .failure(let error):
                print("❌ Failed to refresh remote videos: \(error.localizedDescription)")
                
                // Fall back to cached data if available
                DispatchQueue.main.async {
                    self.isInitialLoad = false
                }
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
                // Multiple videos - add the finished video back to the queue
                if let urlAsset = finishedItem.asset as? AVURLAsset {
                    // Find the video that just finished
                    if let finishedVideo = self.currentPlaylist.first(where: { $0.url == urlAsset.url }) {
                        print("Video finished: \(finishedVideo.title)")
                        // Create a new item and add it to the end of the queue
                        let newItem = AVPlayerItem(url: finishedVideo.url)
                        self.player.insert(newItem, after: self.player.items().last)
                        print("Re-added \(finishedVideo.title) to queue")
                    }
                }
                
                // Update the current video title
                if let currentItem = self.player.currentItem,
                   let urlAsset = currentItem.asset as? AVURLAsset,
                   let currentVideo = self.currentPlaylist.first(where: { $0.url == urlAsset.url }) {
                    self.currentVideoTitle = currentVideo.title
                    print("Now playing: \(currentVideo.title)")
                }
                
                // Ensure playback continues
                self.player.play()
            }
        }
    }
    
    private func loadBundledVideos() {
        if let resourcePath = Bundle.main.resourcePath {
            for bundledVideo in bundledVideos {
                // Check if the video file exists
                if let url = Bundle.main.url(forResource: bundledVideo.filename, withExtension: "mov") ??
                           Bundle.main.url(forResource: bundledVideo.filename, withExtension: "mp4") {
                    print("Found video: \(bundledVideo.filename)")
                    
                    // Generate thumbnail
                    let thumbnailURL = generateThumbnail(for: url, title: bundledVideo.title)
                    
                    let video = VideoItem(
                        url: url,
                        title: bundledVideo.title,
                        isLocal: true,
                        thumbnailURL: thumbnailURL,
                        section: bundledVideo.section
                    )
                    videos.append(video)
                }
            }
        }
    }
    
    private func loadDownloadedVideos() {
        print("\n=== 📚 Loading Downloaded Videos ===")
        if let downloadedInfo = UserDefaults.standard.dictionary(forKey: downloadedVideosKey) as? [String: String] {
            for (title, filename) in downloadedInfo {
                print("\n🎥 Processing: \(title)")
                let videoURL = videosDirectory.appendingPathComponent(filename)
                
                if FileManager.default.fileExists(atPath: videoURL.path) {
                    print("✅ Video file exists")
                    
                    // Check for existing thumbnail
                    if let existingThumb = thumbnailCacheCheck(for: title) {
                        print("✅ Found valid thumbnail at: \(existingThumb)")
                    } else {
                        print("🔄 No valid thumbnail found, generating new one")
                        if let newThumb = generateThumbnail(for: videoURL, title: title) {
                            print("✅ Generated new thumbnail at: \(newThumb)")
                        } else {
                            print("❌ Failed to generate thumbnail")
                        }
                    }
                    
                    // Get final thumbnail URL
                    let thumbnailURL = thumbnailCacheCheck(for: title)
                    print("Final thumbnail status: \(thumbnailURL != nil ? "✅ Available" : "❌ Missing")")
                    
                    let section = remoteVideos.first { $0.title == title }?.section ?? "California"
                    
                    let video = VideoItem(
                        url: videoURL,
                        title: title,
                        isLocal: true,
                        thumbnailURL: thumbnailURL,
                        section: section
                    )
                    videos.append(video)
                    print("✅ Added video to library with thumbnail: \(thumbnailURL?.absoluteString ?? "none")")
                } else {
                    print("❌ Video file missing: \(filename)")
                }
            }
        }
    }
    
    private func generateThumbnail(for videoURL: URL, title: String) -> URL? {
        print("Starting thumbnail generation for: \(title)")
        print("Video URL: \(videoURL)")
        
        let asset = AVURLAsset(url: videoURL)
        let imageGenerator = AVAssetImageGenerator(asset: asset)
        imageGenerator.appliesPreferredTrackTransform = true
        imageGenerator.maximumSize = CGSize(width: 1920, height: 1080)
        
        let time = title.contains("Test") ? 
            CMTime(seconds: 5, preferredTimescale: 600) :
            CMTime(seconds: 1, preferredTimescale: 600)
        
        do {
            // Use synchronous generation instead
            let cgImage = try imageGenerator.copyCGImage(at: time, actualTime: nil)
            let uiImage = UIImage(cgImage: cgImage)
            let cacheDirectory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            let thumbnailURL = cacheDirectory.appendingPathComponent("\(title)_thumbnail.jpg")
            
            if let imageData = uiImage.jpegData(compressionQuality: 0.9) {
                try? imageData.write(to: thumbnailURL)
                print("✅ Successfully generated and saved thumbnail for: \(title)")
                return thumbnailURL
            }
        } catch {
            print("❌ Failed to generate thumbnail for \(title)")
            print("Error: \(error.localizedDescription)")
        }
        
        return nil
    }
    
    func updatePlaylist(_ selectedVideos: [VideoItem]) {
        print("\n🔄 Updating Player Playlist")
        print("Videos to play: \(selectedVideos.count)")
        
        player.removeAllItems()
        
        // Only proceed if we have local videos to play
        let localVideos = selectedVideos.filter { video in
            let exists = FileManager.default.fileExists(atPath: video.url.path)
            print("Checking video: \(video.title)")
            print("URL: \(video.url)")
            print("File exists: \(exists)")
            return video.isLocal && exists
        }
        print("Found \(localVideos.count) valid local videos")
        
        guard !localVideos.isEmpty else {
            print("❌ No valid local videos to play")
            return
        }
        
        // Shuffle the videos and store them
        currentPlaylist = localVideos.shuffled()
        
        var validVideos: [(VideoItem, AVPlayerItem)] = []
        
        for video in currentPlaylist {
            print("\n🎥 Validating video: \(video.title)")
            print("URL: \(video.url)")
            
            // Create asset with specific options
            let asset = AVURLAsset(url: video.url)
            
            // Create player item
            let playerItem = AVPlayerItem(asset: asset)
            
            // Load essential properties synchronously
            let keys = ["duration", "tracks"]
            asset.loadValuesAsynchronously(forKeys: keys) {} // Load the values
            
            // Check if the asset is valid
            var durationStatus: AVKeyValueStatus = asset.statusOfValue(forKey: "duration", error: nil)
            var tracksStatus: AVKeyValueStatus = asset.statusOfValue(forKey: "tracks", error: nil)
            
            // Wait briefly for loading if needed
            let timeout = Date().addingTimeInterval(2.0)
            while durationStatus == .loading || tracksStatus == .loading,
                  Date() < timeout {
                durationStatus = asset.statusOfValue(forKey: "duration", error: nil)
                tracksStatus = asset.statusOfValue(forKey: "tracks", error: nil)
                Thread.sleep(forTimeInterval: 0.1)
            }
            
            // Now safely access the properties
            if durationStatus == .loaded && tracksStatus == .loaded {
                let duration = asset.duration
                let tracks = asset.tracks
                
                print("Duration: \(duration.seconds) seconds")
                print("Number of tracks: \(tracks.count)")
                
                if duration.seconds > 0 && !tracks.isEmpty {
                    print("✅ Asset validated for: \(video.title)")
                    validVideos.append((video, playerItem))
                } else {
                    print("❌ Asset validation failed for: \(video.title)")
                    print("Duration valid: \(duration.seconds > 0)")
                    print("Has tracks: \(!tracks.isEmpty)")
                }
            } else {
                print("❌ Failed to load asset properties for: \(video.title)")
                print("Duration status: \(durationStatus.rawValue)")
                print("Tracks status: \(tracksStatus.rawValue)")
            }
        }
        
        print("\n🎬 Creating player items for \(validVideos.count) valid videos")
        
        if validVideos.isEmpty {
            print("❌ No valid videos to play")
            return
        }
        
        // Create player items from validated assets
        for (video, playerItem) in validVideos {
            print("\nAdding to queue: \(video.title)")
            addPlayerItemObserver(playerItem, title: video.title)
            player.insert(playerItem, after: player.items().last)
        }
        
        // Set initial title and play
        if let firstVideo = validVideos.first?.0 {
            currentVideoTitle = firstVideo.title
            print("\n▶️ Starting playback with: \(currentVideoTitle)")
        }
        
        // Add player observer
        addPlayerObserver()
        
        // Start playback
        print("Starting playback...")
        player.play()
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
    
    // Add a helper function to check if a video is already downloaded
    private func isVideoDownloaded(_ video: VideoItem) -> Bool {
        return videos.contains { $0.title == video.title }
    }
    
    // Add a function to get the local version of a video if it exists
    private func getLocalVersion(_ video: VideoItem) -> VideoItem? {
        return videos.first { $0.title == video.title }
    }
    
    func downloadAndAddVideo(_ video: VideoItem, completion: @escaping (Bool) -> Void) {
        print("\n=== 📥 Video Download Started ===")
        print("Title: \(video.title)")
        print("Remote URL: \(video.url)")
        print("Video ID: \(video.id)")
        
        // Check if already downloaded - EARLY EXIT
        if let existingVideo = getLocalVersion(video) {
            print("\n⚠️ Attempt to download already existing video")
            print("Local URL: \(existingVideo.url)")
            print("Local thumbnail: \(existingVideo.thumbnailURL?.absoluteString ?? "none")")
            
            let fileExists = FileManager.default.fileExists(atPath: existingVideo.url.path)
            print("File exists: \(fileExists)")
            
            if fileExists {
                print("❌ Error: Attempted to download an already downloaded video")
                DispatchQueue.main.async {
                    self.downloadProgress[video.id] = nil
                    completion(true) // Return true since video is available
                }
                return
            }
            
            // If we get here, the video is marked as downloaded but file is missing
            print("⚠️ Video marked as downloaded but file is missing - removing from local videos")
            videos.removeAll { $0.title == video.title }
            
            // Remove from UserDefaults
            if var downloadedInfo = UserDefaults.standard.dictionary(forKey: downloadedVideosKey) as? [String: String] {
                downloadedInfo.removeValue(forKey: video.title)
                UserDefaults.standard.set(downloadedInfo, forKey: downloadedVideosKey)
            }
        }
        
        // Initialize progress
        DispatchQueue.main.async {
            self.downloadProgress[video.id] = 0.0
        }
        
        // Create download request
        let configuration = URLSessionConfiguration.default
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: configuration)
        
        // Create a signed URL request using the S3VideoService
        let request = s3VideoService.s3Service.generateSignedRequest(for: video.url)
        
        let downloadTask = session.downloadTask(with: request) { [weak self] tempURL, response, error in
            guard let self = self else { return }
            
            // Handle download completion
            DispatchQueue.main.async {
                if let error = error {
                    print("❌ Download failed: \(error.localizedDescription)")
                    self.downloadProgress[video.id] = nil
                    completion(false)
                    return
                }
                
                guard let tempURL = tempURL,
                      let httpResponse = response as? HTTPURLResponse else {
                    print("❌ Invalid response type")
                    self.downloadProgress[video.id] = nil
                    completion(false)
                    return
                }
                
                // Log response details for debugging
                print("\n📥 Download Response:")
                print("Status Code: \(httpResponse.statusCode)")
                print("Headers: \(httpResponse.allHeaderFields)")
                
                // Accept both 200 (OK) and 206 (Partial Content) as valid responses
                guard httpResponse.statusCode == 200 || httpResponse.statusCode == 206 else {
                    print("❌ Invalid response status: \(httpResponse.statusCode)")
                    self.downloadProgress[video.id] = nil
                    completion(false)
                    return
                }
                
                do {
                    let finalURL = self.videosDirectory.appendingPathComponent(video.url.lastPathComponent)
                    
                    // Check if file already exists at destination
                    if FileManager.default.fileExists(atPath: finalURL.path) {
                        print("⚠️ File already exists at destination - removing")
                        try FileManager.default.removeItem(at: finalURL)
                    }
                    
                    try FileManager.default.moveItem(at: tempURL, to: finalURL)
                    
                    // Create local video with existing thumbnail
                    let localVideo = VideoItem(
                        url: finalURL,
                        title: video.title,
                        isLocal: true,
                        thumbnailURL: video.thumbnailURL, // Maintain existing thumbnail
                        section: video.section
                    )
                    
                    // Double check we're not adding a duplicate
                    if !self.videos.contains(where: { $0.title == video.title }) {
                        self.videos.append(localVideo)
                    } else {
                        print("⚠️ Prevented duplicate video addition")
                    }
                    
                    // Update download tracking
                    self.downloadProgress[video.id] = nil
                    
                    // Save to UserDefaults
                    if var downloadedInfo = UserDefaults.standard.dictionary(forKey: self.downloadedVideosKey) as? [String: String] {
                        downloadedInfo[video.title] = video.url.lastPathComponent
                        UserDefaults.standard.set(downloadedInfo, forKey: self.downloadedVideosKey)
                    } else {
                        UserDefaults.standard.set([video.title: video.url.lastPathComponent], forKey: self.downloadedVideosKey)
                    }
                    
                    print("✅ Download completed successfully")
                    completion(true)
                    
                } catch {
                    print("❌ Failed to save downloaded file: \(error.localizedDescription)")
                    self.downloadProgress[video.id] = nil
                    completion(false)
                }
            }
        }
        
        // Set up progress observation
        progressObservation?.invalidate()
        progressObservation = downloadTask.progress.observe(
            \Progress.fractionCompleted,
            options: [.new]
        ) { [weak self] (progress: Progress, _) in
            DispatchQueue.main.async {
                self?.downloadProgress[video.id] = progress.fractionCompleted
            }
        }
        
        downloadTask.resume()
    }
    
    func updateSelectedVideos(_ selectedVideos: [VideoItem]) {
        print("\n🎬 Updating Selected Videos:")
        print("Total selected: \(selectedVideos.count)")
        selectedVideos.forEach { video in
            print("- \(video.title)")
            print("  Is Local: \(video.isLocal)")
            print("  URL: \(video.url)")
            print("  File exists: \(FileManager.default.fileExists(atPath: video.url.path))")
        }
        
        // Save selection to UserDefaults
        let selectedIds = selectedVideos.map { $0.id }
        UserDefaults.standard.set(selectedIds, forKey: selectedVideoIdsKey)
        print("Saved IDs to UserDefaults: \(selectedIds)")
        
        // Update playlist with only local videos
        let localSelectedVideos = selectedVideos.filter { $0.isLocal }
        print("\n🎵 Updating Playlist:")
        print("Local selected videos: \(localSelectedVideos.count)")
        localSelectedVideos.forEach { video in
            print("- \(video.title)")
            print("  URL: \(video.url)")
            print("  File exists: \(FileManager.default.fileExists(atPath: video.url.path))")
        }
        
        updatePlaylist(localSelectedVideos)
    }
    
    deinit {
        // Remove all observers
        NotificationCenter.default.removeObserver(self)
        progressObservation?.invalidate()
        
        // Remove KVO observers from player items
        player.items().forEach { item in
            item.removeObserver(self, forKeyPath: #keyPath(AVPlayerItem.status))
            item.removeObserver(self, forKeyPath: #keyPath(AVPlayerItem.isPlaybackLikelyToKeepUp))
        }
        
        // Remove player observer
        player.removeObserver(self, forKeyPath: #keyPath(AVPlayer.timeControlStatus))
    }
    
    // Add new helper function to check thumbnail cache
    private func thumbnailCacheCheck(for videoTitle: String) -> URL? {
        let cacheDirectory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let thumbnailURL = cacheDirectory.appendingPathComponent("\(videoTitle)_thumbnail.jpg")
        
        let exists = FileManager.default.fileExists(atPath: thumbnailURL.path)
        if exists {
            // Verify the file is readable and not empty
            if let attributes = try? FileManager.default.attributesOfItem(atPath: thumbnailURL.path),
               let size = attributes[.size] as? Int64,
               size > 0 {
                return thumbnailURL
            } else {
                print("⚠️ Thumbnail file exists but may be corrupted: \(videoTitle)")
                // Remove corrupted thumbnail
                try? FileManager.default.removeItem(at: thumbnailURL)
                return nil
            }
        }
        return nil
    }
    
    func debugThumbnails() {
        print("\n=== 🔍 Thumbnail Debug Report ===")
        for video in videos {
            print("\nVideo: \(video.title)")
            print("Thumbnail URL: \(video.thumbnailURL?.absoluteString ?? "none")")
            if let thumbURL = video.thumbnailURL {
                let exists = FileManager.default.fileExists(atPath: thumbURL.path)
                print("Thumbnail exists: \(exists)")
                if exists {
                    if let attributes = try? FileManager.default.attributesOfItem(atPath: thumbURL.path),
                       let size = attributes[.size] as? Int64 {
                        print("Thumbnail size: \(size) bytes")
                    }
                }
            }
        }
    }
    
    // Add this new function
    func regenerateMissingThumbnails() {
        print("\n=== 🔄 Regenerating Missing Thumbnails ===")
        
        // Create a queue for background processing
        let queue = DispatchQueue(label: "thumbnail.regeneration", qos: .utility)
        
        queue.async { [weak self] in
            guard let self = self else { return }
            
            // Get videos without thumbnails
            let videosWithoutThumbnails = self.videos.filter { video in
                if let thumbnailURL = video.thumbnailURL {
                    return !FileManager.default.fileExists(atPath: thumbnailURL.path)
                }
                return true
            }
            
            print("Found \(videosWithoutThumbnails.count) videos missing thumbnails")
            
            for video in videosWithoutThumbnails {
                print("\n🎥 Processing: \(video.title)")
                
                // Verify video file exists
                guard FileManager.default.fileExists(atPath: video.url.path) else {
                    print("❌ Video file not found at: \(video.url.path)")
                    continue
                }
                
                // Generate new thumbnail
                print("🖼️ Generating thumbnail...")
                if let thumbnailURL = self.generateThumbnail(for: video.url, title: video.title) {
                    print("✅ Generated thumbnail at: \(thumbnailURL)")
                    
                    // Update the video item with the new thumbnail
                    DispatchQueue.main.async {
                        if let index = self.videos.firstIndex(where: { $0.id == video.id }) {
                            let updatedVideo = VideoItem(
                                url: video.url,
                                title: video.title,
                                isLocal: video.isLocal,
                                thumbnailURL: thumbnailURL,
                                section: video.section
                            )
                            self.videos[index] = updatedVideo
                            print("✅ Updated video item with new thumbnail")
                        }
                    }
                } else {
                    print("❌ Failed to generate thumbnail")
                }
            }
            
            // Final report
            DispatchQueue.main.async {
                print("\n=== 📊 Thumbnail Regeneration Complete ===")
                self.debugThumbnails()
            }
        }
    }
    
    // Add this function to check download status
    func debugDownloadStatus(_ remoteVideos: [VideoItem]) {
        print("\n=== 📊 Download Status Report ===")
        
        // Create lookup set of local video titles
        let localVideoTitles = Set(videos.map { $0.title })
        
        // Group by section
        let groupedVideos = Dictionary(grouping: remoteVideos) { $0.section }
        
        for (section, sectionVideos) in groupedVideos.sorted(by: { $0.key < $1.key }) {
            print("\n📁 Section: \(section)")
            
            for video in sectionVideos {
                let isDownloaded = localVideoTitles.contains(video.title)
                print("\n🎥 \(video.displayTitle)")
                print("Status: \(isDownloaded ? "✅ Downloaded" : "🔄 Not Downloaded")")
                if isDownloaded {
                    if let localVideo = videos.first(where: { $0.title == video.title }) {
                        print("Local URL: \(localVideo.url)")
                        print("File exists: \(FileManager.default.fileExists(atPath: localVideo.url.path))")
                        print("Thumbnail: \(localVideo.thumbnailURL?.absoluteString ?? "none")")
                    }
                }
                print("Remote URL: \(video.url)")
            }
        }
        
        print("\n📚 Total Statistics:")
        print("Remote videos: \(remoteVideos.count)")
        print("Downloaded videos: \(videos.count)")
        print("Sections: \(Set(remoteVideos.map { $0.section }).sorted().joined(separator: ", "))")
    }
    
    func clearCache() {
        print("\n🧹 Clearing downloaded video cache...")
        
        let bundledVideoIds = Set(bundledVideos.map { "local-\($0.title)" })
        
        // Clear downloaded videos from UserDefaults
        UserDefaults.standard.removeObject(forKey: downloadedVideosKey)
        
        // Update selected videos to keep only bundled ones
        if let selectedIds = UserDefaults.standard.array(forKey: selectedVideoIdsKey) as? [String] {
            let remainingSelectedIds = selectedIds.filter { bundledVideoIds.contains($0) }
            UserDefaults.standard.set(remainingSelectedIds, forKey: selectedVideoIdsKey)
        }
        
        // Clear downloaded videos directory
        do {
            let fileManager = FileManager.default
            let files = try fileManager.contentsOfDirectory(at: videosDirectory, includingPropertiesForKeys: nil)
            try files.forEach { file in
                try fileManager.removeItem(at: file)
            }
            print("✅ Cleared downloaded videos directory")
        } catch {
            print("❌ Error clearing videos directory: \(error)")
        }
        
        // Clear ALL thumbnail cache (including for remote videos)
        do {
            let cacheDirectory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            let thumbnailFiles = try FileManager.default.contentsOfDirectory(
                at: cacheDirectory,
                includingPropertiesForKeys: nil
            ).filter { $0.lastPathComponent.contains("_thumbnail") }
            
            print("\n🖼 Clearing \(thumbnailFiles.count) cached thumbnails...")
            for thumbnailURL in thumbnailFiles {
                try FileManager.default.removeItem(at: thumbnailURL)
                print("Removed: \(thumbnailURL.lastPathComponent)")
            }
            print("✅ Cleared all thumbnails")
        } catch {
            print("❌ Error clearing thumbnails: \(error)")
        }
        
        // Remove downloaded videos from videos array but keep bundled ones
        videos = videos.filter { video in
            let isBundled = bundledVideos.contains { $0.title == video.title }
            print("\(video.title): \(isBundled ? "Keeping (bundled)" : "Removing (downloaded)")")
            return isBundled
        }
        
        // Update current playlist to only include bundled videos
        currentPlaylist = currentPlaylist.filter { video in
            bundledVideos.contains { $0.title == video.title }
        }
        
        // Stop playback if no bundled videos are in the playlist
        if currentPlaylist.isEmpty {
            player.removeAllItems()
            currentVideoTitle = ""
        }
        
        // Clear metadata cache
        cacheManager.clearMetadata()
        
        // Force refresh of remote videos and thumbnails
        s3VideoService.fetchAvailableVideos { [weak self] result in
            guard let self = self else { return }
            
            switch result {
            case .success(let videos):
                DispatchQueue.main.async {
                    self.remoteVideos = videos
                    print("✅ Refreshed remote videos after cache clear")
                    print("Found \(videos.count) remote videos")
                    
                    // Force refresh of all thumbnails
                    self.s3VideoService.refreshThumbnails(forceRefresh: true)
                }
            case .failure(let error):
                print("❌ Failed to refresh remote videos after cache clear: \(error.localizedDescription)")
            }
        }
        
        print("\n✅ Cache cleared successfully")
        print("Kept \(videos.count) bundled videos")
        print("Current playlist: \(currentPlaylist.map { $0.title }.joined(separator: ", "))")
    }
    
    // Add this function to VideoPlayerModel
    func debugVideoDownload(_ video: VideoItem) {
        print("\n=== 📱 Video Download Debug ===")
        print("Title: \(video.title)")
        print("ID: \(video.id)")
        print("Is Local: \(video.isLocal)")
        print("URL: \(video.url)")
        
        // Check if video is in local videos array
        let isInLocalArray = videos.contains { $0.title == video.title }
        print("\n📚 Local Videos Status:")
        print("In local videos array: \(isInLocalArray)")
        
        // Check UserDefaults
        if let downloadedInfo = UserDefaults.standard.dictionary(forKey: downloadedVideosKey) as? [String: String] {
            let isInUserDefaults = downloadedInfo[video.title] != nil
            print("\n💾 UserDefaults Status:")
            print("In downloaded videos: \(isInUserDefaults)")
            if isInUserDefaults {
                print("Saved filename: \(downloadedInfo[video.title] ?? "none")")
            }
        }
        
        // Check file system
        let expectedPath = videosDirectory.appendingPathComponent(video.url.lastPathComponent)
        let fileExists = FileManager.default.fileExists(atPath: expectedPath.path)
        print("\n📁 File System Status:")
        print("Expected path: \(expectedPath.path)")
        print("File exists: \(fileExists)")
        
        if fileExists {
            do {
                let attributes = try FileManager.default.attributesOfItem(atPath: expectedPath.path)
                let fileSize = attributes[.size] as? Int64 ?? 0
                let modificationDate = attributes[.modificationDate] as? Date
                print("File size: \(Double(fileSize) / 1_000_000.0) MB")
                print("Last modified: \(modificationDate?.description ?? "unknown")")
            } catch {
                print("Error getting file attributes: \(error.localizedDescription)")
            }
        }
        
        // Check if video is selected
        if let selectedIds = UserDefaults.standard.array(forKey: selectedVideoIdsKey) as? [String] {
            let isSelected = selectedIds.contains(video.id)
            print("\n✅ Selection Status:")
            print("Is selected: \(isSelected)")
        }
    }
}

// Helper extension to safely access array elements
extension Array {
    func safe(_ index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

// Replace the async AVAsset extension with this synchronous version
extension AVAsset {
    func load(_ propertyName: String) throws -> Bool {
        var error: NSError?
        let status = statusOfValue(forKey: propertyName, error: &error)
        
        switch status {
        case .loaded:
            return true
        case .failed:
            throw error ?? NSError(domain: "AVAsset", code: 0, userInfo: [NSLocalizedDescriptionKey: "Failed to load \(propertyName)"])
        case .cancelled:
            throw NSError(domain: "AVAsset", code: 0, userInfo: [NSLocalizedDescriptionKey: "Cancelled loading \(propertyName)"])
        default:
            // Load the value synchronously
            loadValuesAsynchronously(forKeys: [propertyName]) {}
            return statusOfValue(forKey: propertyName, error: nil) == .loaded
        }
    }
} 
