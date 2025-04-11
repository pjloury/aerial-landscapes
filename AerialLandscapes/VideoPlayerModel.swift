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
    private let s3VideoService = S3VideoService()
    
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
            self?.setupPlayerObserver()
            self?.loadBundledVideos()
            self?.loadDownloadedVideos()
            
            // Regenerate missing thumbnails
            self?.regenerateMissingThumbnails()
            
            // Start remote video fetch after UI is loaded
            DispatchQueue.global(qos: .utility).async {
                self?.s3VideoService.fetchAvailableVideos()
            }
            
            print("Loaded \(self?.videos.count ?? 0) total videos")
            
            if !UserDefaults.standard.bool(forKey: "hasLaunchedBefore") {
                print("First launch - selecting all local videos")
                let localVideoIds = self?.videos.map { $0.id } ?? []
                UserDefaults.standard.set(localVideoIds, forKey: self?.selectedVideoIdsKey ?? "")
                UserDefaults.standard.set(true, forKey: "hasLaunchedBefore")
                self?.updatePlaylist(self?.videos ?? [])
            } else {
                print("Subsequent launch - loading saved selection")
                if let selectedIds = UserDefaults.standard.array(forKey: self?.selectedVideoIdsKey ?? "") as? [String] {
                    let selectedVideos = self?.videos.filter { selectedIds.contains($0.id) } ?? []
                    print("Found \(selectedVideos.count) previously selected videos")
                    self?.updatePlaylist(selectedVideos)
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
        
        // Pre-load and validate assets before creating player items
        var validVideos: [(VideoItem, AVAsset)] = []
        
        for video in currentPlaylist {
            print("\n🎥 Validating video: \(video.title)")
            print("URL: \(video.url)")
            
            // Create asset with specific options
            let asset = AVURLAsset(url: video.url, options: [
                AVURLAssetPreferPreciseDurationAndTimingKey: true
            ])
            
            // Load essential properties synchronously
            let keys = ["playable", "tracks", "duration"]
            asset.loadValuesAsynchronously(forKeys: keys) {
                // Check playability
                var error: NSError?
                let status = asset.statusOfValue(forKey: "playable", error: &error)
                
                if status == .loaded && asset.isPlayable {
                    print("✅ Asset validated for: \(video.title)")
                    validVideos.append((video, asset))
                } else {
                    print("❌ Asset validation failed for: \(video.title)")
                    if let error = error {
                        print("Error: \(error.localizedDescription)")
                    }
                }
            }
        }
        
        // Wait a brief moment for asset validation
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self = self else { return }
            
            print("\n🎬 Creating player items for \(validVideos.count) valid videos")
            
            if validVideos.isEmpty {
                print("❌ No valid videos to play")
                return
            }
            
            // Create player items from validated assets
            for (video, asset) in validVideos {
                print("\nAdding to queue: \(video.title)")
                let item = AVPlayerItem(asset: asset)
                addPlayerItemObserver(item, title: video.title)
                player.insert(item, after: player.items().last)
            }
            
            // Set initial title and play
            if let firstVideo = validVideos.first?.0 {
                currentVideoTitle = firstVideo.title
                print("\n▶️ Starting playback with: \(currentVideoTitle)")
            }
            
            // Add player observer
            addPlayerObserver()
            
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
    
    var remoteVideos: [VideoItem] {
        s3VideoService.remoteVideos
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
        print("Is Local: \(video.isLocal)")
        print("Section: \(video.section)")
        
        // Initialize progress immediately
        DispatchQueue.main.async {
            print("🔄 Initializing download progress for ID: \(video.id)")
            self.downloadProgress[video.id] = 0.0
        }
        
        // Check if already downloaded
        if let existingVideo = getLocalVersion(video) {
            print("\n⚠️ Video already exists locally")
            print("Local URL: \(existingVideo.url)")
            print("Local thumbnail: \(existingVideo.thumbnailURL?.absoluteString ?? "none")")
            
            // Verify the file actually exists and is valid
            let fileExists = FileManager.default.fileExists(atPath: existingVideo.url.path)
            print("File exists: \(fileExists)")
            
            if !fileExists {
                print("🔄 File missing - initiating fresh download")
                // Remove from videos array and UserDefaults
                if var downloadedInfo = UserDefaults.standard.dictionary(forKey: downloadedVideosKey) as? [String: String] {
                    downloadedInfo.removeValue(forKey: video.title)
                    UserDefaults.standard.set(downloadedInfo, forKey: downloadedVideosKey)
                }
                videos.removeAll { $0.title == video.title }
                // Continue with download
            } else {
                DispatchQueue.main.async {
                    self.downloadProgress[video.id] = nil
                    completion(true)
                }
                return
            }
        }
        
        print("\n=== 🖼️ Thumbnail Status Check ===")
        print("Video: \(video.title)")
        print("Remote thumbnail URL: \(video.thumbnailURL?.absoluteString ?? "none")")
        
        // Check thumbnail cache
        if let cachedURL = thumbnailCacheCheck(for: video.title) {
            print("✅ Found cached thumbnail at: \(cachedURL)")
        } else {
            print("❌ No cached thumbnail found")
            
            // Try to generate thumbnail if we have a local file
            if let existingVideo = getLocalVersion(video),
               FileManager.default.fileExists(atPath: existingVideo.url.path) {
                print("🔄 Attempting to generate thumbnail for existing video")
                if let newThumbURL = generateThumbnail(for: existingVideo.url, title: video.title) {
                    print("✅ Successfully generated new thumbnail at: \(newThumbURL)")
                } else {
                    print("❌ Failed to generate thumbnail")
                }
            }
        }
        
        print("\n🚀 Creating download task...")
        let configuration = URLSessionConfiguration.default
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: configuration)
        
        print("📝 Download request details:")
        print("URL: \(video.url)")
        print("Cache policy: \(configuration.requestCachePolicy.rawValue)")
        
        let downloadTask = session.downloadTask(with: video.url) { [weak self] tempURL, response, error in
            print("\n📡 Download task completed")
            
            if let error = error {
                print("❌ Download failed")
                print("Error: \(error.localizedDescription)")
                print("Error code: \((error as NSError).code)")
                print("Error domain: \((error as NSError).domain)")
                DispatchQueue.main.async {
                    self?.downloadProgress[video.id] = nil
                    completion(false)
                }
                return
            }
            
            guard let response = response as? HTTPURLResponse else {
                print("❌ Invalid response type")
                print("Actual response type: \(type(of: response))")
                DispatchQueue.main.async {
                    self?.downloadProgress[video.id] = nil
                    completion(false)
                }
                return
            }
            
            print("\n📥 Response details:")
            print("Status code: \(response.statusCode)")
            print("MIME type: \(response.mimeType ?? "unknown")")
            print("Content length: \(response.expectedContentLength) bytes")
            print("Headers: \(response.allHeaderFields)")
            
            guard let tempURL = tempURL else {
                print("❌ No temporary URL received")
                DispatchQueue.main.async {
                    self?.downloadProgress[video.id] = nil
                    completion(false)
                }
                return
            }
            
            print("\n📁 Temporary file:")
            print("URL: \(tempURL)")
            print("Size: \((try? FileManager.default.attributesOfItem(atPath: tempURL.path)[FileAttributeKey.size] as? Int64)?.description ?? "unknown") KB")
            
            do {
                let filename = video.url.lastPathComponent
                guard let self = self else {
                    throw NSError(domain: "VideoPlayerModel", code: -1, userInfo: [NSLocalizedDescriptionKey: "Self is nil"])
                }
                
                let finalURL = self.videosDirectory.appendingPathComponent(filename)
                
                print("\n📦 Moving file:")
                print("From: \(tempURL)")
                print("To: \(finalURL)")
                
                // Remove existing file if present
                if FileManager.default.fileExists(atPath: finalURL.path) {
                    print("🗑️ Removing existing file at destination")
                    try FileManager.default.removeItem(at: finalURL)
                }
                
                try FileManager.default.moveItem(at: tempURL, to: finalURL)
                print("✅ File moved successfully")
                
                // Generate thumbnail for the newly downloaded video
                print("\n🖼️ Generating thumbnail for downloaded video")
                let thumbnailURL = self.generateThumbnail(for: finalURL, title: video.title)
                if let thumbURL = thumbnailURL {
                    print("✅ Generated thumbnail at: \(thumbURL)")
                } else {
                    print("⚠️ Failed to generate thumbnail")
                }
                
                // Save to UserDefaults
                print("\n💾 Updating UserDefaults")
                if var downloadedInfo = UserDefaults.standard.dictionary(forKey: self.downloadedVideosKey) as? [String: String] {
                    downloadedInfo[video.title] = filename
                    UserDefaults.standard.set(downloadedInfo, forKey: self.downloadedVideosKey)
                } else {
                    UserDefaults.standard.set([video.title: filename], forKey: self.downloadedVideosKey)
                }
                print("✅ UserDefaults updated")
                
                // Create local video item with explicit self and new thumbnail
                let localVideo = VideoItem(
                    url: finalURL,
                    title: video.title,
                    isLocal: true,
                    thumbnailURL: thumbnailURL, // Use the newly generated thumbnail
                    section: video.section
                )
                
                print("\n🎥 Created local video item:")
                print("URL: \(localVideo.url)")
                print("Title: \(localVideo.title)")
                print("ID: \(localVideo.id)")
                print("Thumbnail: \(localVideo.thumbnailURL?.absoluteString ?? "none")")
                print("File exists: \(FileManager.default.fileExists(atPath: finalURL.path))")
                
                DispatchQueue.main.async {
                    print("\n✅ Finalizing download")
                    self.downloadProgress[video.id] = nil
                    self.videos.append(localVideo)
                    
                    // Debug current state
                    print("\n📊 Current Library State:")
                    print("Total videos: \((self.videos.count))")
                    self.videos.forEach { video in
                        print("- \(video.title)")
                        print("  URL: \(video.url)")
                        print("  Is Local: \(video.isLocal)")
                        print("  File exists: \(FileManager.default.fileExists(atPath: video.url.path))")
                    }
                    
                    // Refresh selected videos if this video was selected
                    if let selectedIds = UserDefaults.standard.array(forKey: self.selectedVideoIdsKey) as? [String],
                       selectedIds.contains(localVideo.id) {
                        print("\n🔄 Updating playlist with newly downloaded video")
                        let selectedVideos = self.videos.filter { selectedIds.contains($0.id) }
                        self.updateSelectedVideos(selectedVideos)
                    }
                    
                    completion(true)
                }
            } catch {
                print("\n❌ Error handling downloaded file:")
                print("Error: \(error.localizedDescription)")
                print("Error code: \((error as NSError).code)")
                print("Error domain: \((error as NSError).domain)")
                DispatchQueue.main.async {
                    self?.downloadProgress[video.id] = nil
                    completion(false)
                }
            }
        }
        
        // Set up progress observation
        progressObservation?.invalidate()
        progressObservation = downloadTask.progress.observe(
            \Progress.fractionCompleted,
            options: [],
            changeHandler: { [weak self] (progress: Foundation.Progress, _: NSKeyValueObservedChange<Double>) in
                DispatchQueue.main.async {
                    let percentage = progress.fractionCompleted * 100
                    print("📊 Progress: \(String(format: "%.1f", percentage))%")
                    self?.downloadProgress[video.id] = progress.fractionCompleted
                }
            }
        )
        
        print("\n▶️ Starting download task...")
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
}

// Helper extension to safely access array elements
extension Array {
    func safe(_ index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
} 
