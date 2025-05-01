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
    @Published private(set) var selectedPlaylist: [VideoItem] = []  // Rename from currentPlaylist
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
        let thumbnailInfo: ThumbnailInfo
        let section: String
        
        enum ThumbnailInfo {
            case local(URL)      // Local cached file URL
            case remote(URL)     // S3 URL
            case notAvailable    // No thumbnail available
            
            var url: URL? {
                switch self {
                case .local(let url), .remote(let url):
                    return url
                case .notAvailable:
                    return nil
                }
            }
            
            var isLocal: Bool {
                if case .local = self {
                    return true
                }
                return false
            }
        }
        
        var displayTitle: String {
            isLocal ? title : "\(title) (Remote)"
        }
        
        init(url: URL, title: String, isLocal: Bool, thumbnailInfo: ThumbnailInfo, section: String) {
            self.id = isLocal ? "local-\(title)" : "remote-\(title)"
            self.url = url
            self.title = title
            self.isLocal = isLocal
            self.thumbnailInfo = thumbnailInfo
            self.section = section
        }
    }
    
    override init() {
        self.player = AVQueuePlayer()
        super.init()
        
        // Load UI immediately
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            
            // Load initial state (this loads bundled videos)
            self.loadInitialState()
            
            // Select all bundled videos by default
            let bundledVideoIds = Set(self.bundledVideos.map { "local-\($0.title)" })
            UserDefaults.standard.set(Array(bundledVideoIds), forKey: self.selectedVideoIdsKey)
            
            // Get the actual bundled video items
            let bundledVideoItems = self.videos.filter { video in
                bundledVideoIds.contains(video.id)
            }
            
            // Start playing bundled videos
            self.updatePlaylist(bundledVideoItems)
        }
    }
    
    private func loadInitialState() {
        print("\n=== 📱 Loading Initial State ===")
        
        // Step 1: Load bundled and downloaded videos first
        loadBundledVideos()
        loadDownloadedVideos()
        
        // Step 2: Load and validate cached metadata
        print("\n=== 📦 Loading Cached Metadata ===")
        let cachedMetadata = cacheManager.loadVideoMetadata()
        print("Found \(cachedMetadata.count) cached video entries")
        
        // Track corrupted/missing thumbnails for later refresh
        var corruptedThumbnails: Set<String> = []
        
        // Step 3: Process cached metadata and validate thumbnails
        let cachedVideos = cachedMetadata.compactMap { metadata -> VideoItem? in
            print("\n🎥 Processing cached video: \(metadata.title)")
            
            // Check if this video is already downloaded locally
            if videos.contains(where: { $0.title == metadata.title }) {
                print("⏩ Skipping - already in local videos")
                return nil
            }
            
            // Check thumbnail status
            let thumbnailStatus = validateThumbnail(for: metadata.title)
            switch thumbnailStatus {
            case .valid(let url):
                print("✅ Valid thumbnail found in cache")
                return VideoItem(
                    url: metadata.remoteURL,
                    title: metadata.title,
                    isLocal: false,
                    thumbnailInfo: .remote(url),
                    section: metadata.section
                )
            case .corrupted, .missing:
                print("⚠️ Thumbnail needs refresh")
                corruptedThumbnails.insert(metadata.title)
                // Still create the video item with S3 URL
                if let thumbnailURL = self.s3VideoService.getThumbnailURL(for: metadata.title) {
                    return VideoItem(
                        url: metadata.remoteURL,
                        title: metadata.title,
                        isLocal: false,
                        thumbnailInfo: .remote(thumbnailURL),
                        section: metadata.section
                    )
                } else {
                    return VideoItem(
                        url: metadata.remoteURL,
                        title: metadata.title,
                        isLocal: false,
                        thumbnailInfo: .notAvailable,
                        section: metadata.section
                    )
                }
            }
        }
        
        // Step 4: Update UI with cached data first
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.remoteVideos = cachedVideos
            print("\n📱 Updated UI with \(cachedVideos.count) cached remote videos")
            
            // Immediately start downloading corrupted/missing thumbnails
            if !corruptedThumbnails.isEmpty {
                print("\n🔄 Refreshing \(corruptedThumbnails.count) corrupted/missing thumbnails")
                self.s3VideoService.refreshThumbnails(forTitles: Array(corruptedThumbnails))
            }
        }
        
        // Step 5: Fetch fresh data from S3
        print("\n☁️ Fetching fresh data from S3")
        s3VideoService.fetchAvailableVideos { [weak self] result in
            guard let self = self else { return }
            
            switch result {
            case .success(let freshVideos):
                print("Found \(freshVideos.count) videos in S3")
                
                // Process fresh videos
                DispatchQueue.main.async {
                    self.processFreshVideos(freshVideos, existingCache: Set(cachedMetadata.map { $0.title }))
                }
                
            case .failure(let error):
                print("❌ Failed to fetch fresh data: \(error.localizedDescription)")
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
            
            print("\n🔄 Video finished playing")
            print("Selected playlist count: \(self.selectedPlaylist.count)")
            
            if self.selectedPlaylist.count == 1 {
                // Single video - seek back to start
                print("Single video mode - rewinding to start")
                finishedItem.seek(to: .zero) { [weak self] finished in
                    if finished {
                        print("✅ Seek completed - restarting playback")
                        self?.player.play()
                    }
                }
            } else {
                // Multiple videos - handle playlist rotation
                print("Multiple video mode - rotating playlist")
                
                if let urlAsset = finishedItem.asset as? AVURLAsset {
                    // Find the video that just finished
                    if let finishedVideo = self.selectedPlaylist.first(where: { $0.url == urlAsset.url }) {
                        print("Finished playing: \(finishedVideo.title)")
                        
                        // Remove the finished item and add it back to the end
                        self.player.remove(finishedItem)
                        
                        // Create a new item for the same video
                        let newItem = AVPlayerItem(url: finishedVideo.url)
                        
                        // Add it to the end of the queue
                        self.player.insert(newItem, after: self.player.items().last)
                        print("Re-added \(finishedVideo.title) to queue")
                    }
                }
                
                // Update the current video title
                if let currentItem = self.player.currentItem,
                   let urlAsset = currentItem.asset as? AVURLAsset,
                   let currentVideo = self.selectedPlaylist.first(where: { $0.url == urlAsset.url }) {
                    self.currentVideoTitle = currentVideo.title
                    print("Now playing: \(currentVideo.title)")
                }
            }
            
            // Ensure playback continues
            self.player.play()
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
                    
                    let thumbnailInfo: VideoItem.ThumbnailInfo
                    if let url = thumbnailURL {
                        thumbnailInfo = .local(url)
                    } else {
                        thumbnailInfo = .notAvailable
                    }
                    
                    let video = VideoItem(
                        url: url,
                        title: bundledVideo.title,
                        isLocal: true,
                        thumbnailInfo: thumbnailInfo,
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
            print("Found \(downloadedInfo.count) previously downloaded videos")
            
            for (title, filename) in downloadedInfo {
                print("\n🎥 Processing: \(title)")
                let videoURL = videosDirectory.appendingPathComponent(filename)
                
                if FileManager.default.fileExists(atPath: videoURL.path) {
                    print("✅ Video file exists at: \(videoURL.path)")
                    
                    // Validate the video file
                    if validateVideoFile(at: videoURL) {
                        print("✅ Video file is valid")
                        
                        // Get or generate thumbnail
                        let thumbnailURL = thumbnailCacheCheck(for: title) ?? generateThumbnail(for: videoURL, title: title)
                        
                        // Determine section (default to California if not found in remote videos)
                        let section = remoteVideos.first { $0.title == title }?.section ?? "California"
                        
                        let thumbnailInfo: VideoItem.ThumbnailInfo
                        if let cachedThumbnailURL = thumbnailCacheCheck(for: title) {
                            thumbnailInfo = .local(cachedThumbnailURL)
                        } else if let s3URL = s3VideoService.getThumbnailURL(for: title) {
                            thumbnailInfo = .remote(s3URL)
                        } else {
                            thumbnailInfo = .notAvailable
                        }
                        
                        let video = VideoItem(
                            url: videoURL,
                            title: title,
                            isLocal: true,
                            thumbnailInfo: thumbnailInfo,
                            section: section
                        )
                        videos.append(video)
                        print("✅ Added video to library")
                    } else {
                        print("❌ Video file is invalid or corrupted")
                        // Remove invalid entry
                        removeDownloadedVideo(title: title, filename: filename)
                    }
                } else {
                    print("❌ Video file missing: \(filename)")
                    // Remove missing entry
                    removeDownloadedVideo(title: title, filename: filename)
                }
            }
        }
        print("\n📊 Loaded \(videos.count) local videos")
    }
    
    private func removeDownloadedVideo(title: String, filename: String) {
        print("🗑️ Removing downloaded video entry: \(title)")
        
        // Remove from UserDefaults
        if var downloadedInfo = UserDefaults.standard.dictionary(forKey: downloadedVideosKey) as? [String: String] {
            downloadedInfo.removeValue(forKey: title)
            UserDefaults.standard.set(downloadedInfo, forKey: downloadedVideosKey)
        }
        
        // Try to remove the file if it exists
        let videoURL = videosDirectory.appendingPathComponent(filename)
        try? FileManager.default.removeItem(at: videoURL)
        
        // Remove thumbnail if it exists
        if let thumbnailURL = thumbnailCacheCheck(for: title) {
            try? FileManager.default.removeItem(at: thumbnailURL)
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
            let cgImage = try imageGenerator.copyCGImage(at: time, actualTime: nil)
            let uiImage = UIImage(cgImage: cgImage)
            let cacheDirectory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            
            // Sanitize the filename to handle special characters
            let sanitizedTitle = title
                .addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? title
            let thumbnailURL = cacheDirectory.appendingPathComponent("\(sanitizedTitle)_thumbnail.jpg")
            
            if let imageData = uiImage.jpegData(compressionQuality: 0.9) {
                try? imageData.write(to: thumbnailURL)
                print("✅ Successfully generated and saved thumbnail for: \(title)")
                print("Path: \(thumbnailURL.path)")
                return thumbnailURL
            }
        } catch {
            print("❌ Failed to generate thumbnail for \(title)")
            print("Error: \(error.localizedDescription)")
        }
        
        return nil
    }
    
    private func updatePlaylist(_ localVideos: [VideoItem]) {
        print("\n🔄 Updating Player Playlist")
        print("Videos to play: \(localVideos.count)")
        
        guard !localVideos.isEmpty else {
            print("❌ No valid local videos to play")
            player.removeAllItems()
            selectedPlaylist = []  // Update the renamed property
            currentVideoTitle = ""
            return
        }
        
        // Shuffle the videos and store them
        selectedPlaylist = localVideos.shuffled()  // Update the renamed property
        
        // Clear existing queue but don't pause
        player.removeAllItems()
        
        // Create player items for all videos
        for video in selectedPlaylist {  // Use renamed property
            let playerItem = AVPlayerItem(url: video.url)
            player.insert(playerItem, after: player.items().last)
            print("Added to queue: \(video.title)")
        }
        
        // Set initial title
        if let firstVideo = selectedPlaylist.first {  // Use renamed property
            currentVideoTitle = firstVideo.title
            print("Starting playback with: \(firstVideo.title)")
        }
        
        // Start playback if not already playing
        if player.timeControlStatus != .playing {
            player.play()
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
        
        let destinationURL = videosDirectory.appendingPathComponent(video.url.lastPathComponent)
        print("\nDownload Details:")
        print("Source: \(video.url)")
        print("Destination: \(destinationURL.path)")
        
        // Check if already downloaded - EARLY EXIT
        if let existingVideo = getLocalVersion(video) {
            print("\n⚠️ Attempt to download already existing video")
            print("Local URL: \(existingVideo.url)")
            
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
        
        print("\n🚀 Starting download...")
        
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
                    print("\n❌ Download failed:")
                    print("Error: \(error.localizedDescription)")
                    self.downloadProgress[video.id] = nil
                    completion(false)
                    return
                }
                
                guard let tempURL = tempURL,
                      let httpResponse = response as? HTTPURLResponse else {
                    print("\n❌ Invalid response type")
                    self.downloadProgress[video.id] = nil
                    completion(false)
                    return
                }
                
                // Log response details
                print("\n📥 Download Response:")
                print("Status Code: \(httpResponse.statusCode)")
                if let contentLength = httpResponse.allHeaderFields["Content-Length"] as? String,
                   let bytes = Double(contentLength) {
                    let megabytes = bytes / 1_000_000.0
                    print("Content Length: \(String(format: "%.1f MB", megabytes))")
                }
                
                // Accept both 200 (OK) and 206 (Partial Content) as valid responses
                guard httpResponse.statusCode == 200 || httpResponse.statusCode == 206 else {
                    print("\n❌ Invalid response status: \(httpResponse.statusCode)")
                    self.downloadProgress[video.id] = nil
                    completion(false)
                    return
                }
                
                do {
                    // Check if file already exists at destination
                    if FileManager.default.fileExists(atPath: destinationURL.path) {
                        print("\n⚠️ File already exists at destination - removing")
                        try FileManager.default.removeItem(at: destinationURL)
                    }
                    
                    try FileManager.default.moveItem(at: tempURL, to: destinationURL)
                    
                    // Add validation
                    if !self.validateVideoFile(at: destinationURL) {
                        print("❌ Downloaded file failed validation - removing")
                        try? FileManager.default.removeItem(at: destinationURL)
                        self.downloadProgress[video.id] = nil
                        completion(false)
                        return
                    }
                    
                    // Get file info
                    let attributes = try FileManager.default.attributesOfItem(atPath: destinationURL.path)
                    let fileSize = attributes[.size] as? Int64 ?? 0
                    
                    if fileSize < 5_000_000 { // 5MB minimum
                        print("❌ Downloaded file is suspiciously small (\(Double(fileSize) / 1_000_000.0) MB)")
                        try? FileManager.default.removeItem(at: destinationURL)
                        self.downloadProgress[video.id] = nil
                        completion(false)
                        return
                    }
                    
                    print("\n✅ Download completed successfully:")
                    print("Final location: \(destinationURL.path)")
                    print("File size: \(Double(fileSize) / 1_000_000.0) MB")
                    
                    // Create local video with existing thumbnail
                    let thumbnailInfo: VideoItem.ThumbnailInfo
                    if let existingThumbnailURL = video.thumbnailInfo.url {
                        thumbnailInfo = .local(existingThumbnailURL)
                    } else if let s3URL = self.s3VideoService.getThumbnailURL(for: video.title) {
                        thumbnailInfo = .remote(s3URL)
                    } else {
                        thumbnailInfo = .notAvailable
                    }
                    
                    let localVideo = VideoItem(
                        url: destinationURL,
                        title: video.title,
                        isLocal: true,
                        thumbnailInfo: thumbnailInfo,
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
                    
                completion(true)
                    
                } catch {
                    print("\n❌ Failed to save downloaded file:")
                    print("Error: \(error.localizedDescription)")
                    self.downloadProgress[video.id] = nil
                    completion(false)
                }
            }
        }
        
        // Set up progress observation
        progressObservation?.invalidate()
        progressObservation = downloadTask.progress.observe(
            \.fractionCompleted,
            options: [.new]
        ) { [weak self] progress, _ in
            DispatchQueue.main.async {
                self?.downloadProgress[video.id] = progress.fractionCompleted
                // Format the byte counts manually since .formatted() isn't available
                let completedMB = Double(progress.completedUnitCount) / 1_000_000.0
                let totalMB = Double(progress.totalUnitCount) / 1_000_000.0
                print("\r📥 Download progress: \(Int(progress.fractionCompleted * 100))% (\(String(format: "%.1f", completedMB)) MB / \(String(format: "%.1f", totalMB)) MB)", terminator: "")
            }
        }
        
        downloadTask.resume()
    }
    
    func updateSelectedVideos(_ selectedVideos: [VideoItem]) {
        print("\n🎬 Updating Selected Videos:")
        print("Total selected: \(selectedVideos.count)")
        
        // Filter to only local videos that exist
        let validLocalVideos = selectedVideos.filter { video in
            let exists = FileManager.default.fileExists(atPath: video.url.path)
            print("- \(video.title)")
            print("  Is Local: \(video.isLocal)")
            print("  URL: \(video.url)")
            print("  File exists: \(exists)")
            return video.isLocal && exists
        }
        
        // Save selection to UserDefaults
        let selectedIds = selectedVideos.map { $0.id }
        UserDefaults.standard.set(selectedIds, forKey: selectedVideoIdsKey)
        print("Saved IDs to UserDefaults: \(selectedIds)")
        
        // Update playlist directly with filtered videos
        updatePlaylist(validLocalVideos)
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
        // Sanitize the filename to handle special characters
        let sanitizedTitle = videoTitle
            .addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? videoTitle
        let thumbnailURL = cacheDirectory.appendingPathComponent("\(sanitizedTitle)_thumbnail.jpg")
        
        let exists = FileManager.default.fileExists(atPath: thumbnailURL.path)
        if exists {
            // Verify the file is readable and not empty
            if let attributes = try? FileManager.default.attributesOfItem(atPath: thumbnailURL.path),
               let size = attributes[.size] as? Int64,
               size > 0 {
                print("✅ Found valid thumbnail for: \(videoTitle)")
                print("Path: \(thumbnailURL.path)")
                print("Size: \(size) bytes")
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
            print("Thumbnail URL: \(video.thumbnailInfo.url?.absoluteString ?? "none")")
            if let thumbURL = video.thumbnailInfo.url {
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
                if let thumbnailURL = video.thumbnailInfo.url {
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
                                thumbnailInfo: .remote(thumbnailURL),
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
                        print("Thumbnail: \(localVideo.thumbnailInfo.url?.absoluteString ?? "none")")
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
        selectedPlaylist = selectedPlaylist.filter { video in
            bundledVideos.contains { $0.title == video.title }
        }
        
        // Stop playback if no bundled videos are in the playlist
        if selectedPlaylist.isEmpty {
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
        print("Current playlist: \(selectedPlaylist.map { $0.title }.joined(separator: ", "))")
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
    
    // Add this function to VideoPlayerModel
    private func checkCacheStatus() {
        print("\n=== 📦 Cache Status Check ===")
        
        // Check videos directory
        do {
            let files = try FileManager.default.contentsOfDirectory(at: videosDirectory, includingPropertiesForKeys: nil)
            print("\n📁 Videos Directory Status:")
            print("Path: \(videosDirectory.path)")
            print("Found \(files.count) files:")
            
            var totalSize: Int64 = 0
            for file in files {
                if let attributes = try? FileManager.default.attributesOfItem(atPath: file.path) {
                    let size = attributes[.size] as? Int64 ?? 0
                    totalSize += size
                    print("- \(file.lastPathComponent)")
                    print("  Size: \(Double(size) / 1_000_000.0) MB")
                }
            }
            print("Total cache size: \(Double(totalSize) / 1_000_000.0) MB")
        } catch {
            print("❌ Error reading videos directory: \(error.localizedDescription)")
        }
        
        // Check thumbnails
        let cacheDirectory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        do {
            let thumbnails = try FileManager.default.contentsOfDirectory(at: cacheDirectory, includingPropertiesForKeys: nil)
                .filter { $0.lastPathComponent.contains("_thumbnail") }
            
            print("\n🖼 Thumbnail Cache Status:")
            print("Found \(thumbnails.count) thumbnails:")
            for thumbnail in thumbnails {
                if let attributes = try? FileManager.default.attributesOfItem(atPath: thumbnail.path) {
                    let size = attributes[.size] as? Int64 ?? 0
                    print("- \(thumbnail.lastPathComponent)")
                    print("  Size: \(Double(size) / 1_000.0) KB")
                }
            }
        } catch {
            print("❌ Error reading thumbnail cache: \(error.localizedDescription)")
        }
        
        // Check UserDefaults status
        print("\n💾 UserDefaults Status:")
        if let downloadedInfo = UserDefaults.standard.dictionary(forKey: downloadedVideosKey) as? [String: String] {
            print("Found \(downloadedInfo.count) registered downloads:")
            for (title, filename) in downloadedInfo {
                let videoPath = videosDirectory.appendingPathComponent(filename)
                let exists = FileManager.default.fileExists(atPath: videoPath.path)
                print("- \(title)")
                print("  Filename: \(filename)")
                print("  File exists: \(exists)")
            }
        } else {
            print("No downloaded videos registered")
        }
        
        // Compare with remote videos
        print("\n🌐 Remote Video Cache Status:")
        for video in remoteVideos {
            let localPath = videosDirectory.appendingPathComponent(video.url.lastPathComponent)
            let exists = FileManager.default.fileExists(atPath: localPath.path)
            let hasThumbnail = thumbnailCacheCheck(for: video.title) != nil
            
            print("\n- \(video.title)")
            print("  Cached: \(exists)")
            print("  Has thumbnail: \(hasThumbnail)")
            
            if exists {
                if let attributes = try? FileManager.default.attributesOfItem(atPath: localPath.path) {
                    let size = attributes[.size] as? Int64 ?? 0
                    let modified = attributes[.modificationDate] as? Date
                    print("  Size: \(Double(size) / 1_000_000.0) MB")
                    print("  Last modified: \(modified?.description ?? "unknown")")
                }
            }
        }
    }
    
    // Add this function
    private func validateVideoFile(at url: URL) -> Bool {
        let asset = AVURLAsset(url: url)
        let keys = ["duration", "tracks"]
        
        // Load synchronously
        asset.loadValuesAsynchronously(forKeys: keys) {}
        
        // Wait briefly for loading
        let timeout = Date().addingTimeInterval(2.0)
        while Date() < timeout {
            let durationStatus = asset.statusOfValue(forKey: "duration", error: nil)
            let tracksStatus = asset.statusOfValue(forKey: "tracks", error: nil)
            
            if durationStatus != .loading && tracksStatus != .loading {
                print("Video validation results:")
                print("Duration status: \(durationStatus.rawValue)")
                print("Tracks status: \(tracksStatus.rawValue)")
                print("Duration: \(asset.duration.seconds) seconds")
                print("Track count: \(asset.tracks.count)")
                
                return durationStatus == .loaded && tracksStatus == .loaded &&
                       asset.duration.seconds > 0 && !asset.tracks.isEmpty
            }
            
            Thread.sleep(forTimeInterval: 0.1)
        }
        
        return false
    }
    
    var allVideos: [VideoItem] {
        // Get the list of downloaded video titles
        let downloadedTitles = Set(videos.map { $0.title })
        
        // Start with all local videos
        var orderedVideos = videos
        
        // Add only remote videos that aren't already downloaded
        let nonDownloadedRemoteVideos = remoteVideos.filter { !downloadedTitles.contains($0.title) }
        orderedVideos.append(contentsOf: nonDownloadedRemoteVideos)
        
        print("\n📊 Video List Status:")
        print("Local videos: \(videos.count)")
        print("Remote videos (not downloaded): \(nonDownloadedRemoteVideos.count)")
        print("Total unique videos: \(orderedVideos.count)")
        
        return orderedVideos
    }
    
    // Add this helper method to update thumbnail URLs
    private func updateRemoteVideoThumbnails(with thumbnails: [String: URL]) {
        print("\n🔄 Updating remote video thumbnails")
        print("Received \(thumbnails.count) thumbnail updates")
        
        remoteVideos = remoteVideos.map { video -> VideoItem in
            if let newThumbnailURL = thumbnails[video.title] ?? thumbnailCacheCheck(for: video.title) {
                print("✅ Updated thumbnail for: \(video.title)")
                return VideoItem(
                    url: video.url,
                    title: video.title,
                    isLocal: video.isLocal,
                    thumbnailInfo: .remote(newThumbnailURL),
                    section: video.section
                )
            }
            return video
        }
    }
    
    func debugThumbnailLifecycle(_ video: VideoItem) {
        print("\n=== 🖼 Thumbnail Lifecycle Debug for: \(video.title) ===")
        
        // 1. Check assigned thumbnail URL
        print("\n📌 Thumbnail URL Status:")
        if let thumbnailURL = video.thumbnailInfo.url {
            print("Assigned URL: \(thumbnailURL)")
            
            // Check if it's a local cache URL or remote S3 URL
            if thumbnailURL.absoluteString.contains("file://") {
                print("Type: Local Cache URL")
            } else if thumbnailURL.absoluteString.contains("s3") {
                print("Type: Remote S3 URL")
            }
        } else {
            print("❌ No thumbnail URL assigned")
        }
        
        // 2. Check local cache
        print("\n💾 Cache Status:")
        if let cachedURL = thumbnailCacheCheck(for: video.title) {
            print("✅ Found in cache: \(cachedURL)")
            
            // Verify cached file
            if let attributes = try? FileManager.default.attributesOfItem(atPath: cachedURL.path) {
                let size = attributes[.size] as? Int64 ?? 0
                print("File size: \(size) bytes")
                
                // Try to load the image data to verify it's valid
                if let data = try? Data(contentsOf: cachedURL) {
                    print("✅ Cache file is readable (\(data.count) bytes)")
                } else {
                    print("❌ Cache file exists but is not readable")
                }
            }
        } else {
            print("❌ Not found in cache")
        }
        
        // 3. Check S3 availability
        print("\n☁️ S3 Status:")
        if let s3URL = s3VideoService.getThumbnailURL(for: video.title) {
            print("S3 URL available: \(s3URL)")
        } else {
            print("❌ Could not generate S3 URL")
        }
        
        // 4. Compare assigned vs available URLs
        print("\n🔄 URL Comparison:")
        let cachedURL = thumbnailCacheCheck(for: video.title)
        let s3URL = s3VideoService.getThumbnailURL(for: video.title)
        print("Assigned: \(video.thumbnailInfo.url?.absoluteString ?? "none")")
        print("Cached  : \(cachedURL?.absoluteString ?? "none")")
        print("S3      : \(s3URL?.absoluteString ?? "none")")
    }
    
    // Add these helper functions
    private enum ThumbnailStatus {
        case valid(URL)
        case corrupted
        case missing
    }
    
    private func validateThumbnail(for videoTitle: String) -> ThumbnailStatus {
        print("Validating thumbnail for: \(videoTitle)")
        
        if let cachedURL = thumbnailCacheCheck(for: videoTitle) {
            // Try to load the image data to verify it's valid
            do {
                let data = try Data(contentsOf: cachedURL)
                if data.count > 0 {
                    print("✅ Thumbnail validated: \(data.count) bytes")
                    return .valid(cachedURL)
                } else {
                    print("❌ Thumbnail file is empty")
                    return .corrupted
                }
            } catch {
                print("❌ Thumbnail file is corrupted: \(error.localizedDescription)")
                return .corrupted
            }
        }
        
        print("❌ No thumbnail found in cache")
        return .missing
    }
    
    private func processFreshVideos(_ freshVideos: [VideoItem], existingCache: Set<String>) {
        print("\n=== 📥 Processing Fresh Videos ===")
        
        // Get current downloaded titles
        let downloadedTitles = Set(videos.map { $0.title })
        
        // Find new videos not in cache
        let newVideos = freshVideos.filter { !existingCache.contains($0.title) }
        print("Found \(newVideos.count) new videos not in cache")
        
        // Update metadata cache with fresh data
        let freshMetadata = freshVideos.map { video in
            VideoCacheManager.VideoMetadata(
                title: video.title,
                remoteURL: video.url,
                section: video.section,
                hasCachedThumbnail: thumbnailCacheCheck(for: video.title) != nil,
                isDownloaded: downloadedTitles.contains(video.title),
                lastUpdated: Date()
            )
        }
        cacheManager.saveVideoMetadata(freshMetadata)
        
        // Update remote videos list, excluding downloaded ones
        let updatedRemoteVideos = freshVideos.filter { !downloadedTitles.contains($0.title) }
            .map { video -> VideoItem in
                // Use cached thumbnail if available, otherwise use S3 URL
                if let thumbnailURL = thumbnailCacheCheck(for: video.title) ?? 
                                     s3VideoService.getThumbnailURL(for: video.title) {
                    return VideoItem(
                        url: video.url,
                        title: video.title,
                        isLocal: false,
                        thumbnailInfo: .remote(thumbnailURL),
                        section: video.section
                    )
                } else {
                    // If no thumbnail URL is available, use .notAvailable
                    return VideoItem(
                        url: video.url,
                        title: video.title,
                        isLocal: false,
                        thumbnailInfo: .notAvailable,
                        section: video.section
                    )
                }
            }
        
        remoteVideos = updatedRemoteVideos
        isInitialLoad = false
        
        print("✅ Updated UI with \(updatedRemoteVideos.count) remote videos")
        
        // Download thumbnails for new videos
        if !newVideos.isEmpty {
            print("\n🔄 Downloading thumbnails for \(newVideos.count) new videos")
            s3VideoService.refreshThumbnails(forTitles: newVideos.map { $0.title })
        }
    }
    
    func debugThumbnailURLs() {
        print("\n=== 🔍 Debugging Thumbnail URLs ===")
        
        // Check remote videos
        print("\nRemote Videos:")
        for video in remoteVideos {
            print("\n🎥 Video: \(video.title)")
            switch video.thumbnailInfo {
            case .local(let url):
                print("Type: Local")
                print("URL: \(url)")
                print("Exists: \(FileManager.default.fileExists(atPath: url.path))")
                if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) {
                    print("Size: \(attrs[.size] as? Int64 ?? 0) bytes")
                }
            case .remote(let url):
                print("Type: Remote")
                print("URL: \(url)")
            case .notAvailable:
                print("Type: Not Available")
            }
        }
        
        // Check local videos
        print("\nLocal Videos:")
        for video in videos {
            print("\n🎥 Video: \(video.title)")
            switch video.thumbnailInfo {
            case .local(let url):
                print("Type: Local")
                print("URL: \(url)")
                print("Exists: \(FileManager.default.fileExists(atPath: url.path))")
                if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) {
                    print("Size: \(attrs[.size] as? Int64 ?? 0) bytes")
                }
            case .remote(let url):
                print("Type: Remote")
                print("URL: \(url)")
            case .notAvailable:
                print("Type: Not Available")
            }
        }
        
        // Check cache directory
        let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        print("\nCache Directory Contents:")
        if let files = try? FileManager.default.contentsOfDirectory(at: cacheDir, includingPropertiesForKeys: nil) {
            for file in files.filter({ $0.lastPathComponent.contains("_thumbnail") }) {
                print("\nFile: \(file.lastPathComponent)")
                if let attrs = try? FileManager.default.attributesOfItem(atPath: file.path) {
                    print("Size: \(attrs[.size] as? Int64 ?? 0) bytes")
                }
            }
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
