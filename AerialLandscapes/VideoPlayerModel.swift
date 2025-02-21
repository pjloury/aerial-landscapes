import SwiftUI
import AVKit

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
    
    private var documentsDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }
    
    private var videosDirectory: URL {
        let directory = documentsDirectory.appendingPathComponent("Videos")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
    
    struct VideoItem: Identifiable {
        let id: String
        let url: URL
        let title: String
        let isLocal: Bool
        let thumbnailURL: URL?
        
        init(url: URL, title: String, isLocal: Bool, thumbnailURL: URL? = nil) {
            // Create a unique ID that combines title and local/remote status
            self.id = isLocal ? "local-\(title)" : "remote-\(title)"
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
        
        // Load bundled videos first
        loadBundledVideos()
        // Then load any previously downloaded videos
        loadDownloadedVideos()
        
        print("Loaded \(videos.count) total videos")
        
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
    
    private func loadDownloadedVideos() {
        // Load info about previously downloaded videos
        if let downloadedInfo = UserDefaults.standard.dictionary(forKey: downloadedVideosKey) as? [String: String] {
            for (title, filename) in downloadedInfo {
                let videoURL = videosDirectory.appendingPathComponent(filename)
                if FileManager.default.fileExists(atPath: videoURL.path) {
                    // Generate or load thumbnail
                    let thumbnailURL = generateThumbnail(for: videoURL, title: title)
                    
                    let video = VideoItem(
                        url: videoURL,
                        title: title,
                        isLocal: true,
                        thumbnailURL: thumbnailURL
                    )
                    videos.append(video)
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
            // Multiple videos - add them all to queue and set to loop
            print("Multiple videos mode - setting up queue with \(currentPlaylist.count) videos")
            player.actionAtItemEnd = .advance // Ensure we advance to next item
            
            // Add each video to the queue
            for video in currentPlaylist {
                print("Adding video to queue: \(video.title) at URL: \(video.url)")
                let item = AVPlayerItem(url: video.url)
                player.insert(item, after: player.items().last)
            }
        }
        
        // Set initial title and play
        currentVideoTitle = currentPlaylist[0].title
        print("Starting playback with: \(currentVideoTitle)")
        
        player.play()
    }
    
    var remoteVideos: [VideoItem] {
        RemoteVideos.videos
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
        print("=== Download Process Started ===")
        print("Video: \(video.title)")
        print("URL: \(video.url)")
        print("ID: \(video.id)")
        
        // Check if already downloaded
        if let existingVideo = getLocalVersion(video) {
            print("Video already exists locally:")
            print("- Local URL: \(existingVideo.url)")
            print("- Thumbnail URL: \(existingVideo.thumbnailURL?.absoluteString ?? "none")")
            DispatchQueue.main.async {
                completion(true)
            }
            return
        }
        
        print("Starting new download...")
        let videoTitle = video.title
        videos.removeAll { $0.title == videoTitle }
        
        let downloadTask = URLSession.shared.downloadTask(with: video.url) { [weak self] tempURL, response, error in
            if let error = error {
                print("❌ Download failed with error: \(error.localizedDescription)")
                DispatchQueue.main.async {
                    self?.downloadProgress[video.id] = nil
                    completion(false)
                }
                return
            }
            
            guard let response = response as? HTTPURLResponse else {
                print("❌ Invalid response type")
                return
            }
            print("📥 Response received:")
            print("- Status code: \(response.statusCode)")
            print("- MIMEType: \(response.mimeType ?? "unknown")")
            print("- Expected length: \(response.expectedContentLength)")
            
            guard let tempURL = tempURL else {
                print("❌ No temporary URL received")
                DispatchQueue.main.async {
                    self?.downloadProgress[video.id] = nil
                    completion(false)
                }
                return
            }
            
            print("📁 Temporary file received at: \(tempURL)")
            
            do {
                let filename = video.url.lastPathComponent
                let finalURL = self?.videosDirectory.appendingPathComponent(filename) ?? tempURL
                print("Moving file to: \(finalURL)")
                
                try FileManager.default.moveItem(at: tempURL, to: finalURL)
                print("✅ File moved successfully")
                
                print("Generating thumbnail...")
                let thumbnailURL = self?.generateThumbnail(for: finalURL, title: video.title)
                print("Thumbnail result: \(thumbnailURL?.absoluteString ?? "failed")")
                
                let localVideo = VideoItem(
                    url: finalURL,
                    title: video.title,
                    isLocal: true,
                    thumbnailURL: thumbnailURL
                )
                
                print("Saving to UserDefaults...")
                if var downloadedInfo = UserDefaults.standard.dictionary(forKey: self?.downloadedVideosKey ?? "") as? [String: String] {
                    downloadedInfo[video.title] = filename
                    UserDefaults.standard.set(downloadedInfo, forKey: self?.downloadedVideosKey ?? "")
                } else {
                    UserDefaults.standard.set([video.title: filename], forKey: self?.downloadedVideosKey ?? "")
                }
                print("✅ Saved to UserDefaults")
                
                DispatchQueue.main.async {
                    print("Completing download process...")
                    self?.downloadProgress[video.id] = nil
                    self?.videos.append(localVideo)
                    print("✅ Download complete and video added to library")
                    completion(true)
                }
            } catch {
                print("❌ Error handling downloaded file:")
                print(error)
                DispatchQueue.main.async {
                    self?.downloadProgress[video.id] = nil
                    completion(false)
                }
            }
            
            print("Cleaning up progress observation")
            self?.progressObservation?.invalidate()
            self?.progressObservation = nil
        }
        
        print("Setting up progress observation...")
        progressObservation?.invalidate()
        progressObservation = downloadTask.progress.observe(\.fractionCompleted) { [weak self] progress, _ in
            DispatchQueue.main.async {
                let percentage = progress.fractionCompleted * 100
                print("📊 Download progress: \(String(format: "%.1f", percentage))%")
                self?.downloadProgress[video.id] = progress.fractionCompleted
            }
        }
        
        print("Starting download task...")
        downloadTask.resume()
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
        progressObservation?.invalidate()
    }
}

// Helper extension to safely access array elements
extension Array {
    func safe(_ index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
} 
