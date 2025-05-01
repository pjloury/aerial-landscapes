override init() {
    self.player = AVQueuePlayer()
    super.init()
    
    // Load UI immediately
    DispatchQueue.main.async { [weak self] in
        guard let self = self else { return }
        self.loadInitialState()
    }
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
    
    // Clear ALL thumbnail cache
    do {
        let cacheDirectory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VideoThumbnails", isDirectory: true)
        if FileManager.default.fileExists(atPath: cacheDirectory.path) {
            try FileManager.default.removeItem(at: cacheDirectory)
            print("✅ Removed thumbnail cache directory")
        }
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
    
    // Refresh remote videos list WITHOUT auto-refreshing thumbnails
    s3VideoService.fetchAvailableVideos { [weak self] result in
        guard let self = self else { return }
        
        switch result {
        case .success(let videos):
            DispatchQueue.main.async {
                self.remoteVideos = videos
                print("✅ Refreshed remote videos after cache clear")
                print("Found \(videos.count) remote videos")
                // Do NOT automatically refresh thumbnails
            }
        case .failure(let error):
            print("❌ Failed to refresh remote videos after cache clear: \(error.localizedDescription)")
        }
    }
    
    print("\n✅ Cache cleared successfully")
    print("Kept \(videos.count) bundled videos")
    print("Current playlist: \(selectedPlaylist.map { $0.title }.joined(separator: ", "))")
}

var allVideos: [VideoItem] {
    // Get the list of downloaded video titles
    let downloadedTitles = Set(videos.map { $0.title })
    
    // Start with all local videos
    var orderedVideos = videos
    
    // Add remote videos that aren't already downloaded
    let nonDownloadedRemoteVideos = remoteVideos.filter { !downloadedTitles.contains($0.title) }
        .map { remoteVideo -> VideoItem in
            // Check for cached thumbnail regardless of download status
            if let cachedURL = s3VideoService.thumbnailCache.getCachedThumbnailURL(for: remoteVideo.title) {
                // Use cached thumbnail even for non-downloaded videos
                return VideoItem(
                    url: remoteVideo.url,
                    title: remoteVideo.title,
                    isLocal: false,
                    thumbnailInfo: .local(cachedURL),  // Use cached thumbnail
                    section: remoteVideo.section
                )
            }
            // Keep original remote video if no cache exists
            return remoteVideo
        }
    
    orderedVideos.append(contentsOf: nonDownloadedRemoteVideos)
    
    return orderedVideos
} 